param(
    [ValidateSet('debug', 'release')]
    [string]$Mode = 'release',
    [ValidateSet('android-arm64', 'android-x64', 'android-arm64,android-x64')]
    [string]$TargetPlatform = 'android-arm64',
    [string]$OutputDirectory,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\', '/')
$canonicalBranch = 'codex/scan-enhancement-alpha2'
$baseline = 'b1cf03e26c8b58b4a0eeea818a62651d96085170'

function Read-ProjectGit {
    param([string[]]$GitArguments)
    $result = & git -C $projectRoot @GitArguments
    if ($LASTEXITCODE -ne 0) { throw "Git check failed: $($GitArguments -join ' ')" }
    return ($result -join "`n").Trim()
}

function Assert-Alpha2Source {
    if ($env:OS -eq 'Windows_NT' -and $projectRoot -ine 'D:\DEV\paperless-mobile') {
        throw 'Use the canonical project folder D:\DEV\paperless-mobile.'
    }
    $branch = Read-ProjectGit -GitArguments @('branch', '--show-current')
    if (!$branch -and $env:GITHUB_ACTIONS -eq 'true' -and $env:GITHUB_REF -eq "refs/heads/$canonicalBranch") {
        $branch = $canonicalBranch
    }
    if ($branch -ne $canonicalBranch) { throw "Expected $canonicalBranch; found '$branch'." }
    $null = Read-ProjectGit -GitArguments @('merge-base', '--is-ancestor', $baseline, 'HEAD')
    # Check SDK contents separately so generated Kotlin sessions are not source edits.
    $status = Read-ProjectGit -GitArguments @('status', '--porcelain=v1', '--untracked-files=normal', '--ignore-submodules=untracked')
    if ($status) { throw "Commit or preserve local changes before building a verified APK:`n$status" }
    $manifest = Get-Content -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Raw
    if ($manifest -notmatch 'path:\s*packages/paperless_mobile_document_scanner' -or
        (Test-Path -LiteralPath (Join-Path $projectRoot 'lib/features/scanner/paperless_mobile_document_scanner.dart'))) {
        throw 'The checkout does not contain the maintained standalone Alpha 2 scanner.'
    }
    $sdkRevision = Read-ProjectGit -GitArguments @('-C', 'flutter', 'rev-parse', 'HEAD')
    $recordedSdk = Read-ProjectGit -GitArguments @('rev-parse', 'HEAD:flutter')
    if ($sdkRevision -ne $recordedSdk) { throw 'Flutter does not match the committed submodule revision.' }
    $sdkStatus = Read-ProjectGit -GitArguments @('-C', 'flutter', 'status', '--porcelain=v1', '--untracked-files=normal', '--', '.', ':(exclude)packages/flutter_tools/gradle/.kotlin/**')
    if ($sdkStatus) { throw 'Flutter has local changes. Preserve them before building.' }
}

Assert-Alpha2Source
$revision = Read-ProjectGit -GitArguments @('rev-parse', 'HEAD')
if ($CheckOnly) {
    Write-Output "Verified Alpha 2 source: $revision"
    exit 0
}
if (!$OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'build/verified-apks' }
$flutterExecutable = Join-Path $projectRoot 'flutter/bin/flutter.bat'
$dartExecutable = Join-Path $projectRoot 'flutter/bin/dart.bat'
if ($env:OS -ne 'Windows_NT') {
    $flutterExecutable = Join-Path $projectRoot 'flutter/bin/flutter'
    $dartExecutable = Join-Path $projectRoot 'flutter/bin/dart'
}

Push-Location $projectRoot
try {
    & $flutterExecutable pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Locked dependency resolution failed.' }
    & $flutterExecutable gen-l10n
    if ($LASTEXITCODE -ne 0) { throw 'Localization generation failed.' }
    & $dartExecutable run build_runner build --delete-conflicting-outputs
    if ($LASTEXITCODE -ne 0) { throw 'Source generation failed.' }
    Assert-Alpha2Source
    # Flutter 3.41 regenerates mode-specific plugin registration only with pub
    # enabled. --no-pub can retain integration_test after a debug test build.
    $buildArguments = @('build', 'apk', "--$Mode", "--target-platform=$TargetPlatform",
        "--dart-define=BUILD_GIT_SHA=$revision", "--dart-define=BUILD_SOURCE_BRANCH=$canonicalBranch")
    & $flutterExecutable @buildArguments
    if ($LASTEXITCODE -ne 0) { throw 'APK build failed.' }
    Assert-Alpha2Source
    if ((Read-ProjectGit -GitArguments @('rev-parse', 'HEAD')) -ne $revision) {
        throw 'The source revision changed during the build; this APK is not verified.'
    }
    $metadata = Get-Content -LiteralPath "build/app/outputs/apk/$Mode/output-metadata.json" -Raw | ConvertFrom-Json
    $version = $metadata.elements[0].versionName
    $versionCode = $metadata.elements[0].versionCode
    $shortRevision = $revision.Substring(0, 10)
    $platformLabel = $TargetPlatform.Replace(',', '+')
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $destination = Join-Path $OutputDirectory "paperless-alpha2-$Mode-$platformLabel-$version+$versionCode-$shortRevision.apk"
    if (Test-Path -LiteralPath $destination) { throw "Verified artifact already exists: $destination" }
    Copy-Item -LiteralPath "build/app/outputs/flutter-apk/app-$Mode.apk" -Destination $destination
    $sdk = Get-Content -LiteralPath 'flutter/bin/cache/flutter.version.json' -Raw | ConvertFrom-Json
    $localProperties = Get-Content -LiteralPath 'android/local.properties' -Raw
    $debugSigning = if ($env:ORG_GRADLE_PROJECT_useDebugSigning) {
        $env:ORG_GRADLE_PROJECT_useDebugSigning -eq 'true'
    } else { $localProperties -match '(?m)^useDebugSigning=true\s*$' }
    $signing = if ($Mode -eq 'debug' -or $debugSigning) { 'local-debug-key' } else { 'release-key' }
    $provenance = [ordered]@{
        sourceBranch = $canonicalBranch
        sourceRevision = $revision
        flutterRevision = $sdk.frameworkRevision
        flutterVersion = $sdk.flutterVersion
        dartVersion = $sdk.dartSdkVersion
        dependencyLockSha256 = (Get-FileHash -LiteralPath 'pubspec.lock' -Algorithm SHA256).Hash
        applicationId = $metadata.applicationId
        versionName = $version
        versionCode = $versionCode
        mode = $Mode
        targetPlatform = $TargetPlatform
        signing = $signing
        scanner = 'Alpha 2 standalone package; 1080p default'
        apkSha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    $provenance | ConvertTo-Json | Set-Content -LiteralPath "$destination.json" -Encoding utf8
    Write-Output "Verified APK: $destination"
    Write-Output "SHA-256: $($provenance.apkSha256)"
    Write-Output "Signing: $signing"
} finally {
    Pop-Location
}
