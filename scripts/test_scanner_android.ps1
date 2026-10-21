param(
    [Parameter(Mandatory = $true)]
    [string]$DeviceId
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterExecutable = Join-Path $projectRoot 'flutter\bin\flutter.bat'
Push-Location $projectRoot
try {
    & $flutterExecutable test integration_test/scanner_processing_test.dart -d $DeviceId --no-pub --reporter expanded
    $testExitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $testExitCode
