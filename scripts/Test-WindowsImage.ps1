#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try {
    Import-Module Pester -RequiredVersion 4.9.0 -ErrorAction Stop
    $testDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'tests'
    $results = Pester\Invoke-Pester -Script $testDirectory -PassThru
    if ($results.TotalCount -eq 0) {
        throw "No tests were found in $testDirectory."
    }
    if ($results.FailedCount -gt 0) {
        throw "$($results.FailedCount) tests failed."
    }
} catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
}
exit 0
