# Minimal VHD mount -> set partition -> dismount script for CI host
# Looks for: output-windows-server\Virtual Hard Disks\hybrid-minikube-windows-server.vhdx

$VhdName = 'hybrid-minikube-windows-server.vhdx'
$relative = "..\output-windows-server\Virtual Hard Disks\$VhdName"
$vhdPath = Join-Path -Path $PSScriptRoot -ChildPath $relative

function Write-Log { param($m) Write-Host "[vhd-mount] $m" }

Write-Log "Looking for VHD: $vhdPath"
if (-not (Test-Path -Path $vhdPath)) {
    Write-Error "VHD not found: $vhdPath"
    exit 1
}

try {
    Write-Log "Mounting VHD (read-only)..."
    Mount-VHD -Path $vhdPath -ReadOnly -ErrorAction Stop

    Start-Sleep -Seconds 2

    Write-Log "Assigning drive letter Z to DiskNumber 1 PartitionNumber 4"
    Set-Partition -DiskNumber 1 -PartitionNumber 4 -NewDriveLetter Z -ErrorAction Stop

} catch {
    Write-Error "Operation failed: $_"
    # attempt best-effort dismount
    try { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue } catch {}
    exit 1
} finally {
    Write-Log "Dismounting VHD..."
    try { Dismount-VHD -Path $vhdPath -ErrorAction Stop } catch {
        Write-Error "Failed to dismount VHD: $($_.Exception.Message)"
        exit 1
    }
}

Write-Log "Completed mount, assign, dismount."
