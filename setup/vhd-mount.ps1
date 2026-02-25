# Minimal VHD mount -> set partition -> dismount script for CI host
# Usage: .\vhd-mount.ps1 [-VhdPath <path>] [-DriveLetter <letter>]
# If no -VhdPath is provided the script searches for generated VHDs under output* dirs.

param(
    [string]$VhdPath,
    [string]$DriveLetter = 'Z',
    [switch]$ReadOnly = $true
)

$VhdName = 'hybrid-minikube-windows-server.vhdx'
$relative = "..\output-windows-server\Virtual Hard Disks\$VhdName"
$vhdPath = Join-Path -Path $PSScriptRoot -ChildPath $relative

# If caller provided an explicit VhdPath, prefer that
if ($VhdPath) {
    $vhdPath = $VhdPath
}

function Write-Log { param([string]$m) Write-Host "[vhd-mount] $m" }

# Ensure running elevated
try {
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    $isAdmin = $false
}
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

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
    $mounted = $false
    Write-Log "Mounting VHD (ReadOnly=$ReadOnly)..."
    if ($ReadOnly) {
        Mount-VHD -Path $vhdPath -ReadOnly -ErrorAction Stop
    } else {
        Mount-VHD -Path $vhdPath -ErrorAction Stop
    }
    $mounted = $true

    Start-Sleep -Seconds 2

    # Resolve disk/partition info from the mounted VHD
    $vhd = Get-VHD -Path $vhdPath -ErrorAction Stop
    if ($null -eq $vhd.DiskNumber) {
        throw "Mounted VHD has no DiskNumber (mount may have failed)."
    }

    $disk = Get-Disk -Number $vhd.DiskNumber -ErrorAction Stop
    Write-Log "Mounted disk: Number=$($disk.Number) Size=$($disk.Size) Style=$($disk.PartitionStyle)"

    # Choose the largest Basic Data partition (Windows volume) by GPT type or Basic type
    $part = Get-Partition -DiskNumber $disk.Number |
        Where-Object { ($_.GptType -and ($_.GptType -ieq '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}')) -or ($_.Type -and ($_.Type -ieq 'Basic')) } |
        Sort-Object Size -Descending |
        Select-Object -First 1

    if (-not $part) {
        throw "No Basic/Windows partition found on disk $($disk.Number)"
    }

    if (-not $part.DriveLetter) {
        Write-Log "Assigning drive letter $DriveLetter to disk $($disk.Number) partition $($part.PartitionNumber)"
        Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter $DriveLetter -ErrorAction Stop
    } else {
        $DriveLetter = $part.DriveLetter
        Write-Log "Partition already has drive letter: $DriveLetter"
    }

    Write-Log "Sanity: Test-Path ${DriveLetter}:\\Windows => $(Test-Path "${DriveLetter}:\Windows")"
    if (-not (Test-Path "${DriveLetter}:\Windows")) {
        throw "Mounted volume does not look like Windows. Check partition selection."
    }

    Write-Log "Top-level contents:"
    Get-ChildItem "${DriveLetter}:\" -Force | Select-Object -First 20 | ForEach-Object { Write-Log (" - " + $_.Name) }

} catch {
    Write-Error "Operation failed: $_"
    exit 1
} finally {
    if ($mounted) {
        Write-Log "Dismounting VHD (best-effort)..."
        try {
            Dismount-VHD -Path $vhdPath -ErrorAction Stop
        } catch {
            Write-Error "Warning: failed to dismount VHD: $($_.Exception.Message)"
        }
    }
}

Write-Log "Completed mount, assign, dismount."
