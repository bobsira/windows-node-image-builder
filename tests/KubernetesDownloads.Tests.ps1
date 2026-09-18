# Load functions without running the provisioning commands at script scope.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot '..\setup\configure-vm.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($function in $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}

Describe 'Verified Kubernetes downloads' {
    BeforeEach {
        $script:destination = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:payload = [Text.Encoding]::UTF8.GetBytes('test binary')
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $script:checksum = ([BitConverter]::ToString($sha.ComputeHash($script:payload))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        $script:failure = ''
        $script:attempts = 0
        Mock Start-Sleep {}
        Mock Write-Warning {}
        Mock Invoke-WebRequest {
            if ([string]$Uri -like '*.sha256') {
                if ($script:failure -eq 'checksum download failure') { throw 'checksum unavailable' }
                Set-Content -LiteralPath $OutFile -Value $script:checksum
            } else {
                $script:attempts++
                [IO.File]::WriteAllBytes($OutFile, $script:payload)
                if ($script:failure -eq 'connection') {
                    $inner = New-Object System.IO.IOException 'unexpected EOF'
                    throw [System.Net.WebException]::new('transport failed', $inner)
                }
                if ($script:failure -eq 'transient' -and $script:attempts -eq 1) { throw 'unexpected EOF' }
            }
        }
    }

    It 'verifies and installs <Name> with a normalized version' -TestCases @(
        @{ Name = 'kubeadm' }, @{ Name = 'kubelet' }
    ) {
        param($Name)
        Get-KubernetesBinary -Name $Name -KubernetesVersion 'v1.37.0' -DestinationDirectory $script:destination
        (Get-FileHash (Join-Path $script:destination "$Name.exe")).Hash | Should -Be $script:checksum
        @(Get-ChildItem $script:destination).Count | Should -Be 1
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 2 -Exactly -ParameterFilter {
            [string]$Uri -like 'https://dl.k8s.io/v1.37.0/bin/windows/amd64/*' -and
            $TimeoutSec -eq 300 -and $UseBasicParsing
        }
        Assert-MockCalled Start-Sleep -Scope It -Times 0 -Exactly
    }

    It 'retries a partial download and succeeds on the second attempt' {
        $script:failure = 'transient'
        Get-KubernetesBinary kubeadm v1.37.0 $script:destination
        Assert-MockCalled Start-Sleep -Scope It -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        @(Get-ChildItem $script:destination).Count | Should -Be 1
    }

    It 'throws after three connection failures, logs diagnostics, and removes partial files' {
        $script:failure = 'connection'
        { Get-KubernetesBinary kubeadm v1.37.0 $script:destination } | Should -Throw 'transport failed'
        Assert-MockCalled Invoke-WebRequest -Scope It -Times 3 -Exactly
        Assert-MockCalled Start-Sleep -Scope It -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        Assert-MockCalled Start-Sleep -Scope It -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
        Assert-MockCalled Write-Warning -Scope It -Times 3 -Exactly -ParameterFilter {
            $Message -like '*System.Net.WebException*System.IO.IOException*unexpected EOF*'
        }
        @(Get-ChildItem $script:destination).Count | Should -Be 0
    }

    It 'rejects <Failure> and preserves an existing destination' -TestCases @(
        @{ Failure = 'checksum mismatch' }, @{ Failure = 'invalid checksum' },
        @{ Failure = 'empty binary' }, @{ Failure = 'checksum download failure' }
    ) {
        param($Failure)
        $script:failure = $Failure
        New-Item -ItemType Directory $script:destination | Out-Null
        $target = Join-Path $script:destination 'kubeadm.exe'
        Set-Content $target 'existing binary'
        switch ($Failure) {
            'checksum mismatch' { $script:checksum = '0' * 64 }
            'invalid checksum' { $script:checksum = '<html>error</html>' }
            'empty binary' { $script:payload = [byte[]]@() }
        }
        { Get-KubernetesBinary kubeadm v1.37.0 $script:destination } | Should -Throw
        (Get-Content $target -Raw).Trim() | Should -Be 'existing binary'
        @(Get-ChildItem $script:destination).Count | Should -Be 1
        Assert-MockCalled Start-Sleep -Scope It -Times 2 -Exactly
    }
}

Describe 'Provisioning download failures' {
    BeforeEach {
        Mock Get-KubernetesBinary { throw 'download exhausted' }
    }
    It 'propagates kubeadm download failure' {
        { Get-Kubeadm -KubernetesVersion v1.37.0 } | Should -Throw 'download exhausted'
        Assert-MockCalled Get-KubernetesBinary -Scope It -Times 1 -ParameterFilter { $Name -eq 'kubeadm' }
    }
    It 'stops kubelet installation before writing service configuration' {
        Mock Get-WmiObject { [pscustomobject]@{ Name = 'unrelated'; PathName = 'unrelated' } }
        Mock Set-Content {}
        { Install-Kubelet -KubernetesVersion v1.37.0 } | Should -Throw 'download exhausted'
        Assert-MockCalled Get-KubernetesBinary -Scope It -Times 1 -ParameterFilter { $Name -eq 'kubelet' }
        Assert-MockCalled Set-Content -Scope It -Times 0 -Exactly
    }
}
