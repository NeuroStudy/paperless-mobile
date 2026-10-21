$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterCommand = Join-Path $projectRoot 'flutter/bin/flutter.bat'
$dartCommand = Join-Path $projectRoot 'flutter/bin/dart.bat'

if (-not (Test-Path -LiteralPath $flutterCommand)) {
    throw 'Initialize the pinned SDK first: git submodule update --init flutter'
}

Push-Location $projectRoot
try {
    & $flutterCommand pub get
    if ($LASTEXITCODE -ne 0) { throw 'Dependency resolution failed.' }
    & $flutterCommand gen-l10n
    if ($LASTEXITCODE -ne 0) { throw 'Localization generation failed.' }
    & $dartCommand run build_runner build --delete-conflicting-outputs
    if ($LASTEXITCODE -ne 0) { throw 'Dart code generation failed.' }
} finally {
    Pop-Location
}
