#!/usr/bin/env pwsh
<# Gringots APK low-level build (roadmap Phase 5, no Gradle).
   Uses ANDROID_HOME SDK tools directly: zig (native .so), javac, d8,
   aapt2, zipalign, apksigner. Outputs to android/build/ (gitignored).
   Fails the gate on any step; prints badging + cert summary on success. #>
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $root
$sdk = $env:ANDROID_HOME
if (-not $sdk) { throw "ANDROID_HOME not set" }
$bt = Join-Path $sdk "build-tools\35.0.0"
$platform = Join-Path $sdk "platforms\android-35"
$androidJar = Join-Path $platform "android.jar"
foreach ($p in @($androidJar, "$bt\aapt2.exe", "$bt\zipalign.exe", "$bt\apksigner.bat", "$bt\d8.bat")) {
    if (-not (Test-Path -LiteralPath $p)) { throw "missing tool: $p" }
}

$build = Join-Path $root "build"
$classes = Join-Path $build "classes"
$dexdir = Join-Path $build "dex"
$libdir = Join-Path $build "app\lib\arm64-v8a"
New-Item -ItemType Directory -Force -Path $classes, $dexdir, $libdir | Out-Null

Write-Host "== zig: android .so =="
Push-Location $repo
zig build android-lib
if ($LASTEXITCODE -ne 0) { throw "zig build android-lib failed" }
Pop-Location
Copy-Item (Join-Path $repo "zig-out\lib\libgringots.so") (Join-Path $libdir "libgringots.so") -Force

Write-Host "== javac =="
$javaFiles = Get-ChildItem (Join-Path $root "app\src") -Recurse -Filter *.java | ForEach-Object { $_.FullName }
& javac --release 17 -cp $androidJar -d $classes @javaFiles
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

Write-Host "== d8 =="
$classFiles = Get-ChildItem $classes -Recurse -Filter *.class | ForEach-Object { $_.FullName }
if (-not $classFiles) { throw "no classes compiled" }
& "$bt\d8.bat" --min-api 26 --lib $androidJar --output $dexdir @classFiles
if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

Write-Host "== aapt2 =="
& "$bt\aapt2.exe" compile --dir (Join-Path $root "app\res") -o (Join-Path $build "compiled.zip")
if ($LASTEXITCODE -ne 0) { throw "aapt2 compile failed" }
$base = Join-Path $build "base.apk"
& "$bt\aapt2.exe" link -o $base -I $androidJar `
    --manifest (Join-Path $root "app\AndroidManifest.xml") `
    --min-sdk-version 26 --target-sdk-version 35 `
    --auto-add-overlay `
    -R (Join-Path $build "compiled.zip")
if ($LASTEXITCODE -ne 0) { throw "aapt2 link failed" }

Write-Host "== package dex + .so (python zipfile, .so stored) =="
$unsigned = Join-Path $build "unsigned.apk"
& python3 (Join-Path $root "package_apk.py") $base $dexdir $libdir $unsigned
if ($LASTEXITCODE -ne 0) { throw "packaging failed" }

Write-Host "== zipalign + sign =="
$aligned = Join-Path $build "aligned.apk"
$release = Join-Path $build "gringots.apk"
& "$bt\zipalign.exe" -f -p 4 $unsigned $aligned
if ($LASTEXITCODE -ne 0) { throw "zipalign failed" }
$ks = Join-Path $build "debug.keystore"
if (-not (Test-Path -LiteralPath $ks)) {
    & keytool -genkeypair -keystore $ks -alias debug -keyalg RSA -keysize 2048 `
        -validity 3650 -storepass android -keypass android `
        -dname "CN=Gringots Debug" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "keytool failed" }
}
& "$bt\apksigner.bat" sign --ks $ks --ks-pass pass:android --key-pass pass:android --out $release $aligned
if ($LASTEXITCODE -ne 0) { throw "apksigner failed" }

Write-Host "== gate checks =="
$badging = (& "$bt\aapt2.exe" dump badging $release) -join "`n"
$badging | Select-String "package:|sdkVersion|targetSdkVersion|native-code|application:"
if ($badging -notmatch "package: name='ee.vaino.gringots'") { throw "badging: package name" }
if ($badging -notmatch "native-code: 'arm64-v8a'") { throw "badging: native lib missing" }
& "$bt\apksigner.bat" verify --print-certs $release | Select-String "Verified|certificate"
if ($LASTEXITCODE -ne 0) { throw "apksigner verify failed" }
Write-Host "APK OK: $release"
