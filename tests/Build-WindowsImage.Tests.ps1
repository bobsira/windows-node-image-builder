. (Join-Path $PSScriptRoot '..\scripts\Build-WindowsImage.ps1')

Describe 'Unattended DVD boot configuration' {
    It 'disables the Packer default wait and sends ten boot-key attempts' {
        $template = Get-Content (Join-Path $PSScriptRoot '..\windows.json.pkr.hcl') -Raw
        $template | Should -Match '(?m)^\s*boot_wait\s*=\s*"-1s"'
        $template | Should -Match '(?m)^\s*boot_command\s*=\s*\[for attempt in range\(10\)\s*:\s*"a<wait1>"\]'
    }
}

Describe 'Build identities' {
    BeforeEach {
        $script:oldActions = $env:GITHUB_ACTIONS
        $script:oldRunId = $env:GITHUB_RUN_ID
        $script:oldAttempt = $env:GITHUB_RUN_ATTEMPT
        $env:GITHUB_ACTIONS = ''
    }
    AfterEach {
        $env:GITHUB_ACTIONS = $script:oldActions
        $env:GITHUB_RUN_ID = $script:oldRunId
        $env:GITHUB_RUN_ATTEMPT = $script:oldAttempt
    }
    It 'generates unique local IDs' {
        $first = New-ImageBuildId
        $first | Should -Match '^local-[a-zA-Z0-9-]+$'
        (New-ImageBuildId) | Should -Not -Be $first
    }
    It 'includes both the workflow run and attempt' {
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_RUN_ID = '123456'
        $env:GITHUB_RUN_ATTEMPT = '2'
        New-ImageBuildId | Should -Be '123456-2'
    }
    It 'rejects missing workflow identity instead of sharing a default' {
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_RUN_ID = ''
        { New-ImageBuildId } | Should -Throw
    }
}

