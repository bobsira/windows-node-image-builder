[CmdletBinding()]
param(
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$')]
    [string]$BuildId,
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$')]
    [string]$VmName = 'hybrid-minikube-windows-server',
    [string]$ArtifactRoot = (Join-Path $env:ProgramData 'WindowsNodeImageBuilder\builds'),
    [string]$VarFile,
    [string]$WindowsVersion,
    [string]$KubernetesVersion,
    [string]$ContainerdVersion,
    [switch]$ValidateOnly
)

$repositoryRoot = Split-Path $PSScriptRoot -Parent

function New-ImageBuildId {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        if ($env:GITHUB_RUN_ID -notmatch '^\d+$' -or $env:GITHUB_RUN_ATTEMPT -notmatch '^\d+$') {
            throw 'GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT must be present in GitHub Actions.'
        }
        return "$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
    }
    return ('local-{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmssfff'), [guid]::NewGuid().ToString('N').Substring(0, 8))
}

function Enter-ImageBuildLock {
    $directory = Join-Path $env:ProgramData 'WindowsNodeImageBuilder'
    New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    $path = Join-Path $directory 'build.lock'
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    } catch [IO.IOException] {
        if (($_.Exception.HResult -band 0xffff) -in 32, 33) {
            throw "Another image build holds the host-wide lock at $path. Wait for it to finish; do not delete the lock file."
        }
        throw
    }
    try {
        $owner = [Text.Encoding]::UTF8.GetBytes("PID=$PID`r`nStartedUTC=$([DateTime]::UtcNow.ToString('o'))`r`n")
        $stream.SetLength(0)
        $stream.Write($owner, 0, $owner.Length)
        $stream.Flush()
        return $stream
    } catch {
        $stream.Dispose()
        throw
    }
}

function Assert-ImageBuildHost {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the build in an elevated PowerShell session or an appropriately privileged runner service.'
    }
    Get-Command Get-VM, Get-VHD, Test-VHD -ErrorAction Stop | Out-Null
    if ((Get-Service vmms -ErrorAction Stop).Status -ne 'Running') {
        throw 'The Hyper-V Virtual Machine Management service is not running.'
    }
    $legacyBuilds = @(Get-CimInstance Win32_Process -Filter "Name = 'packer.exe'" -ErrorAction Stop |
        Where-Object { $_.CommandLine -match '\bbuild\b' -and $_.CommandLine -match 'windows\.json\.pkr\.hcl' })
    if ($legacyBuilds.Count -gt 0) {
        throw "An existing Packer image build is running (PID(s): $($legacyBuilds.ProcessId -join ', ')). It may predate the shared lock; leave it untouched."
    }
    if (-not (Get-Command oscdimg.exe, mkisofs.exe -ErrorAction SilentlyContinue)) {
        throw 'Install the Windows ADK Deployment Tools and put oscdimg.exe on PATH before building.'
    }
}

function Invoke-ImageCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$LogPath
    )
    Get-Command $Command -ErrorAction Stop | Out-Null
    Write-Host "Running $Command $($Arguments -join ' ')"
    $oldPreference = $ErrorActionPreference
    try {
        # Windows PowerShell represents native stderr as ErrorRecords, even on success.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        & $Command @Arguments 2>&1 |
            ForEach-Object { $_.ToString() } |
            Tee-Object -FilePath $LogPath -Append -ErrorAction Stop |
            ForEach-Object { Write-Host $_ }
        $commandExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($commandExitCode -ne 0) {
        throw "$Command $($Arguments[0]) failed with exit code $commandExitCode. See $LogPath."
    }
}

function Get-ImageBuildDisk {
    param([Parameter(Mandatory = $true)][string]$OutputDirectory)

    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        throw "The build did not create its output directory: $OutputDirectory"
    }
    $disks = @(Get-ChildItem -LiteralPath $OutputDirectory -Recurse -File -ErrorAction Stop |
        Where-Object { $_.Extension -in '.vhd', '.vhdx' })
    if ($disks.Count -ne 1) {
        throw "Expected exactly one virtual disk in $OutputDirectory; found $($disks.Count)."
    }
    $disk = $disks[0]
    $vhd = Get-VHD -Path $disk.FullName -ErrorAction Stop
    $format = [string]$vhd.VhdFormat
    if ($disk.Length -le 0 -or $vhd.Attached -or $vhd.ParentPath -or
        $format -notin 'VHD', 'VHDX' -or $disk.Extension -ine ".$format" -or
        -not (Test-VHD -Path $disk.FullName -ErrorAction Stop)) {
        throw "The exported disk is empty, attached, dependent on another disk, or invalid: $($disk.FullName)"
    }
    return [pscustomobject]@{ Path = $disk.FullName; Format = $format; SizeBytes = $disk.Length }
}

