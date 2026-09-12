#Requires -Version 5.1
<#
.SYNOPSIS
Publishes the exact disk from a successful, isolated build result.
.DESCRIPTION
Requires Hyper-V PowerShell, Azure CLI, AZURE_STORAGE_ACCOUNT, AZURE_STORAGE_KEY,
and AZURE_CONTAINER_NAME. Writes publication.json, publication.log, and
publication-lease.log beside ResultPath. Never renames build artifacts.

The canonical block blob is also the cross-host lock: a 60-second lease,
renewed every 15 seconds, with fail-fast contention and no lease breaking.
An absent destination is conditionally created as an empty block blob; a failed
first publication may leave that empty blob. Existing images are never seeded.
Both .vhdx and .vhd are uploaded as block-blob file artifacts, not page disks.
The actual upload carries the lease ID, so an expired/lost lease cannot commit
over another publisher. Azure administrators must not break active leases.
#>
[CmdletBinding()]
param([string]$ResultPath)

function Protect-PublicationText {
    param([string]$Text)
    if ($env:AZURE_STORAGE_KEY) {
        return $Text.Replace($env:AZURE_STORAGE_KEY, '[REDACTED]')
    }
    return $Text
}

function Write-PublicationLog {
    param([string]$LogPath, [string]$Message)
    Add-Content -LiteralPath $LogPath -Encoding UTF8 -ErrorAction Stop -Value (
        '{0} {1}' -f [DateTime]::UtcNow.ToString('o'), (Protect-PublicationText $Message))
}

function Invoke-PublicationAzureCli {
    param([string[]]$Arguments, [string]$LogPath, [string]$Operation)
    Write-PublicationLog $LogPath $Operation
    # Windows PowerShell wraps native stderr in ErrorRecords even on exit 0.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& az @Arguments --auth-mode key --only-show-errors --output json 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $text = Protect-PublicationText (($output | ForEach-Object { "$_" }) -join "`n")
    if (-not [string]::IsNullOrWhiteSpace($text)) {
        Write-PublicationLog $LogPath "$Operation output: $text"
    }
    if ($exitCode -ne 0) {
        throw "$Operation failed (Azure CLI exit $exitCode): $text"
    }
    return $text
}

function Get-PublicationAbsolutePath {
    param([object]$Path, [string]$Name)
    if ($Path -isnot [string] -or $Path -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+\\)') {
        throw "$Name must be an absolute Windows filesystem path."
    }
    return [IO.Path]::GetFullPath($Path)
}

function Get-PublicationDisk {
    param([object]$Result)
    foreach ($name in @('Status', 'BuildId', 'VmName', 'OutputDirectory', 'DiskPath', 'DiskFormat', 'DiskSizeBytes')) {
        if ($null -eq $Result -or $null -eq $Result.PSObject.Properties[$name]) {
            throw "Build result is missing $name."
        }
    }
    if ($Result.Status -cne 'Succeeded') { throw 'Build result must have Status Succeeded.' }
    foreach ($name in @('Status', 'BuildId', 'VmName', 'DiskFormat')) {
        if ($Result.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($Result.$name)) {
            throw "Build result $name must be a nonempty string."
        }
    }
    if (@('VHD', 'VHDX') -cnotcontains $Result.DiskFormat) { throw 'DiskFormat must be VHD or VHDX.' }
    if (($Result.DiskSizeBytes -isnot [long] -and $Result.DiskSizeBytes -isnot [int]) -or
        $Result.DiskSizeBytes -le 0) {
        throw 'DiskSizeBytes must be a positive integer file length.'
    }
    $directory = Get-PublicationAbsolutePath $Result.OutputDirectory 'OutputDirectory'
    $path = Get-PublicationAbsolutePath $Result.DiskPath 'DiskPath'
    $prefix = $directory.TrimEnd('\') + '\'
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'DiskPath must be inside OutputDirectory.'
    }
    $output = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
    $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (-not $output.PSIsContainer -or $file.PSIsContainer) { throw 'DiskPath must identify a disk file.' }
    if ($file.Extension -ine ('.' + $Result.DiskFormat)) { throw 'Disk extension does not match DiskFormat.' }
    # Reject redirected paths, including junctions above the output directory.
    $item = $file
    while ($null -ne $item) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'DiskPath must not traverse a reparse point.'
        }
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
    $stream = $null
    try {
        # Keep the disk readable but immutable until the upload and verification finish.
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        if ($stream.Length -ne $Result.DiskSizeBytes) { throw 'Disk file length does not match DiskSizeBytes.' }
        $vhd = @(Get-VHD -Path $path -ErrorAction Stop)
        if ($vhd.Count -ne 1 -or $vhd[0].VhdFormat -ine $Result.DiskFormat -or
            $vhd[0].FileSize -ne $Result.DiskSizeBytes -or
            -not [string]::IsNullOrEmpty($vhd[0].ParentPath) -or
            $vhd[0].VhdType -eq 'Differencing' -or $vhd[0].Attached) {
            throw 'Get-VHD did not verify the expected independent, detached disk format and file size.'
        }
        if (-not (Test-VHD -Path $path -ErrorAction Stop)) { throw 'Test-VHD reports an unreadable disk.' }
        return [pscustomobject]@{ Path = $path; Stream = $stream }
    } catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}

