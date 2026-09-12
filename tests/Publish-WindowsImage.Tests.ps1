. (Join-Path $PSScriptRoot '..\scripts\Publish-WindowsImage.ps1')

# Fail closed if a test accidentally invokes the CLI without installing a mock.
function az { throw 'Azure CLI must be mocked in publication tests.' }

# Keep fixtures in the repository, not Pester's temporary TestDrive.
$script:publicationFixtureRoot = Join-Path $PSScriptRoot ('.publication-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:publicationFixtureRoot | Out-Null
if (-not (Get-Command Get-VHD -ErrorAction SilentlyContinue)) {
    function Get-VHD { param($Path) throw 'Get-VHD must be mocked.' }
}
if (-not (Get-Command Test-VHD -ErrorAction SilentlyContinue)) {
    function Test-VHD { param($Path) throw 'Test-VHD must be mocked.' }
}

try {
    Describe 'Exact publication disk validation' {
        BeforeEach {
            $script:fixture = Join-Path $script:publicationFixtureRoot ([guid]::NewGuid().ToString('N'))
            $script:output = Join-Path $script:fixture 'output'
            New-Item -ItemType Directory -Path $script:output -Force | Out-Null
            $script:diskPath = Join-Path $script:output 'original-export-name.vhdx'
            [IO.File]::WriteAllBytes($script:diskPath, [byte[]](1, 2, 3, 4))
            $script:result = [pscustomobject]@{
                Status = 'Succeeded'; BuildId = 'local-build'; VmName = 'isolated-vm'
                OutputDirectory = $script:output; DiskPath = $script:diskPath
                DiskFormat = 'VHDX'; DiskSizeBytes = 4
            }
            Mock Get-VHD { [pscustomobject]@{ VhdFormat = 'VHDX'; FileSize = 4; ParentPath = ''; Attached = $false; VhdType = 'Dynamic' } }
            Mock Test-VHD { $true }
        }
        It 'uses and read-locks the exact manifest disk without renaming it' {
            $disk = Get-PublicationDisk $script:result
            try {
                $disk.Path | Should Be $script:diskPath
                { [IO.File]::OpenWrite($script:diskPath) } | Should Throw
                Test-Path -LiteralPath $script:diskPath | Should Be $true
                Assert-MockCalled Get-VHD -Times 1 -Exactly -Scope It -ParameterFilter { $Path -eq $script:diskPath }
            } finally { $disk.Stream.Dispose() }
        }
        It 'rejects unsuccessful builds' {
            $script:result.Status = 'Failed'
            { Get-PublicationDisk $script:result } | Should Throw 'Succeeded'
            Assert-MockCalled Get-VHD -Times 0 -Exactly -Scope It
        }
        It 'rejects a missing required field' {
            $script:result.PSObject.Properties.Remove('BuildId')
            { Get-PublicationDisk $script:result } | Should Throw 'BuildId'
        }
        It 'rejects an ambiguous disk path array' {
            $script:result.DiskPath = @($script:diskPath, $script:diskPath)
            { Get-PublicationDisk $script:result } | Should Throw 'absolute'
        }
        It 'rejects a missing disk rather than selecting a neighboring export' {
            $script:result.DiskPath = Join-Path $script:output 'missing.vhdx'
            { Get-PublicationDisk $script:result } | Should Throw
        }
        It 'rejects paths outside the output directory including prefix lookalikes' {
            $script:result.OutputDirectory = $script:output.Substring(0, $script:output.Length - 1)
            { Get-PublicationDisk $script:result } | Should Throw 'inside OutputDirectory'
        }
        It 'rejects traversal out of the output directory' {
            $script:result.DiskPath = Join-Path $script:output '..\outside.vhdx'
            { Get-PublicationDisk $script:result } | Should Throw 'inside OutputDirectory'
        }
        It 'rejects redirected output directories' {
            $redirected = Join-Path $script:fixture 'redirected'
            New-Item -ItemType Junction -Path $redirected -Value $script:output | Out-Null
            $script:result.OutputDirectory = $redirected
            $script:result.DiskPath = Join-Path $redirected 'original-export-name.vhdx'
            { Get-PublicationDisk $script:result } | Should Throw 'reparse point'
        }
        It 'rejects string, zero, or mismatched disk lengths' {
            foreach ($length in @('4', 0, 5)) {
                $script:result.DiskSizeBytes = $length
                { Get-PublicationDisk $script:result } | Should Throw
            }
        }
        It 'rejects a VHD format mismatch reported by Hyper-V' {
            Mock Get-VHD { [pscustomobject]@{ VhdFormat = 'VHD'; FileSize = 4; ParentPath = ''; Attached = $false } }
            { Get-PublicationDisk $script:result } | Should Throw 'Get-VHD'
        }
        It 'rejects a Hyper-V file-size mismatch' {
            Mock Get-VHD { [pscustomobject]@{ VhdFormat = 'VHDX'; FileSize = 8; ParentPath = ''; Attached = $false } }
            { Get-PublicationDisk $script:result } | Should Throw 'Get-VHD'
        }
        It 'rejects an ambiguous Hyper-V result' {
            Mock Get-VHD {
                [pscustomobject]@{ VhdFormat = 'VHDX'; FileSize = 4; ParentPath = ''; Attached = $false }
                [pscustomobject]@{ VhdFormat = 'VHDX'; FileSize = 4; ParentPath = ''; Attached = $false }
            }
            { Get-PublicationDisk $script:result } | Should Throw 'Get-VHD'
        }
        It 'rejects a differencing disk' {
            Mock Get-VHD { [pscustomobject]@{ VhdFormat = 'VHDX'; FileSize = 4; ParentPath = 'parent.vhdx'; Attached = $false } }
            { Get-PublicationDisk $script:result } | Should Throw 'independent'
        }
        It 'rejects an attached disk' {
            Mock Get-VHD { [pscustomobject]@{ VhdFormat = 'VHDX'; FileSize = 4; ParentPath = ''; Attached = $true } }
            { Get-PublicationDisk $script:result } | Should Throw 'detached'
        }
        It 'rejects an unreadable disk' {
            Mock Get-VHD { throw 'Disk is unreadable' }
            { Get-PublicationDisk $script:result } | Should Throw 'unreadable'
        }
        It 'rejects a disk that fails Test-VHD and releases its file handle' {
            Mock Test-VHD { $false }
            { Get-PublicationDisk $script:result } | Should Throw 'Test-VHD'
            $stream = [IO.File]::OpenWrite($script:diskPath)
            $stream.Dispose()
        }
    }

    Describe 'Leased Azure publication orchestration' {
        BeforeEach {
            $script:fixture = Join-Path $script:publicationFixtureRoot ([guid]::NewGuid().ToString('N'))
            $script:output = Join-Path $script:fixture 'output'
            New-Item -ItemType Directory -Path $script:output -Force | Out-Null
            $script:diskPath = Join-Path $script:output 'unchanged-name.vhdx'
            [IO.File]::WriteAllBytes($script:diskPath, [byte[]](1, 2, 3, 4))
            $script:resultPath = Join-Path $script:fixture 'result.json'
            $script:result = [pscustomobject]@{
                Status = 'Succeeded'; BuildId = 'run-12'; VmName = 'vm-12'
                OutputDirectory = $script:output; DiskPath = $script:diskPath
                DiskFormat = 'VHDX'; DiskSizeBytes = 4
            }
            $script:result | ConvertTo-Json | Set-Content -LiteralPath $script:resultPath
            $script:oldEnvironment = @{}
            foreach ($name in @('AZURE_STORAGE_ACCOUNT', 'AZURE_STORAGE_KEY', 'AZURE_CONTAINER_NAME',
                'AZURE_STORAGE_CONTAINER', 'AZURE_STORAGE_CONNECTION_STRING', 'AZURE_STORAGE_SAS_TOKEN')) {
                $script:oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            $env:AZURE_STORAGE_ACCOUNT = 'testaccount'
            $env:AZURE_STORAGE_KEY = 'never-log-this-secret'
            $env:AZURE_CONTAINER_NAME = 'images'
            $env:AZURE_STORAGE_CONTAINER = 'previous-container'
            $env:AZURE_STORAGE_CONNECTION_STRING = 'ambient-connection-string'
            $env:AZURE_STORAGE_SAS_TOKEN = 'ambient-sas'
            $script:commands = New-Object System.Collections.ArrayList
            $script:exists = $true
            $script:acquireFailure = $false
            $script:uploadFailure = $false
            $script:releaseFailure = $false
            $script:seedFailure = $false
            $script:seedError = 'ConditionNotMet'
            $script:remoteLength = 4
            Mock Get-VHD { [pscustomobject]@{ VhdFormat = $script:result.DiskFormat; FileSize = 4; ParentPath = ''; Attached = $false } }
            Mock Test-VHD { $true }
            Mock Get-Command { [pscustomobject]@{ Name = 'az' } } -ParameterFilter { $Name -eq 'az' }
            Mock Invoke-PublicationAzureCli {
                $null = $script:commands.Add(@($Arguments))
                if ($Arguments -contains '--account-key' -or $Arguments -contains $env:AZURE_STORAGE_KEY) { throw 'Secret passed in arguments.' }
                if ($env:AZURE_STORAGE_CONNECTION_STRING -or $env:AZURE_STORAGE_SAS_TOKEN) { throw 'Ambient authentication was not cleared.' }
                if ($Arguments -contains 'exists') { return ('{"exists":' + $script:exists.ToString().ToLowerInvariant() + '}') }
                if ($Arguments -contains 'acquire' -and $script:acquireFailure) { throw 'LeaseAlreadyPresent' }
                if ($Arguments -contains '--if-none-match' -and $script:seedFailure) {
                    $script:exists = $true
                    throw $script:seedError
                }
                if ($Arguments -contains 'upload' -and $Arguments -contains '--lease-id' -and $script:uploadFailure) {
                    throw 'Upload failed: LeaseIdMismatchWithBlobOperation'
                }
                if ($Arguments -contains 'release' -and $script:releaseFailure) { throw 'Release failed' }
                if ($Arguments -contains 'show') { return ('{"properties":{"contentLength":' + $script:remoteLength + ',"blobType":"BlockBlob"}}') }
                return '{}'
            }
            Mock Start-PublicationLeaseRenewal { [pscustomobject]@{ Id = 123; State = 'Running' } }
            Mock Assert-PublicationLeaseRenewal {}
            Mock Stop-PublicationLeaseRenewal {}
        }
        AfterEach {
            foreach ($name in $script:oldEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $script:oldEnvironment[$name])
            }
        }
        It 'leases the canonical blob and uploads the exact file under the same lease' {
            $published = Invoke-WindowsImagePublication $script:resultPath
            $published.Status | Should Be 'Succeeded'
            $published.BlobName | Should Be 'hybrid-minikube-windows-server.vhdx'
            $acquire = @($script:commands | Where-Object { $_ -contains 'acquire' })[0]
            $upload = @($script:commands | Where-Object { $_ -contains 'upload' })[0]
            $release = @($script:commands | Where-Object { $_ -contains 'release' })[0]
            $acquire[$acquire.IndexOf('--lease-duration') + 1] | Should Be '60'
            $lease = $acquire[$acquire.IndexOf('--proposed-lease-id') + 1]
            $upload[$upload.IndexOf('--lease-id') + 1] | Should Be $lease
            $release[$release.IndexOf('--lease-id') + 1] | Should Be $lease
            $upload[$upload.IndexOf('--file') + 1] | Should Be $script:diskPath
            $upload[$upload.IndexOf('--type') + 1] | Should Be 'block'
            @($script:commands | Where-Object { $_ -contains '--if-none-match' }).Count | Should Be 0
            $env:AZURE_STORAGE_CONTAINER | Should Be 'previous-container'
            $env:AZURE_STORAGE_CONNECTION_STRING | Should Be 'ambient-connection-string'
            $env:AZURE_STORAGE_SAS_TOKEN | Should Be 'ambient-sas'
            Test-Path -LiteralPath $script:diskPath | Should Be $true
            (Get-Content (Join-Path $script:fixture 'publication.json') -Raw | ConvertFrom-Json).Status | Should Be 'Succeeded'
            Assert-MockCalled Start-PublicationLeaseRenewal -Times 1 -Exactly -Scope It
            Assert-MockCalled Stop-PublicationLeaseRenewal -Times 1 -Exactly -Scope It
        }
        It 'uses .vhd only when the manifest and Hyper-V report a real VHD' {
            $newPath = Join-Path $script:output 'real-disk.vhd'
            Move-Item -LiteralPath $script:diskPath -Destination $newPath
            $script:result.DiskPath = $newPath
            $script:result.DiskFormat = 'VHD'
            $script:result | ConvertTo-Json | Set-Content -LiteralPath $script:resultPath
            (Invoke-WindowsImagePublication $script:resultPath).BlobName | Should Be 'hybrid-minikube-windows-server.vhd'
            Test-Path -LiteralPath $newPath | Should Be $true
        }
        It 'creates an absent canonical blob conditionally without overwriting a concurrent creator' {
            $script:exists = $false
            $script:seedFailure = $true
            (Invoke-WindowsImagePublication $script:resultPath).Status | Should Be 'Succeeded'
            $seed = @($script:commands | Where-Object { $_ -contains '--if-none-match' })[0]
            $seed[$seed.IndexOf('--if-none-match') + 1] | Should Be '*'
            $seed[$seed.IndexOf('--overwrite') + 1] | Should Be 'false'
            @(Get-ChildItem -LiteralPath $script:fixture -Filter 'publication-seed-*').Count | Should Be 0
        }
        It 'fails fast on contention and never uploads or releases the other owner lease' {
            $script:acquireFailure = $true
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'LeaseAlreadyPresent'
            @($script:commands | Where-Object { $_ -contains 'upload' -or $_ -contains 'release' }).Count | Should Be 0
            Assert-MockCalled Start-PublicationLeaseRenewal -Times 0 -Exactly -Scope It
        }
        It 'does not hide an unrelated seed failure behind concurrent blob existence' {
            $script:exists = $false
            $script:seedFailure = $true
            $script:seedError = 'AuthorizationFailure'
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'AuthorizationFailure'
            @($script:commands | Where-Object { $_ -contains 'acquire' -or $_ -contains '--lease-id' }).Count | Should Be 0
            (Get-Content (Join-Path $script:fixture 'publication.json') -Raw | ConvertFrom-Json).Status | Should Be 'Failed'
        }
        It 'does not upload when initial renewal is not ready' {
            Mock Assert-PublicationLeaseRenewal { throw 'Renewal not ready' }
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'Renewal not ready'
            @($script:commands | Where-Object { $_ -contains 'upload' }).Count | Should Be 0
            @($script:commands | Where-Object { $_ -contains 'release' }).Count | Should Be 1
        }
        It 'propagates lease loss during upload and cleans up its own renewal job' {
            $script:uploadFailure = $true
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'LeaseIdMismatch'
            Assert-MockCalled Stop-PublicationLeaseRenewal -Times 1 -Exactly -Scope It
            @($script:commands | Where-Object { $_ -contains 'release' }).Count | Should Be 1
            (Get-Content (Join-Path $script:fixture 'publication.json') -Raw | ConvertFrom-Json).Status | Should Be 'Failed'
        }
        It 'propagates renewal failure after upload even when upload itself returned success' {
            Mock Assert-PublicationLeaseRenewal { if (-not $WaitUntilReady) { throw 'Renewal failed during upload' } }
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'Renewal failed during upload'
            Assert-MockCalled Stop-PublicationLeaseRenewal -Times 1 -Exactly -Scope It
        }
        It 'fails when remote length does not match the source' {
            $script:remoteLength = 9
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'length'
        }
        It 'preserves the upload failure when lease cleanup also fails' {
            $script:uploadFailure = $true
            $script:releaseFailure = $true
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'Upload failed'
            $saved = Get-Content (Join-Path $script:fixture 'publication.json') -Raw | ConvertFrom-Json
            $saved.Error | Should Match 'Upload failed'
            $saved.CleanupErrors[0] | Should Match 'Release failed'
        }
        It 'reports cleanup failure instead of reporting successful publication' {
            $script:releaseFailure = $true
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'cleanup failed'
            (Get-Content (Join-Path $script:fixture 'publication.json') -Raw | ConvertFrom-Json).Status | Should Be 'Failed'
        }
        It 'rejects malformed JSON before making any Azure call' {
            Set-Content -LiteralPath $script:resultPath -Value '{malformed'
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw
            Assert-MockCalled Invoke-PublicationAzureCli -Times 0 -Exactly -Scope It
        }
        It 'rejects a top-level array instead of interpreting it as one build' {
            Set-Content -LiteralPath $script:resultPath -Value ('[' + ($script:result | ConvertTo-Json) + ']')
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'JSON object'
            Assert-MockCalled Invoke-PublicationAzureCli -Times 0 -Exactly -Scope It
        }
        It 'rejects an unsuccessful build before making any Azure call' {
            $script:result.Status = 'Failed'
            $script:result | ConvertTo-Json | Set-Content -LiteralPath $script:resultPath
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'Succeeded'
            Assert-MockCalled Invoke-PublicationAzureCli -Times 0 -Exactly -Scope It
        }
        It 'rejects missing credentials without Azure calls' {
            $env:AZURE_STORAGE_KEY = ''
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'AZURE_STORAGE_KEY'
            Assert-MockCalled Invoke-PublicationAzureCli -Times 0 -Exactly -Scope It
        }
        It 'rejects a missing disk without Azure calls' {
            Remove-Item -LiteralPath $script:diskPath
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw
            Assert-MockCalled Invoke-PublicationAzureCli -Times 0 -Exactly -Scope It
        }
        It 'redacts the account key in persistent error diagnostics' {
            Mock Invoke-PublicationAzureCli { throw "Failure containing $env:AZURE_STORAGE_KEY" }
            { Invoke-WindowsImagePublication $script:resultPath } | Should Throw 'REDACTED'
            $saved = Get-Content (Join-Path $script:fixture 'publication.json') -Raw
            $saved.Contains($env:AZURE_STORAGE_KEY) | Should Be $false
            $saved | Should Match 'REDACTED'
        }
    }

    Describe 'Native CLI errors and lease renewal worker' {
        BeforeEach {
            $script:workerLog = Join-Path $script:publicationFixtureRoot ([guid]::NewGuid().ToString('N') + '.log')
            $script:oldKey = $env:AZURE_STORAGE_KEY
            $script:oldExitCode = $global:LASTEXITCODE
            $env:AZURE_STORAGE_KEY = 'worker-secret-do-not-log'
            $script:worker = $null
            $script:workerArguments = $null
            Mock Start-Job {
                $script:worker = $ScriptBlock
                $script:workerArguments = $ArgumentList
                [pscustomobject]@{ State = 'Running' }
            }
            Mock az { $global:LASTEXITCODE = 0; '{}' }
        }
        AfterEach {
            $env:AZURE_STORAGE_KEY = $script:oldKey
            $global:LASTEXITCODE = $script:oldExitCode
        }
        It 'checks native exit codes and redacts both stderr and stdout diagnostics' {
            Mock az {
                $global:LASTEXITCODE = 23
                "stdout $env:AZURE_STORAGE_KEY"
                Write-Error "stderr $env:AZURE_STORAGE_KEY"
            }
            { Invoke-PublicationAzureCli @('storage', 'blob', 'show') $script:workerLog 'Test native failure' } |
                Should Throw 'exit 23'
            $saved = Get-Content -LiteralPath $script:workerLog -Raw
            $saved | Should Match 'stdout'
            $saved | Should Match 'stderr'
            $saved | Should Match 'REDACTED'
            $saved.Contains($env:AZURE_STORAGE_KEY) | Should Be $false
        }
        It 'does not confuse stderr alone with a native failure' {
            Mock az { $global:LASTEXITCODE = 0; Write-Error 'benign diagnostic' }
            { Invoke-PublicationAzureCli @('storage', 'blob', 'show') $script:workerLog 'Test native success' } |
                Should Not Throw
        }
        It 'renews independently before signaling readiness and waits fifteen seconds' {
            Mock Start-Sleep { throw 'End renewal test' } -ParameterFilter { $Seconds -eq 15 }
            Start-PublicationLeaseRenewal 'images' 'canonical.vhdx' 'test-lease' $script:workerLog | Out-Null
            $script:workerArguments.Count | Should Be 6
            ($script:workerArguments -join ' ').Contains($env:AZURE_STORAGE_KEY) | Should Be $false
            { & $script:worker @script:workerArguments | Out-Null } | Should Throw 'End renewal test'
            (Get-Content -LiteralPath $script:workerLog -Raw) | Should Match 'Lease renewed'
            Assert-MockCalled az -Times 1 -Exactly -Scope It
            Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter { $Seconds -eq 15 }
        }
        It 'fails explicitly on renewal errors without exposing credentials' {
            Mock az { $global:LASTEXITCODE = 19; "renew failed $env:AZURE_STORAGE_KEY" }
            Start-PublicationLeaseRenewal 'images' 'canonical.vhdx' 'test-lease' $script:workerLog | Out-Null
            { & $script:worker @script:workerArguments | Out-Null } | Should Throw 'exit 19'
            $saved = Get-Content -LiteralPath $script:workerLog -Raw
            $saved | Should Match 'REDACTED'
            $saved.Contains($env:AZURE_STORAGE_KEY) | Should Be $false
        }
        It 'does not renew after its original parent exits even if the PID is reused' {
            Start-PublicationLeaseRenewal 'images' 'canonical.vhdx' 'test-lease' $script:workerLog | Out-Null
            $script:workerArguments[5] = 0
            { & $script:worker @script:workerArguments | Out-Null } | Should Throw 'owner exited'
            Assert-MockCalled az -Times 0 -Exactly -Scope It
        }
    }

    Describe 'Lease renewal health checks' {
        BeforeEach {
            $script:healthJob = Start-Job { Start-Sleep -Seconds 60 }
        }
        AfterEach {
            Stop-Job -Job $script:healthJob
            Remove-Job -Job $script:healthJob -Force
        }
        It 'requires a running job and readiness before upload' {
            Mock Receive-Job { 'LeaseReady' }
            { Assert-PublicationLeaseRenewal $script:healthJob -WaitUntilReady } | Should Not Throw
        }
        It 'rejects a stopped renewer' {
            Mock Receive-Job { 'LeaseReady' }
            Stop-Job -Job $script:healthJob
            { Assert-PublicationLeaseRenewal $script:healthJob } | Should Throw 'not running'
        }
        It 'propagates asynchronous renewal errors' {
            Mock Receive-Job { throw 'LeaseLost' }
            { Assert-PublicationLeaseRenewal $script:healthJob } | Should Throw 'LeaseLost'
        }
    }
} finally {
    Remove-Item -LiteralPath $script:publicationFixtureRoot -Recurse -Force
}
