param([Parameter(Mandatory = $true)][string]$ProgramDataPath)
. (Join-Path $PSScriptRoot '..\..\scripts\Build-WindowsImage.ps1')
$env:ProgramData = $ProgramDataPath
try {
    $lock = Enter-ImageBuildLock
    $lock.Dispose()
    exit 0
} catch {
    Write-Output $_.Exception.Message
    exit 7
}
