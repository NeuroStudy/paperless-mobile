param(
    [Parameter(Mandatory = $true)]
    [string]$DeviceId
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterExecutable = Join-Path $projectRoot 'flutter\bin\flutter.bat'
$sdkDirectory = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else {
    Join-Path $env:LOCALAPPDATA 'Android\Sdk'
}
$adbExecutable = Join-Path $sdkDirectory 'platform-tools\adb.exe'
if (!(Test-Path -LiteralPath $adbExecutable)) { throw 'Android platform-tools were not found.' }

# Integration runs can reinstall the debug app. Grant its camera permission
# after installation, before the camera test opens a platform permission dialog.
$permissionJob = Start-Job -ArgumentList $adbExecutable, $DeviceId -ScriptBlock {
    param($adb, $device)
    while ($true) {
        & $adb -s $device shell pm grant de.astubenbord.paperless_mobile.debug android.permission.CAMERA *> $null
        Start-Sleep -Seconds 2
    }
}

Push-Location $projectRoot
try {
    & $flutterExecutable test integration_test/scanner_processing_test.dart -d $DeviceId --no-pub --reporter expanded
    $testExitCode = $LASTEXITCODE
} finally {
    Pop-Location
    Stop-Job $permissionJob -ErrorAction SilentlyContinue
    Remove-Job $permissionJob -Force -ErrorAction SilentlyContinue
}
exit $testExitCode
