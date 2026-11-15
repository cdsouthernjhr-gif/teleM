<#
.SYNOPSIS
  Builds MY_ASEAN_TV.apk (release) on Windows.

.DESCRIPTION
  1. Checks Flutter / Java.
  2. flutter pub get
  3. Validates the JSON database
  4. flutter analyze
  5. flutter test
  6. flutter build apk --release
  7. Copies the APK to dist\MY_ASEAN_TV.apk

  Recommended Flutter version: 3.32.8 (last stable line whose default
  minSdk is below 24; the project pins minSdk 23 for Android 6.0).

.PARAMETER SkipTests
  Skip analyze and unit tests (not recommended).

.PARAMETER DbBaseUrl
  Override the GitHub raw URL of the database folder.

.PARAMETER SplitPerAbi
  Also build smaller per-ABI APKs (armeabi-v7a is what most TV boxes need).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\build.ps1
.EXAMPLE
  .\build.ps1 -DbBaseUrl "https://raw.githubusercontent.com/me/my-asean-tv/main/database/"
#>
param(
    [switch]$SkipTests,
    [string]$DbBaseUrl = "",
    [switch]$SplitPerAbi
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Run($exe, [string[]]$argList) {
    & $exe @argList
    if ($LASTEXITCODE -ne 0) { throw "$exe $($argList -join ' ') failed (exit $LASTEXITCODE)" }
}

Step "Checking tools"
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw "Flutter not found in PATH. Install Flutter 3.32.8: https://docs.flutter.dev/release/archive"
}
if (-not (Get-Command java -ErrorAction SilentlyContinue) -and -not $env:JAVA_HOME) {
    Write-Warning "Java not found. Install JDK 17 (Android Studio includes one) or set JAVA_HOME."
}
$ver = (flutter --version | Select-Object -First 1)
Write-Host $ver
if ($ver -notmatch "Flutter 3\.32\.") {
    Write-Warning "Tested with Flutter 3.32.8. Newer Flutter versions raise the default minSdk; the project pins minSdk 23 explicitly."
}

Step "flutter pub get"
Run flutter @("pub", "get")

Step "Validating database JSON"
Run dart @("run", "tool/validate_db.dart")

if (-not $SkipTests) {
    Step "flutter analyze"
    Run flutter @("analyze")
    Step "flutter test"
    Run flutter @("test")
}

Step "Building release APK"
$buildArgs = @("build", "apk", "--release")
if ($DbBaseUrl -ne "") { $buildArgs += "--dart-define=DB_BASE_URL=$DbBaseUrl" }
Run flutter $buildArgs

New-Item -ItemType Directory -Force -Path "dist" | Out-Null
Copy-Item "build\app\outputs\flutter-apk\app-release.apk" "dist\MY_ASEAN_TV.apk" -Force

if ($SplitPerAbi) {
    Step "Building per-ABI APKs"
    $splitArgs = $buildArgs + @("--split-per-abi")
    Run flutter $splitArgs
    Get-ChildItem "build\app\outputs\flutter-apk\app-*-release.apk" | ForEach-Object {
        $abi = $_.Name -replace "app-", "" -replace "-release.apk", ""
        Copy-Item $_.FullName "dist\MY_ASEAN_TV-$abi.apk" -Force
    }
}

if (-not (Test-Path "android\key.properties")) {
    Write-Warning "android\key.properties not found: the APK is signed with the DEBUG key (OK for testing, not for publishing)."
}

$apk = Get-Item "dist\MY_ASEAN_TV.apk"
Write-Host "`nDONE: $($apk.FullName) ($([math]::Round($apk.Length / 1MB, 1)) MB)" -ForegroundColor Green
Write-Host "Install on a TV box:  adb connect <TV-IP>:5555 ; adb install -r dist\MY_ASEAN_TV.apk"
