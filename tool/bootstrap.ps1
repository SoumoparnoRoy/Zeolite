<#
    Zeolite bootstrap
    ------------------
    Generates the Android platform folder for YOUR installed Flutter version,
    then restores the app source on top of it and applies the two Android
    tweaks that flutter_local_notifications needs.

    Run this once, from the project root:

        powershell -ExecutionPolicy Bypass -File tool\bootstrap.ps1

    It is safe to re-run: your lib/, test/ and pubspec.yaml are backed up and
    restored, and the Android patches are only applied if they are missing.
#>

$ErrorActionPreference = 'Stop'
# Keep native tool output (flutter, gradle) from aborting the script.
$PSNativeCommandUseErrorActionPreference = $false

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
Write-Host "Zeolite bootstrap in $root" -ForegroundColor Cyan

# 0. Sanity check

$flutter = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $flutter) {
    Write-Host "Flutter is not on your PATH. Install it from https://docs.flutter.dev/install and re-run." -ForegroundColor Red
    exit 1
}

Write-Host "`n[1/5] Flutter version" -ForegroundColor Cyan
flutter --version

# 1. Stash the authored source

$authored = @('lib', 'test', 'tool', 'pubspec.yaml', 'analysis_options.yaml', 'README.md')
$backup = Join-Path $env:TEMP ("zeolite_backup_" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $backup | Out-Null

Write-Host "`n[2/5] Backing up app source to $backup" -ForegroundColor Cyan
foreach ($item in $authored) {
    $path = Join-Path $root $item
    if (Test-Path $path) {
        Copy-Item -Path $path -Destination $backup -Recurse -Force
    }
}

# 2. Generate the platform scaffolding

Write-Host "`n[3/5] Generating the Android project" -ForegroundColor Cyan
flutter create . --project-name zeolite --org com.soumoparno --platforms android

# 3. Put the app source back

Write-Host "`n[4/5] Restoring app source" -ForegroundColor Cyan
foreach ($item in $authored) {
    $src = Join-Path $backup $item
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $root $item
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    Copy-Item -Path $src -Destination $dst -Recurse -Force
}

# flutter create leaves a default widget test that does not match this app.
$defaultTest = Join-Path $root 'test\widget_test.dart'
if ((Test-Path $defaultTest) -and -not (Test-Path (Join-Path $backup 'test\widget_test.dart'))) {
    Remove-Item $defaultTest -Force
}

# 4. Android patches

Write-Host "`n[5/5] Applying Android notification setup" -ForegroundColor Cyan

# 4a. AndroidManifest.xml — permissions, receivers and the app label.
$manifest = Join-Path $root 'android\app\src\main\AndroidManifest.xml'
if (Test-Path $manifest) {
    $xml = Get-Content $manifest -Raw

    if ($xml -notmatch 'RECEIVE_BOOT_COMPLETED') {
        $permissions = @'
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM" />
    <uses-permission android:name="android.permission.VIBRATE" />
'@
        $xml = $xml -replace '(<manifest[^>]*>)', "`$1`r`n$permissions"
        Write-Host "  + notification permissions" -ForegroundColor Green
    }

    if ($xml -notmatch 'ScheduledNotificationReceiver') {
        $receivers = @'
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />
        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
                <action android:name="android.intent.action.QUICKBOOT_POWERON" />
                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON" />
            </intent-filter>
        </receiver>
'@
        $xml = $xml -replace '(\r?\n)(\s*)</application>', "`r`n$receivers`r`n`$2</application>"
        Write-Host "  + notification receivers" -ForegroundColor Green
    }

    if ($xml -match 'android:label="zeolite"') {
        $xml = $xml -replace 'android:label="zeolite"', 'android:label="Zeolite"'
        Write-Host "  + app label set to Zeolite" -ForegroundColor Green
    }

    Set-Content -Path $manifest -Value $xml -NoNewline -Encoding UTF8
} else {
    Write-Host "  ! AndroidManifest.xml not found - skipping manifest patch" -ForegroundColor Yellow
}

# 4b. Gradle — core library desugaring. Appended as extra configuration
#     blocks, which Gradle merges, so nothing already in the file is touched.
$gradleKts = Join-Path $root 'android\app\build.gradle.kts'
$gradleGroovy = Join-Path $root 'android\app\build.gradle'

if (Test-Path $gradleKts) {
    $g = Get-Content $gradleKts -Raw
    if ($g -notmatch 'coreLibraryDesugaring') {
        $block = @'


// --- Added by Zeolite bootstrap -------------------------------------------
// flutter_local_notifications schedules alarms via java.time, which needs
// core library desugaring on older Android versions.
android {
    defaultConfig {
        multiDexEnabled = true
    }
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
'@
        Add-Content -Path $gradleKts -Value $block -Encoding UTF8
        Write-Host "  + core library desugaring (build.gradle.kts)" -ForegroundColor Green
    }
} elseif (Test-Path $gradleGroovy) {
    $g = Get-Content $gradleGroovy -Raw
    if ($g -notmatch 'coreLibraryDesugaring') {
        $block = @'


// --- Added by Zeolite bootstrap -------------------------------------------
android {
    defaultConfig {
        multiDexEnabled true
    }
    compileOptions {
        coreLibraryDesugaringEnabled true
    }
}

dependencies {
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'
}
'@
        Add-Content -Path $gradleGroovy -Value $block -Encoding UTF8
        Write-Host "  + core library desugaring (build.gradle)" -ForegroundColor Green
    }
} else {
    Write-Host "  ! No app build.gradle found - skipping desugaring patch" -ForegroundColor Yellow
}

# 5. Dependencies

Write-Host "`nFetching packages..." -ForegroundColor Cyan
flutter pub get

Write-Host "`nDone." -ForegroundColor Green
Write-Host "  flutter analyze     # static check"
Write-Host "  flutter test        # run the logic tests"
Write-Host "  flutter run         # launch on your device"
