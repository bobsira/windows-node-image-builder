# Enable WinRM + required firewall rules for automation (idempotent-ish)
# Adds logging + better error handling + waits for network profile readiness.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Console-only logging helpers
# -----------------------------
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = "[$Level] $Message"
    if ($Level -eq 'ERROR') { Write-Error $line } elseif ($Level -eq 'WARN') { Write-Warning $line } else { Write-Host $line }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][scriptblock]$Action
    )
    Write-Log "START: $Name"
    try {
        & $Action
        Write-Log "OK:    $Name"
    } catch {
        Write-Log "FAIL:  $Name - $($_.Exception.Message)" "ERROR"
        throw
    }
}

Write-Log 'WinRM setup starting.'
Write-Log "Running as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# -----------------------------
# 1) Ensure network profile is Private
# -----------------------------
Invoke-Step "Ensure network profile is Private" {
    # Wait for network profile to be in a usable state (avoid 'Identifying...')
    $deadline = (Get-Date).AddMinutes(3)
    do {
        $profiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
        $ready = $profiles | Where-Object { $_.Name -and $_.Name -ne "Identifying..." -and $_.IPv4Connectivity -ne "Disconnected" }
        if (-not $ready) {
            Write-Log "Network profile not ready yet. Waiting..." "WARN"
            Start-Sleep -Seconds 5
        }
    } until ($ready -or (Get-Date) -gt $deadline)

    if (-not $ready) {
        Write-Log 'Timed out waiting for network profile. Proceeding anyway.' 'WARN'
        $ready = $profiles
    }

    foreach ($p in $ready) {
        Write-Log "Profile: Name='$($p.Name)' Category='$($p.NetworkCategory)' IPv4='$($p.IPv4Connectivity)'"
        if ($p.NetworkCategory -ne "Private") {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private
            Write-Log "Set profile '$($p.Name)' to Private."
        } else {
            Write-Log "Profile '$($p.Name)' is already Private."
        }
    }

    # Disable "new network detected" popups + Network Discovery (optional hardening)
    reg.exe ADD 'HKLM\SYSTEM\CurrentControlSet\Control\Network\NewNetworkWindowOff' /f | Out-Null
    netsh advfirewall firewall set rule group='Network Discovery' new enable=No | Out-Null
    Write-Log 'Disabled Network Discovery firewall group.'
}

# -----------------------------
# 2) Enable PSRemoting / WinRM configuration
# -----------------------------
Invoke-Step "Enable PSRemoting + configure WinRM" {
    # Enable-PSRemoting sets up WinRM service + listeners (but we still tune settings)
    Enable-PSRemoting -Force | Out-Null

    # Ensure WinRM service is running
    Set-Service winrm -StartupType Automatic
    Start-Service winrm

    # WinRM base config
    winrm quickconfig -q | Out-Null

    # Tune WinRM limits for automation
    winrm set winrm/config '@{MaxTimeoutms="1800000"}' | Out-Null
    winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="800"}' | Out-Null

    # Allow unencrypted + Basic (use only on trusted networks; required for some automation flows)
    winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
    winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
    winrm set winrm/config/client/auth '@{Basic="true"}' | Out-Null

    # Ensure HTTP listener on 5985
    winrm set 'winrm/config/listener?Address=*+Transport=HTTP' '@{Port="5985"}' | Out-Null

    Write-Log 'WinRM configured: HTTP/5985, Basic auth enabled, AllowUnencrypted=true.'
}

# -----------------------------
# 3) Firewall rules for WinRM
# -----------------------------
Invoke-Step "Enable WinRM firewall rules" {
    # Built-in rule groups (idempotent)
    netsh advfirewall firewall set rule group='Windows Remote Administration' new enable=yes | Out-Null

    # This rule name is common but can vary by OS build; enable if it exists.
    $rule = Get-NetFirewallRule -DisplayName 'Windows Remote Management (HTTP-In)' -ErrorAction SilentlyContinue
    if ($rule) {
        Enable-NetFirewallRule -DisplayName 'Windows Remote Management (HTTP-In)' | Out-Null
        Write-Log "Enabled firewall rule: Windows Remote Management (HTTP-In)"
    } else {
        Write-Log "Firewall rule 'Windows Remote Management (HTTP-In)' not found; enabling by service group may be sufficient." 'WARN'
        # Fallback: enable WinRM rules by group (best-effort)
        Get-NetFirewallRule -Group '@{Microsoft.Windows.RemoteManagement*}' -ErrorAction SilentlyContinue | Enable-NetFirewallRule | Out-Null
    }
}

# -----------------------------
# 4) Restart WinRM
# -----------------------------
Invoke-Step "Restart WinRM service" {
    Restart-Service winrm -Force
    Write-Log 'WinRM service restarted.'
}

# -----------------------------
# 5) Quick sanity check
# -----------------------------
Invoke-Step "Sanity check (WinRM listener + service)" {
    $svc = Get-Service winrm
    Write-Log "WinRM service status: $($svc.Status) (StartupType: $((Get-CimInstance Win32_Service -Filter \"Name='WinRM'\").StartMode))"

    $listeners = winrm enumerate winrm/config/listener 2>$null
    if ($listeners) {
        Write-Log 'WinRM listeners:'
        $listeners | ForEach-Object { Write-Log $_ }
    } else {
        Write-Log 'Could not enumerate listeners (non-fatal).' 'WARN'
    }
}

# -----------------------------
# 6) UAC Fix for Local Accounts (THE 401 FIX)
# -----------------------------
Invoke-Step "Apply LocalAccountTokenFilterPolicy" {
    $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $name = "LocalAccountTokenFilterPolicy"
    if (-not (Test-Path $registryPath)) { New-Item -Path $registryPath -Force | Out-Null }
    Set-ItemProperty -Path $registryPath -Name $name -Value 1 -Type DWord
    Write-Log 'Registry fix applied: LocalAccountTokenFilterPolicy=1'
}

Write-Log "WinRM setup completed successfully."
exit 0