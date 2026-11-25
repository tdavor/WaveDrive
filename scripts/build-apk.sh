#!/usr/bin/env bash
set -euo pipefail
flutter create --platforms=android --org com.wavedrive --project-name wavedrive --no-pub .
python3 - <<'PY'
from pathlib import Path
p=Path('android/app/src/main/AndroidManifest.xml')
s=p.read_text().replace('<application','<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>\n    <uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>\n    <application',1).replace('android:label="wavedrive"','android:label="WaveDrive" android:usesCleartextTraffic="true"')
s=s.replace('</application>','''<service android:name="com.ryanheise.audioservice.AudioService" android:foregroundServiceType="mediaPlayback" android:exported="true">
<intent-filter><action android:name="android.media.browse.MediaBrowserService"/></intent-filter>
</service>
<receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver" android:exported="true">
<intent-filter><action android:name="android.intent.action.MEDIA_BUTTON"/></intent-filter>
</receiver>
</application>''')
s=s.replace('</application>','<meta-data android:name="com.google.android.gms.car.application" android:resource="@xml/automotive_app_desc"/></application>')
s=s.replace('</application>','''<provider android:name="androidx.core.content.FileProvider" android:authorities="${applicationId}.updates" android:exported="false" android:grantUriPermissions="true"><meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/update_paths"/></provider></application>''')
p.write_text(s)
x=Path('android/app/src/main/res/xml/automotive_app_desc.xml')
x.parent.mkdir(parents=True,exist_ok=True)
x.write_text('<automotiveApp><uses name="media"/></automotiveApp>')
x.with_name('update_paths.xml').write_text('<paths xmlns:android="http://schemas.android.com/apk/res/android"><cache-path name="updates" path="updates/"/></paths>')
from shutil import copyfile
activity=Path('android/app/src/main/kotlin/com/wavedrive/wavedrive/MainActivity.kt')
activity.parent.mkdir(parents=True,exist_ok=True)
copyfile('android-support/MainActivity.kt',activity)
g=Path('android/app/build.gradle.kts')
gradle=g.read_text()
debug='signingConfig = signingConfigs.getByName("debug")'
assert debug in gradle and 'buildTypes {' in gradle, 'Unexpected Flutter signing template'
gradle=gradle.replace('buildTypes {','''signingConfigs {
        create("waveRelease") {
            storeFile = file(System.getenv("WAVEDRIVE_KEYSTORE") ?: error("WAVEDRIVE_KEYSTORE missing"))
            storePassword = System.getenv("WAVEDRIVE_KEYSTORE_PASSWORD") ?: error("Signing password missing")
            storeType = "PKCS12"
            keyAlias = "wavedrive"
            keyPassword = storePassword
        }
    }
    buildTypes {''',1).replace(debug,'signingConfig = signingConfigs.getByName("waveRelease")')
g.write_text(gradle)
PY
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings lib
flutter build apk --release --split-per-abi