function Start-PublicationLeaseRenewal {
    param([string]$Container, [string]$BlobName, [string]$LeaseId, [string]$LogPath)
    $parentStart = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime().Ticks
    Start-Job -ArgumentList $Container, $BlobName, $LeaseId, $LogPath, $PID, $parentStart -ScriptBlock {
        param($Container, $BlobName, $LeaseId, $LogPath, $OwnerId, $OwnerStart)
        $ErrorActionPreference = 'Stop'
        $ready = $false
        try {
            while ($true) {
                $owner = Get-Process -Id $OwnerId -ErrorAction Stop
                if ($owner.StartTime.ToUniversalTime().Ticks -ne $OwnerStart) {
                    throw 'Publication owner exited.'
                }
                $ErrorActionPreference = 'Continue'
                $output = @(& az storage blob lease renew --container-name $Container --blob-name $BlobName `
                    --lease-id $LeaseId --auth-mode key --timeout 15 --only-show-errors --output json 2>&1)
                $exitCode = $LASTEXITCODE
                $ErrorActionPreference = 'Stop'
                $text = ($output | ForEach-Object { "$_" }) -join "`n"
                if ($env:AZURE_STORAGE_KEY) { $text = $text.Replace($env:AZURE_STORAGE_KEY, '[REDACTED]') }
                if ($exitCode -ne 0) { throw "Lease renewal failed (Azure CLI exit $exitCode): $text" }
                Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("{0} Lease renewed." -f [DateTime]::UtcNow.ToString('o'))
                if (-not $ready) { Write-Output 'LeaseReady'; $ready = $true }
                Start-Sleep -Seconds 15
            }
        } catch {
            $message = $_.Exception.Message
            if ($env:AZURE_STORAGE_KEY) { $message = $message.Replace($env:AZURE_STORAGE_KEY, '[REDACTED]') }
            Add-Content -LiteralPath $LogPath -Encoding UTF8 -Value ("{0} {1}" -f [DateTime]::UtcNow.ToString('o'), $message)
            throw $message
        }
    }
}

function Assert-PublicationLeaseRenewal {
    param([object]$Job, [switch]$WaitUntilReady)
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    do {
        try { $messages = @(Receive-Job -Job $Job -Keep -ErrorAction Stop) }
        catch { throw "Lease renewal failed: $(Protect-PublicationText $_.Exception.Message)" }
        if ($Job.State -ne 'Running') { throw "Lease renewal job is not running ($($Job.State))." }
        if (-not $WaitUntilReady -or $messages -contains 'LeaseReady') { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Lease renewal did not become ready within 40 seconds; upload was not started.'
}

function Stop-PublicationLeaseRenewal {
    param([object]$Job)
    try { Stop-Job -Job $Job -ErrorAction Stop }
    finally { Remove-Job -Job $Job -Force -ErrorAction Stop }
}

function Invoke-WindowsImagePublication {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ResultPath)
    $ErrorActionPreference = 'Stop'
    $path = Get-PublicationAbsolutePath $ResultPath 'ResultPath'
    $logDirectory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) { throw 'Result log directory does not exist.' }
    $logPath = Join-Path $logDirectory 'publication.log'
    $manifestPath = Join-Path $logDirectory 'publication.json'
    $renewalLog = Join-Path $logDirectory 'publication-lease.log'
    $manifest = [ordered]@{
        Status = 'Failed'; ResultPath = $path; BuildId = $null; VmName = $null
        StorageAccount = $env:AZURE_STORAGE_ACCOUNT; ContainerName = $env:AZURE_CONTAINER_NAME
        BlobName = $null; DiskPath = $null; DiskFormat = $null; DiskSizeBytes = $null
        PublishedAtUtc = $null; Error = $null; CleanupErrors = @()
    }
    $failure = $null
    $disk = $null
    $job = $null
    $leaseId = $null
    $seedPath = $null
    $oldContainer = $env:AZURE_STORAGE_CONTAINER
    $oldConnectionString = $env:AZURE_STORAGE_CONNECTION_STRING
    $oldSasToken = $env:AZURE_STORAGE_SAS_TOKEN
    try {
        Write-PublicationLog $logPath 'Publication requested.'
        $resultText = Get-Content -LiteralPath $path -Raw
        if ($resultText -notmatch '\A\s*\{') { throw 'Build result must be a JSON object.' }
        $result = $resultText | ConvertFrom-Json
        $disk = Get-PublicationDisk $result
        foreach ($name in @('AZURE_STORAGE_ACCOUNT', 'AZURE_STORAGE_KEY', 'AZURE_CONTAINER_NAME')) {
            if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
                throw "Required environment variable $name is not set."
            }
        }
        $env:AZURE_STORAGE_CONTAINER = $env:AZURE_CONTAINER_NAME
        # Do not let ambient connection-string/SAS authentication select a different destination.
        $env:AZURE_STORAGE_CONNECTION_STRING = $null
        $env:AZURE_STORAGE_SAS_TOKEN = $null
        Get-Command az -CommandType Application -ErrorAction Stop | Out-Null
        foreach ($name in @('BuildId', 'VmName', 'DiskFormat', 'DiskSizeBytes')) { $manifest[$name] = $result.$name }
        $manifest.DiskPath = $disk.Path
        $blobName = 'hybrid-minikube-windows-server.' + $result.DiskFormat.ToLowerInvariant()
        $manifest.BlobName = $blobName
        $destination = @('--container-name', $env:AZURE_CONTAINER_NAME, '--name', $blobName)
        $leaseDestination = @('--container-name', $env:AZURE_CONTAINER_NAME, '--blob-name', $blobName)
        $exists = Invoke-PublicationAzureCli (@('storage', 'blob', 'exists') + $destination) $logPath 'Check canonical blob' |
            ConvertFrom-Json
        if ($exists.exists -isnot [bool]) { throw 'Azure CLI returned a malformed existence response.' }
        if (-not $exists.exists) {
            $seedPath = Join-Path $logDirectory ('publication-seed-' + [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllBytes($seedPath, [byte[]]@())
            try {
                Invoke-PublicationAzureCli (@('storage', 'blob', 'upload') + $destination +
                    @('--file', $seedPath, '--type', 'block', '--overwrite', 'false', '--if-none-match', '*', '--no-progress')) `
                    $logPath 'Conditionally create absent canonical blob' | Out-Null
            } catch {
                $creationFailure = $_
                if ($creationFailure.Exception.Message -notmatch '\b(BlobAlreadyExists|ConditionNotMet|LeaseIdMissing)\b') {
                    throw
                }
                $exists = Invoke-PublicationAzureCli (@('storage', 'blob', 'exists') + $destination) $logPath 'Check concurrent creation' |
                    ConvertFrom-Json
                if ($exists.exists -isnot [bool] -or -not $exists.exists) { throw $creationFailure }
                Write-PublicationLog $logPath 'Canonical blob now exists; acquire its lease without replacing it.'
            }
        }
        $proposedId = [guid]::NewGuid().ToString()
        # Set ownership only after a successful atomic acquisition. Never release another owner's lease.
        Invoke-PublicationAzureCli (@('storage', 'blob', 'lease', 'acquire') + $leaseDestination +
            @('--lease-duration', '60', '--proposed-lease-id', $proposedId, '--timeout', '15')) `
            $logPath 'Acquire canonical blob lease (fail-fast contention)' | Out-Null
        $leaseId = $proposedId
        $job = Start-PublicationLeaseRenewal $env:AZURE_CONTAINER_NAME $blobName $leaseId $renewalLog
        Assert-PublicationLeaseRenewal $job -WaitUntilReady
        Invoke-PublicationAzureCli (@('storage', 'blob', 'upload') + $destination +
            @('--file', $disk.Path, '--type', 'block', '--overwrite', 'true', '--lease-id', $leaseId,
                '--validate-content', '--no-progress')) $logPath 'Upload exact build disk with enforced lease' | Out-Null
        Assert-PublicationLeaseRenewal $job
        $remote = Invoke-PublicationAzureCli (@('storage', 'blob', 'show') + $destination) $logPath 'Verify published blob' |
            ConvertFrom-Json
        if ($remote.properties.contentLength -ne $result.DiskSizeBytes -or $remote.properties.blobType -ne 'BlockBlob') {
            throw 'Published blob type or length does not match the build disk.'
        }
        Assert-PublicationLeaseRenewal $job
        $manifest.Status = 'Succeeded'
        $manifest.PublishedAtUtc = [DateTime]::UtcNow.ToString('o')
    } catch {
        $failure = $_
        $manifest.Error = Protect-PublicationText $_.Exception.Message
    } finally {
        if ($null -ne $job) {
            try { Stop-PublicationLeaseRenewal $job }
            catch { $manifest.CleanupErrors += Protect-PublicationText $_.Exception.Message }
        }
        if ($null -ne $leaseId) {
            try {
                Invoke-PublicationAzureCli (@('storage', 'blob', 'lease', 'release') + $leaseDestination +
                    @('--lease-id', $leaseId, '--timeout', '15')) $logPath 'Release owned canonical blob lease' | Out-Null
            } catch { $manifest.CleanupErrors += Protect-PublicationText $_.Exception.Message }
        }
        if ($null -ne $disk) {
            try { $disk.Stream.Dispose() }
            catch { $manifest.CleanupErrors += Protect-PublicationText $_.Exception.Message }
        }
        if ($null -ne $seedPath) {
            try { Remove-Item -LiteralPath $seedPath -Force -ErrorAction Stop }
            catch { $manifest.CleanupErrors += Protect-PublicationText $_.Exception.Message }
        }
        $env:AZURE_STORAGE_CONTAINER = $oldContainer
        $env:AZURE_STORAGE_CONNECTION_STRING = $oldConnectionString
        $env:AZURE_STORAGE_SAS_TOKEN = $oldSasToken
        if ($manifest.CleanupErrors.Count -gt 0 -and $null -eq $failure) {
            $failure = New-Object System.Exception -ArgumentList ('Publication cleanup failed: ' + ($manifest.CleanupErrors -join '; '))
            $manifest.Error = $failure.Message
        }
        if ($null -ne $failure) { $manifest.Status = 'Failed'; $manifest.PublishedAtUtc = $null }
        try {
            $manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
            Write-PublicationLog $logPath ("Publication {0}. {1}" -f $manifest.Status, $manifest.Error)
        } catch {
            if ($null -eq $failure) { $failure = $_ }
            else { Write-Warning ("Could not persist publication outcome: " + (Protect-PublicationText $_.Exception.Message)) }
        }
    }
    if ($null -ne $failure) {
        if ($failure -is [System.Management.Automation.ErrorRecord]) {
            throw (Protect-PublicationText $failure.Exception.Message)
        }
        throw (Protect-PublicationText $failure.Message)
    }
    return [pscustomobject]$manifest
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($ResultPath)) { throw 'Specify -ResultPath with the absolute successful build result.json path.' }
    Invoke-WindowsImagePublication -ResultPath $ResultPath
}
