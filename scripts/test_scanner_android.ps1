param(
    [Parameter(Mandatory = $true)]
    [string]$DeviceId,
    [switch]$DiagnosticOutput
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterExecutable = Join-Path $projectRoot 'flutter\bin\flutter.bat'
$sdkDirectory = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else {
    Join-Path $env:LOCALAPPDATA 'Android\Sdk'
}
$adbExecutable = Join-Path $sdkDirectory 'platform-tools\adb.exe'
if (!(Test-Path -LiteralPath $adbExecutable)) { throw 'Android platform-tools were not found.' }

# Flutter reinstalls the integration app. Grant permission only to that debug
# app on the selected test device, so its camera-frame check runs unattended.
$permissionJob = Start-Job -ArgumentList $adbExecutable, $DeviceId -ScriptBlock {
    param($adb, $device)
    while ($true) {
        & $adb -s $device shell pm grant de.astubenbord.paperless_mobile.debug android.permission.CAMERA *> $null
        Start-Sleep -Seconds 2
    }
}
Push-Location $projectRoot
try {
    # The pinned SDK's `flutter test --no-dds` attempts to subscribe to a DDS-only
    # golden stream. The standard integration driver checks the same test suite
    # directly, avoiding that host-side error and intermittent DDS startup.
    $testArguments = @('drive', '--driver', 'test_driver/scanner.dart', '--target', 'integration_test/scanner_processing_test.dart', '-d', $DeviceId, '--no-pub', '--no-dds')
    if ($DiagnosticOutput) { $testArguments += '--verbose' }
    & $flutterExecutable @testArguments
    $testExitCode = $LASTEXITCODE
} finally {
    Pop-Location
    Stop-Job $permissionJob -ErrorAction SilentlyContinue
    Remove-Job $permissionJob -Force -ErrorAction SilentlyContinue
}
exit $testExitCode
