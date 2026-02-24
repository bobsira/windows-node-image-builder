# Minimal VHD mount -> set partition -> dismount script for CI host
# Looks for: output-windows-server\Virtual Hard Disks\hybrid-minikube-windows-server.vhdx

$VhdName = 'hybrid-minikube-windows-server.vhdx'
$relative = "..\output-windows-server\Virtual Hard Disks\$VhdName"
$vhdPath = Join-Path -Path $PSScriptRoot -ChildPath $relative

function Write-Log { param($m) Write-Host "[vhd-mount] $m" }

Write-Log "Looking for VHD: $vhdPath"
if (-not (Test-Path -Path $vhdPath)) {
    Write-Log "Primary path not found; searching output directories (output*, output-*, output) for .vhd/.vhdx files..."

    function Find-GeneratedVhd {
        param(
            [string]$baseDir
        )
        $searchPatterns = @("$baseDir\output*", "$baseDir\output-*", "$baseDir\output")
        foreach ($pattern in $searchPatterns) {
            try {
                $found = Get-ChildItem -Path $pattern -Include "*.vhd","*.vhdx" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { return $found.FullName }
            } catch {
                # ignore and continue
            }
        }
        return $null
    }

    # Try script root, then its parent directories (keeps script generic for local and CI use)
    $found = Find-GeneratedVhd -baseDir $PSScriptRoot
    if (-not $found) {
        $parent = Split-Path -Path $PSScriptRoot -Parent
        while ($parent -and -not $found) {
            $found = Find-GeneratedVhd -baseDir $parent
            if ($found) { break }
            $next = Split-Path -Path $parent -Parent
            if ($next -and $next -ne $parent) { $parent = $next } else { break }
        }
    }

    if (-not $found) {
        Write-Error "VHD not found: $vhdPath"
        exit 1
    }

    $vhdPath = $found
    Write-Log "Found VHD: $vhdPath"
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
