$envPathRegKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"

if ($env:KUBERNETES_VERSION -and $env:KUBERNETES_VERSION.Trim()) {
    $kubernetes_ver = $env:KUBERNETES_VERSION.TrimStart('v')
    Write-Output "Using Kubernetes version from environment: $kubernetes_ver"
} else {
    Write-Output "KUBERNETES_VERSION environment variable not set. Fetching latest version..."
    $kubernetes_ver = Get-k8LatestVersion
    $kubernetes_ver = $kubernetes_ver.TrimStart('v')
    Write-Output "Using latest Kubernetes version: $kubernetes_ver"
}

function Get-LatestToolVersion($repository) {
    try {
        $uri = "https://api.github.com/repos/$repository/releases/latest"
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing
        $version = ($response.content  | ConvertFrom-Json).tag_name
        return $version.TrimStart("v")
    }
    catch {
        Throw "Could not get $repository version. $_"
    }
}

function Get-ContainerdLatestVersion {
    $latestVersion = Get-LatestToolVersion -Repository "containerd/containerd"
    return $latestVersion
}

function Install-Containerd {
    param(
        [String]
        [parameter(HelpMessage = "Path to install containerd. Defaults to ~\program files\containerd")]
        $InstallPath = "$Env:ProgramFiles\containerd",
        
        [String]
        [parameter(HelpMessage = "Path to download files. Defaults to user's Downloads folder")]
        $DownloadPath = "$HOME\Downloads"
    )

    $Version = Get-ContainerdLatestVersion

    $Version = $Version.TrimStart('v')
    # TODO: revert to this line after finding the right way to handle the new containerd version
    # $Version = $Version.TrimStart('v')
    $Version = "1.7.25"
    Write-Output "* Downloading and installing Containerd v$version at $InstallPath"

    
    # Download file from repo
    $containerdTarFile = "containerd-${version}-windows-amd64.tar.gz"
    try {
        $Uri = "https://github.com/containerd/containerd/releases/download/v$version/$($containerdTarFile)"
        Invoke-WebRequest -Uri $Uri -OutFile $DownloadPath\$containerdTarFile | Out-Null
    }
    catch {
        Throw "Containerd download failed. $_"
    }


    # Untar and install tool
    $params = @{
        Feature      = "containerd"
        InstallPath  = $InstallPath
        DownloadPath = "$DownloadPath\$containerdTarFile"
        EnvPath      = "$InstallPath\bin"
        cleanup      = $true
    }

    
    Install-RequiredFeature @params | Out-Null

    Write-Output "* Containerd v$version successfully installed at $InstallPath"
    containerd.exe -v 
}

function Install-RequiredFeature {
    param(
        [string] $Feature,
        [string] $InstallPath,
        [string] $DownloadPath,
        [string] $EnvPath,
        [boolean] $cleanup
    )
    
    # Create the directory to untar to
    Write-Information -InformationAction Continue -MessageData "* Extracting $Feature to $InstallPath ..."
    if (!(Test-Path $InstallPath)) { 
        New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null 
    }

    # Untar file
    if ($DownloadPath.EndsWith("tar.gz")) {
        tar.exe -xf $DownloadPath -C $InstallPath
        if ($LASTEXITCODE -gt 0) {
            Throw "Could not untar $DownloadPath. $_"
        }
    }

    # Add to env path
    Add-FeatureToPath -Feature $Feature -Path $EnvPath

    # Clean up
    if ($CleanUp) {
        Write-Output "Cleanup to remove downloaded files"
        Remove-Item $downloadPath -Force -ErrorAction Continue
    }
}

function Add-FeatureToPath {
    param (
        [string]
        [ValidateNotNullOrEmpty()]
        [parameter(HelpMessage = "Feature to add to env path")]
        $feature,

        [string]
        [ValidateNotNullOrEmpty()]
        [parameter(HelpMessage = "Path where the feature is installed")]
        $path
    )

    $currPath = (Get-ItemProperty -Path $envPathRegKey -Name path).path
    $currPath = ParsePathString -PathString $currPath
    if (!($currPath -like "*$feature*")) {
        # Write-Information -InformationAction Continue -MessageData "Adding $feature to Environment Path RegKey"

        # Add to reg key
        Set-ItemProperty -Path $envPathRegKey -Name PATH -Value "$currPath;$path"
    }

    $currPath = ParsePathString -PathString $env:Path
    if (!($currPath -like "*$feature*")) {
        # Write-Information -InformationAction Continue -MessageData "Adding $feature to env path"
        # Add to env path
        [Environment]::SetEnvironmentVariable("Path", "$($env:path);$path", [System.EnvironmentVariableTarget]::Machine)
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    }
}

