param([int]$ExitCode = 0)
Write-Output 'native stdout'
[Console]::Error.WriteLine('native stderr')
exit $ExitCode