Describe 'Host-wide build lock' {
    BeforeEach {
        $script:oldProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive 'ProgramData'
    }
    AfterEach { $env:ProgramData = $script:oldProgramData }
    It 'rejects another owner and can be reacquired after release' {
        $first = Enter-ImageBuildLock
        try { { Enter-ImageBuildLock } | Should -Throw 'host-wide lock' }
        finally { $first.Dispose() }
        $next = Enter-ImageBuildLock
        try { $next.CanWrite | Should -Be $true }
        finally { $next.Dispose() }
    }
    It 'enforces the lock in a separate PowerShell process' {
        $lock = Enter-ImageBuildLock
        try {
            $childOutput = & powershell.exe -NoProfile -NonInteractive -File `
                (Join-Path $PSScriptRoot 'fixtures\acquire-build-lock.ps1') -ProgramDataPath $env:ProgramData 2>&1
            $LASTEXITCODE | Should -Be 7
            ($childOutput | Out-String) | Should -Match 'host-wide lock'
        } finally { $lock.Dispose() }
    }
}

Describe 'Native command failure handling' {
    It 'captures stdout and stderr without treating stderr alone as failure' {
        $log = Join-Path $TestDrive 'native-success.log'
        Invoke-ImageCommand powershell.exe @('-NoProfile', '-NonInteractive', '-File',
            (Join-Path $PSScriptRoot 'fixtures\native-command.ps1')) $log
        $text = Get-Content $log -Raw
        $text | Should -Match 'native stdout'
        $text | Should -Match 'native stderr'
    }
    It 'throws for a nonzero exit and preserves both output streams' {
        $log = Join-Path $TestDrive 'native-failure.log'
        { Invoke-ImageCommand powershell.exe @('-NoProfile', '-NonInteractive', '-File',
            (Join-Path $PSScriptRoot 'fixtures\native-command.ps1'), '-ExitCode', '23') $log } |
            Should -Throw 'exit code 23'
        (Get-Content $log -Raw) | Should -Match 'native stderr'
    }
}

Describe 'Windows PowerShell file entry point' {
    It 'resolves the default var-file when launched with -File' {
        $oldPath = $env:PATH
        $oldActions = $env:GITHUB_ACTIONS
        $root = Join-Path $TestDrive 'file-entry'
        try {
            $env:GITHUB_ACTIONS = ''
            $env:PATH = (Join-Path $PSScriptRoot 'fixtures') + ';' + $env:PATH
            $output = & powershell.exe -NoProfile -NonInteractive -File `
                (Join-Path $PSScriptRoot '..\scripts\Build-WindowsImage.ps1') `
                -ValidateOnly -BuildId 'file-entry' -ArtifactRoot $root 2>&1
            $LASTEXITCODE | Should -Be 0
            ($output | Out-String) | Should -Match 'Packer fixture validate'
            $result = Get-Content (Join-Path $root 'file-entry\logs\result.json') -Raw | ConvertFrom-Json
            $result.Status | Should -Be 'Validated'
            $result.DiskPath | Should -BeNullOrEmpty
        } finally {
            $env:PATH = $oldPath
            $env:GITHUB_ACTIONS = $oldActions
        }
    }
}

Describe 'Exact build disk selection' {
    BeforeEach {
        $script:output = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:output -Force | Out-Null
        Mock Get-VHD { [pscustomobject]@{ VhdFormat = 'VHDX'; Attached = $false; ParentPath = '' } }
        Mock Test-VHD { $true }
    }
    It 'rejects missing output' {
        { Get-ImageBuildDisk (Join-Path $TestDrive 'missing') } | Should -Throw 'output directory'
    }
    It 'does not select a disk from an adjacent build' {
        Set-Content (Join-Path $TestDrive 'other-build.vhdx') 'other disk'
        { Get-ImageBuildDisk $script:output } | Should -Throw 'found 0'
    }
    It 'accepts exactly one readable independent disk' {
        $path = Join-Path $script:output 'temporary-name.vhdx'
        Set-Content $path 'disk'
        $disk = Get-ImageBuildDisk $script:output
        $disk.Path | Should -Be $path
        $disk.Format | Should -Be 'VHDX'
    }
    It 'rejects multiple disks instead of selecting the first one' {
        Set-Content (Join-Path $script:output 'first.vhdx') 'disk'
        Set-Content (Join-Path $script:output 'second.vhdx') 'disk'
        { Get-ImageBuildDisk $script:output } | Should -Throw 'found 2'
    }
    It 'rejects a failed disk integrity check' {
        Set-Content (Join-Path $script:output 'bad.vhdx') 'disk'
        Mock Test-VHD { $false }
        { Get-ImageBuildDisk $script:output } | Should -Throw 'invalid'
    }
    It 'rejects an attached or differencing disk' {
        Set-Content (Join-Path $script:output 'dependent.vhdx') 'disk'
        Mock Get-VHD { [pscustomobject]@{ VhdFormat = 'VHDX'; Attached = $true; ParentPath = 'parent.vhdx' } }
        { Get-ImageBuildDisk $script:output } | Should -Throw 'invalid'
    }
    It 'rejects a misleading file extension' {
        Set-Content (Join-Path $script:output 'wrong.vhd') 'disk'
        { Get-ImageBuildDisk $script:output } | Should -Throw 'invalid'
    }
}

Describe 'Shared build orchestration' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:buildLock = New-Object IO.MemoryStream
        $script:output = Join-Path $script:root 'test-run\output'
        $script:resultPath = Join-Path $script:root 'test-run\logs\result.json'
        $script:oldActions = $env:GITHUB_ACTIONS
        $env:GITHUB_ACTIONS = ''
        $script:failurePhase = ''
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Enter-ImageBuildLock { $script:buildLock }
        Mock Assert-ImageBuildHost {}
        Mock Get-VM { @() }
        Mock Invoke-ImageCommand {
            if ($Arguments[0] -eq $script:failurePhase) { throw "$script:failurePhase failed" }
        }
        Mock Get-ImageBuildDisk {
            [pscustomobject]@{ Path = (Join-Path $script:output 'image.vhdx'); Format = 'VHDX'; SizeBytes = 1024 }
        }
    }
    AfterEach {
        $env:GITHUB_ACTIONS = $script:oldActions
        $script:buildLock.Dispose()
    }
    It 'uses one ID for VM, output, metadata and Packer arguments' {
        $result = Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root
        $result.Status | Should -Be 'Succeeded'
        $result.VmName | Should -Be 'hybrid-minikube-windows-server-test-run'
        $result.OutputDirectory | Should -Be $script:output
        Assert-MockCalled Invoke-ImageCommand -Scope It -Times 1 -Exactly -ParameterFilter {
            $Arguments[0] -eq 'build' -and $Arguments -contains 'build_id=test-run' -and
            $Arguments -contains "output_directory=$script:output" -and
            $Arguments -contains '-on-error=abort' -and $Arguments -notcontains '-force'
        }
        $script:buildLock.CanWrite | Should -Be $false
        (Get-Content $script:resultPath -Raw | ConvertFrom-Json).Status | Should -Be 'Succeeded'
    }
    It 'passes version overrides identically to validate and build, ignoring blanks' {
        Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root `
            -WindowsVersion '2022' -KubernetesVersion ' v1.37.0 ' -ContainerdVersion ' ' | Out-Null
        Assert-MockCalled Invoke-ImageCommand -Scope It -Times 2 -Exactly -ParameterFilter {
            $Arguments[0] -in 'validate', 'build' -and $Arguments -contains 'windows_version=2022' -and
            $Arguments -contains 'kubernetes_version=v1.37.0' -and
            -not ($Arguments | Where-Object { $_ -like 'containerd_version=*' })
        }
    }
    It 'validates without taking the build lock or creating a VM' {
        $result = Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root -ValidateOnly
        $result.Status | Should -Be 'Validated'
        Assert-MockCalled Enter-ImageBuildLock -Scope It -Times 0 -Exactly
        Assert-MockCalled Invoke-ImageCommand -Scope It -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'build' }
        Assert-MockCalled Get-ImageBuildDisk -Scope It -Times 0 -Exactly
    }
    It 'fails rather than overwriting a reused build ID' {
        New-Item -ItemType Directory -Path (Join-Path $script:root 'test-run') -Force | Out-Null
        { Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root } | Should -Throw
        Assert-MockCalled Enter-ImageBuildLock -Scope It -Times 0 -Exactly
    }
    It 'rejects path traversal in an explicit build ID' {
        { Invoke-WindowsImageBuild -BuildId '..\other' -ArtifactRoot $script:root } | Should -Throw 'unsupported'
        Assert-MockCalled Enter-ImageBuildLock -Scope It -Times 0 -Exactly
    }
    It 'resolves a relative artifact root against the PowerShell location' {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $base | Out-Null
        Push-Location $base
        try {
            $result = Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot '.\relative' -ValidateOnly
            $result.OutputDirectory | Should -Be (Join-Path $base 'relative\test-run\output')
        } finally { Pop-Location }
    }
    It 'exposes this run log directory to Actions even when the build fails' {
        $oldOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_ACTIONS = 'true'
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'github-output'
        $script:failurePhase = 'init'
        try {
            { Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root } | Should -Throw 'init failed'
            $values = Get-Content $env:GITHUB_OUTPUT
            $values | Should -Contain "result_path=$script:resultPath"
            $values | Should -Contain "log_directory=$(Split-Path $script:resultPath -Parent)"
        } finally { $env:GITHUB_OUTPUT = $oldOutput }
    }
    It 'preserves failure metadata and stops after initialization fails' {
        $script:failurePhase = 'init'
        { Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root } | Should -Throw 'init failed'
        $saved = Get-Content $script:resultPath -Raw | ConvertFrom-Json
        $saved.Status | Should -Be 'Failed'
        $saved.DiskPath | Should -BeNullOrEmpty
        $script:buildLock.CanWrite | Should -Be $false
        Assert-MockCalled Invoke-ImageCommand -Scope It -Times 0 -Exactly -ParameterFilter { $Arguments[0] -in 'validate', 'build' }
    }
    It 'does not build after validation fails' {
        $script:failurePhase = 'validate'
        { Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root } | Should -Throw 'validate failed'
        Assert-MockCalled Invoke-ImageCommand -Scope It -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'build' }
    }
    It 'does not report success or select an artifact after Packer fails' {
        $script:failurePhase = 'build'
        { Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root } | Should -Throw 'build failed'
        (Get-Content $script:resultPath -Raw | ConvertFrom-Json).Status | Should -Be 'Failed'
        Assert-MockCalled Get-ImageBuildDisk -Scope It -Times 0 -Exactly
    }
    It 'rejects a successful Packer exit without a valid disk' {
        Mock Get-ImageBuildDisk { throw 'No valid disk' }
        { Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root } | Should -Throw 'No valid disk'
        (Get-Content $script:resultPath -Raw | ConvertFrom-Json).Status | Should -Be 'Failed'
    }
    It 'does not launch Packer when another build is detected' {
        Mock Assert-ImageBuildHost { throw 'Existing Packer build' }
        { Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root } | Should -Throw 'Existing Packer'
        Assert-MockCalled Invoke-ImageCommand -Scope It -Times 0 -Exactly
        $script:buildLock.CanWrite | Should -Be $false
    }
    It 'restores the caller environment after failure' {
        $oldLog = $env:PACKER_LOG_PATH
        $env:PACKER_LOG_PATH = 'original-path'
        try {
            Mock Invoke-ImageCommand { throw 'failure' }
            { Invoke-WindowsImageBuild -BuildId 'test-run' -ArtifactRoot $script:root } | Should -Throw
            $env:PACKER_LOG_PATH | Should -Be 'original-path'
        } finally { $env:PACKER_LOG_PATH = $oldLog }
    }
}