function Invoke-WindowsImageBuild {
    [CmdletBinding()]
    param(
        [string]$BuildId,
        [string]$VmName = 'hybrid-minikube-windows-server',
        [string]$ArtifactRoot = (Join-Path $env:ProgramData 'WindowsNodeImageBuilder\builds'),
        [string]$VarFile = (Join-Path $repositoryRoot 'windows.auto.pkrvars.hcl'),
        [string]$WindowsVersion,
        [string]$KubernetesVersion,
        [string]$ContainerdVersion,
        [switch]$ValidateOnly
    )
    $ErrorActionPreference = 'Stop'
    if (-not $BuildId) { $BuildId = New-ImageBuildId }
    if ($BuildId -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$' -or
        $VmName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]{0,31}$') {
        throw 'BuildId or VmName contains unsupported characters or is too long.'
    }
    $VarFile = (Resolve-Path -LiteralPath $VarFile -ErrorAction Stop).ProviderPath
    $artifactRootPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArtifactRoot)
    $runDirectory = Join-Path $artifactRootPath $BuildId
    # No -Force: a reused build ID must never overwrite an earlier run's evidence.
    New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
    $logDirectory = Join-Path $runDirectory 'logs'
    New-Item -ItemType Directory -Path $logDirectory -ErrorAction Stop | Out-Null
    $outputDirectory = Join-Path $runDirectory 'output'
    $resultPath = Join-Path $logDirectory 'result.json'
    $consoleLog = Join-Path $logDirectory 'console.log'
    $result = [ordered]@{
        Status = 'Started'
        BuildId = $BuildId
        VmName = "$VmName-$BuildId"
        OutputDirectory = $outputDirectory
        LogDirectory = $logDirectory
        StartedUTC = [DateTime]::UtcNow.ToString('o')
        FinishedUTC = $null
        DiskPath = $null
        DiskFormat = $null
        DiskSizeBytes = $null
        Error = $null
        RetainedVM = $null
    }
    $lock = $null
    $oldLog = $env:PACKER_LOG
    $oldLogPath = $env:PACKER_LOG_PATH
    $oldPath = $env:PATH
    $locationPushed = $false
    $transcribing = $false
    try {
        if ($env:GITHUB_ACTIONS -eq 'true' -and $env:GITHUB_OUTPUT) {
            @("build_id=$BuildId", "log_directory=$logDirectory", "result_path=$resultPath") |
                Out-File -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8 -Append
        }
        Start-Transcript -Path (Join-Path $logDirectory 'host.log') -ErrorAction Stop | Out-Null
        $transcribing = $true
        Write-Host "Build ID: $BuildId"
        Write-Host "Temporary VM: $($result.VmName)"
        Write-Host "Logs: $logDirectory"
        $env:PACKER_LOG = '1'
        $env:PACKER_LOG_PATH = Join-Path $logDirectory 'packer-debug.log'
        foreach ($architecture in 'amd64', 'x86') {
            $adkPath = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$architecture\Oscdimg"
            if (Test-Path -LiteralPath (Join-Path $adkPath 'oscdimg.exe')) { $env:PATH += ";$adkPath" }
        }
        if (-not $ValidateOnly) {
            $lock = Enter-ImageBuildLock
            Assert-ImageBuildHost
            if (Get-VM -ErrorAction Stop | Where-Object Name -eq $result.VmName) {
                throw "VM $($result.VmName) already exists and will not be overwritten."
            }
        }
        Push-Location -LiteralPath $repositoryRoot
        $locationPushed = $true
        $template = Join-Path $repositoryRoot 'windows.json.pkr.hcl'
        $variables = @("-var-file=$VarFile", '-var', "build_id=$BuildId", '-var', "vm_name=$VmName",
            '-var', "output_directory=$outputDirectory")
        foreach ($entry in @(
            @{ Name = 'windows_version'; Value = $WindowsVersion },
            @{ Name = 'kubernetes_version'; Value = $KubernetesVersion },
            @{ Name = 'containerd_version'; Value = $ContainerdVersion }
        )) {
            if (-not [string]::IsNullOrWhiteSpace($entry.Value)) {
                $variables += @('-var', "$($entry.Name)=$($entry.Value.Trim())")
            }
        }
        Invoke-ImageCommand -Command packer -Arguments @('init', $template) -LogPath $consoleLog
        Invoke-ImageCommand -Command packer -Arguments (@('validate') + $variables + $template) -LogPath $consoleLog
        if ($ValidateOnly) {
            $result.Status = 'Validated'
        } else {
            Invoke-ImageCommand -Command packer -Arguments (@('build', '-color=false', '-on-error=abort') + $variables + $template) -LogPath $consoleLog
            $disk = Get-ImageBuildDisk -OutputDirectory $outputDirectory
            $result.DiskPath = $disk.Path
            $result.DiskFormat = $disk.Format
            $result.DiskSizeBytes = $disk.SizeBytes
            $result.Status = 'Succeeded'
        }
    } catch {
        $result.Status = 'Failed'
        $result.Error = $_.Exception.Message
        if (-not $ValidateOnly -and $lock) {
            try {
                $vm = Get-VM -ErrorAction Stop | Where-Object Name -eq $result.VmName
                if ($vm) {
                    $result.RetainedVM = [ordered]@{
                        Id = [string]$vm.Id
                        Path = $vm.Path
                        Disks = @($vm | Get-VMHardDiskDrive -ErrorAction Stop | Select-Object -ExpandProperty Path)
                    }
                }
            } catch {
                Write-Warning "Could not collect retained VM details: $($_.Exception.Message)"
            }
        }
        throw
    } finally {
        try {
            $result.FinishedUTC = [DateTime]::UtcNow.ToString('o')
            $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
        } finally {
            if ($lock) { $lock.Dispose() }
            $env:PACKER_LOG = $oldLog
            $env:PACKER_LOG_PATH = $oldLogPath
            $env:PATH = $oldPath
            if ($locationPushed) { Pop-Location }
            if ($transcribing) { Stop-Transcript | Out-Null }
        }
    }
    Write-Host "Build status: $($result.Status). Result: $resultPath"
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WindowsImageBuild @PSBoundParameters
}