function ParsePathString($pathString) {
    $parsedString = $pathString -split ";" | `
        ForEach-Object { $_.TrimEnd("\") } | `
        Select-Object -Unique | `
        Where-Object { ![string]::IsNullOrWhiteSpace($_) }

    if (!$parsedString) {
        $DebugPreference = 'Stop'
        Write-Debug "Env path cannot be null or an empty string"
    }
    return $parsedString -join ";"
}

function Start-ContainerdService {
    Set-Service containerd -StartupType Automatic
    try {
        Start-Service containerd

        # Waiting for containerd to come to steady state
        (Get-Service containerd -ErrorAction SilentlyContinue).WaitForStatus('Running', '00:00:30')
    }
    catch {
        Throw "Couldn't start Containerd service. $_"
    } 

    Write-Output "* Containerd is installed and the service is started  ..."

}

function Stop-ContainerdService {
    $containerdStatus = Get-Service containerd -ErrorAction SilentlyContinue
    if (!$containerdStatus) {
        Write-Warning "Containerd service does not exist as an installed service."
        return
    }

    try {
        Stop-Service containerd -NoWait

        # Waiting for containerd to come to steady state
        (Get-Service containerd -ErrorAction SilentlyContinue).WaitForStatus('Stopped', '00:00:30')
    }
    catch {
        Throw "Couldn't stop Containerd service. $_"
    } 
}

function Initialize-ContainerdService {
    param(
        [string]
        [parameter(HelpMessage = "Containerd path")]
        $ContainerdPath = "$Env:ProgramFiles\containerd"
    )

    #Configure containerd service
    $containerdConfigFile = "$ContainerdPath\config.toml"
    $containerdDefault = containerd.exe config default
    $containerdDefault | Out-File $ContainerdPath\config.toml -Encoding ascii
    Write-Information -InformationAction Continue -MessageData "* Review containerd configutations at $containerdConfigFile ..."

    Add-MpPreference -ExclusionProcess "$ContainerdPath\containerd.exe"

    # Review the configuration. Depending on setup you may want to adjust:
    # - the sandbox_image (Kubernetes pause image)
    # - cni bin_dir and conf_dir locations


    # Setting	Old value	                                New Value
    # bin_dir	"C:\\Program Files\\containerd\\cni\\bin"	"c:\\opt\\cni\\bin"
    # conf_dir	"C:\\Program Files\\containerd\\cni\\conf"	"c:\\etc\\cni\\net.d\\"

    # Read the content of the config.toml file
    $containerdConfigContent = Get-Content -Path $containerdConfigFile -Raw

    # Define the replacements
    $replacements = @(
        @{
            Find = 'bin_dir = "C:\\Program Files\\containerd\\cni\\bin"'
            Replace = 'bin_dir = "c:\\opt\\cni\\bin"'
        },
        @{
            Find = 'conf_dir = "C:\\Program Files\\containerd\\cni\\conf"'
            Replace = 'conf_dir = "c:\\etc\\cni\\net.d\\"'
          }
    )

    # Perform the check and replacement in one loop
    $replacementsMade = $false
    foreach($replacement in $replacements) {
        if ($containerdConfigContent -match [regex]::Escape($replacement.Find)) {
            $containerdConfigContent = $containerdConfigContent -replace [regex]::Escape($replacement.Find), $replacement.Replace
            $replacementsMade = $true
        }
    }

    # Write the modified content back to the config.toml file if any replacements were made
    if ($replacementsMade) {
        $containerdConfigContent | Set-Content -Path $containerdConfigFile
        # Output a message indicating the changes
        # Write-Host "Changes applied to $containerdConfigFile"
        } else {
        # Write-Host "No changes needed in $containerdConfigFile"
    }

     # Create the folders if they do not exist
    $binDir = "c:\opt\cni\bin"
    $confDir = "c:\etc\cni\net.d"

    if (!(Test-Path $binDir)) {
        mkdir $binDir | Out-Null
        # Write-Host "Created $binDir"
    }

    if (!(Test-Path $confDir)) {
        mkdir $confDir | Out-Null
        # Write-Host "Created $confDir"
    }


    $pathExists = [System.Environment]::GetEnvironmentVariable('PATH', [System.EnvironmentVariableTarget]::Machine) -like "*$ContainerdPath\bin*"
    if (-not $pathExists) {
        # Register containerd service
        Add-FeatureToPath -Feature "containerd" -Path "$ContainerdPath\bin"
    }

    # Check if the containerd service is already registered
    $containerdServiceExists = Get-Service -Name "containerd" -ErrorAction SilentlyContinue
    if (-not $containerdServiceExists) {
        containerd.exe --register-service --log-level debug --service-name containerd --log-file "$env:TEMP\containerd.log"
        if ($LASTEXITCODE -gt 0) {
            Throw "Failed to register containerd service. $_"
        }
    } else {
        Write-Host "Containerd service is already registered."
    }

    Get-Service *containerd* | Select-Object Name, DisplayName, ServiceName, ServiceType, StartupType, Status, RequiredServices, ServicesDependedOn | Out-Null
}

function Install-NSSM {
    $nssmService = Get-WmiObject win32_service | Where-Object {$_.PathName -like '*nssm*'}
    if ($nssmService) {
        Write-Output "NSSM is already installed."
        return
    }

    if (-not (Test-Path -Path "c:\k" -PathType Container)) {
        mkdir "c:\k" | Out-Null
    }
    $arch = "win64"
    $nssmZipFile = "nssm-2.24.zip"
    $nssmUri = "https://k8stestinfrabinaries.blob.core.windows.net/nssm-mirror/$nssmZipFile"
    try {
        Invoke-WebRequest -Uri $nssmUri -OutFile "c:\k\$nssmZipFile" | Out-Null
    }
    catch {
        Throw "NSSM download failed. $_"
    }
    tar.exe C c:\k\ -xf "c:\k\$nssmZipFile" --strip-components 2 */$arch/*.exe | Out-Null

    Write-Output "* NSSM is installed  ..."
}

function Get-k8LatestVersion {
    $latestVersion = Get-LatestToolVersion -Repository "kubernetes/kubernetes"
    return $latestVersion
}

function Install-Kubelet {
    param (
        [string]
        $KubernetesVersion
    )

    # Check if kubelet service is already installed
    $nssmService = Get-WmiObject win32_service | Where-Object {$_.PathName -like '*nssm*'}
    if ($nssmService.Name -eq 'kubelet') {
        Write-Output "Kubelet service is already installed."
        return
    }

    # Define the URL for kubelet download
    $KubeletUrl = "https://dl.k8s.io/v$KubernetesVersion/bin/windows/amd64/kubelet.exe"

    # Download kubelet
    try {
        Invoke-WebRequest -Uri $KubeletUrl -OutFile "c:\k\kubelet.exe" | Out-Null
    } catch {
        Write-Error "Failed to download kubelet: $_"
    }

    # Create the Start-kubelet.ps1 script
    @"
`$FileContent = Get-Content -Path "/var/lib/kubelet/kubeadm-flags.env"
`$kubeAdmArgs = `$FileContent.TrimStart(`'KUBELET_KUBEADM_ARGS=`').Trim(`'"`')

`$args = "--cert-dir=`$env:SYSTEMDRIVE/var/lib/kubelet/pki",
        "--config=`$env:SYSTEMDRIVE/var/lib/kubelet/config.yaml",
        "--bootstrap-kubeconfig=`$env:SYSTEMDRIVE/etc/kubernetes/bootstrap-kubelet.conf",
        "--kubeconfig=`$env:SYSTEMDRIVE/etc/kubernetes/kubelet.conf",
        "--hostname-override=`$(hostname)",
        "--enable-debugging-handlers",
        "--cgroups-per-qos=false",
        "--enforce-node-allocatable=``"``"",
        "--resolv-conf=``"``""

`$kubeletCommandLine = "c:\k\kubelet.exe " + (`$args -join " ") + " `$kubeAdmArgs"
Invoke-Expression `$kubeletCommandLine
"@ | Set-Content -Path "c:\k\Start-kubelet.ps1"

    # Install kubelet as a Windows service
    c:\k\nssm.exe install kubelet Powershell -ExecutionPolicy Bypass -NoProfile c:\k\Start-kubelet.ps1 | Out-Null
    c:\k\nssm.exe set Kubelet AppStdout C:\k\kubelet.log | Out-Null
    c:\k\nssm.exe set Kubelet AppStderr C:\k\kubelet.err.log | Out-Null

    Write-Output "* Kubelet is installed and the service is started  ..."
}

function Set-Port {
    $firewallRule = Get-NetFirewallRule -Name 'kubelet' -ErrorAction SilentlyContinue
    if ($firewallRule) {
        Write-Output "Firewall rule 'kubelet' already exists."
        return
    }

    $ruleParams = @{
        Name = 'kubelet'
        DisplayName = 'kubelet'
        Enabled = "True"
        Direction = 'Inbound'
        Protocol = 'TCP'
        Action = 'Allow'
        LocalPort = 10250
    }

    New-NetFirewallRule @ruleParams | Out-Null
}

function Get-Kubeadm {
    param (
        [string]
        $KubernetesVersion
    )

    $KubernetesVersion = Get-k8LatestVersion
    Write-Output "* The latest Kubernetes version is $KubernetesVersion"
    $KubernetesVersion = $KubernetesVersion.TrimStart('v')
    
    try {
        Invoke-WebRequest -Uri "https://dl.k8s.io/v$KubernetesVersion/bin/windows/amd64/kubeadm.exe" -OutFile "c:\k\kubeadm.exe" | Out-Null
    } catch {
        Write-Error "Failed to download kubeadm: $_"
    }
}


Write-Output "Phase 1 [Installing Containerd] ..."
Install-Containerd

Write-Output "Phase 2 [Initializing Containerd Service] ..."
Initialize-ContainerdService

Write-Output "Phase 3 [Starting Containerd Service] ..."
Start-ContainerdService

Write-Output "Phase 4 [Installing NSSM] ..."
Install-NSSM

Write-Output "Phase 5 [Installing Kubelet] ..."
Install-Kubelet -KubernetesVersion $kubernetes_ver

Write-Output "Phase 6 [Setting Port] ..."
Set-Port

Write-Output "Phase 7 [Getting Kubeadm] ..."
Get-Kubeadm