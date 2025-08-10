$global:os = ""

function whichWindows {
    # Check if WINDOWS_VERSION environment variable is set
    if ($env:WINDOWS_VERSION) {
        $global:os = $env:WINDOWS_VERSION
        Write-Output "Phase 1 [INFO] - Using Windows Server version from environment variable: $global:os"
        printWindowsVersion
        return
    }

    # Fallback to detecting Windows version dynamically
    $version = (Get-WMIObject win32_operatingsystem).name
    if ($version) {
        switch -Regex ($version) {
            '(Server 2016)' {
                $global:os = "2016"
                printWindowsVersion
            }
            '(Server 2019)' {
                $global:os = "2019"
                printWindowsVersion
            }
            '(Server 2022)' {
                $global:os = "2022"
                printWindowsVersion
            }
            '(Server 2025)' {
                $global:os = "2025"
                printWindowsVersion
            }
            '(Microsoft Windows Server Standard|Microsoft Windows Server Datacenter)' {
                $ws_version = (Get-WmiObject win32_operatingsystem).buildnumber
                switch -Regex ($ws_version) {
                    '16299' { $global:os = "1709"; printWindowsVersion }
                    '17134' { $global:os = "1803"; printWindowsVersion }
                    '17763' { $global:os = "1809"; printWindowsVersion }
                    '18362' { $global:os = "1903"; printWindowsVersion }
                    '18363' { $global:os = "1909"; printWindowsVersion }
                    '19041' { $global:os = "2004"; printWindowsVersion }
                    '19042' { $global:os = "20H2"; printWindowsVersion }
                }
            }
            '(Windows 10)' {
                Write-Output 'Phase 1 [INFO] - Windows 10 found'
                $global:os = "10"
                printWindowsVersion
            }
            default {
                Write-Output "unknown"
                printWindowsVersion
            }
        }
    } else {
        throw "Build number empty, cannot continue"
    }
}

function printWindowsVersion {
    if ($global:os) {
        Write-Output "Phase 1 [INFO] - Windows Server $global:os found."
    } else {
        Write-Output "Phase 1 [INFO] - Unknown version of Windows Server found."
    }
}

# Phase 1 - Mandatory generic stuff
Write-Output "Phase 1 [START] - Start of Phase 1"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Import-Module ServerManager

# Determine Windows version
whichWindows

# Apply configurations based on Windows version
if ($global:os -notlike '2016') {
    Enable-NetFirewallRule -DisplayGroup "Windows Defender Firewall Remote Management" -Verbose
}

# Features and firewall rules common for all Windows Servers
try {
    Install-WindowsFeature SNMP-Service,SNMP-WMI-Provider -IncludeManagementTools
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -Verbose
    Enable-NetFirewallRule -DisplayGroup "Remote Service Management" -Verbose
} catch {
    Write-Output "Phase 1 [ERROR] - Setting firewall went wrong"
}

# Terminal services and sysprep registry entries
try {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -Value 0 -Verbose -Force
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -name "UserAuthentication" -Value 0 -Verbose -Force
    Set-ItemProperty -Path 'HKLM:\SYSTEM\Setup\Status\SysprepStatus' -Name 'GeneralizationState' -Value 7 -Verbose -Force
} catch {
    Write-Output "Phase 1 [ERROR] - Setting registry went wrong"
}

Write-Output "Phase 1 [END] - End of Phase 1"
exit 0