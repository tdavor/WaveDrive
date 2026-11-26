#!/usr/bin/env bash
set -euo pipefail
flutter create --platforms=android --org com.wavedrive --project-name wavedrive --no-pub .
python3 - <<'PY'
from pathlib import Path
p=Path('android/app/src/main/AndroidManifest.xml')
s=p.read_text().replace('<application','<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>\n    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>\n    <uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>\n    <application',1).replace('android:label="wavedrive"','android:label="WaveDrive" android:usesCleartextTraffic="true"')
s=s.replace('</application>','''<service android:name="com.ryanheise.audioservice.AudioService" android:label="WaveDrive" android:icon="@mipmap/ic_launcher" android:foregroundServiceType="mediaPlayback" android:exported="true">
<intent-filter><action android:name="android.media.browse.MediaBrowserService"/></intent-filter>
</service>
<receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver" android:exported="true">
<intent-filter><action android:name="android.intent.action.MEDIA_BUTTON"/></intent-filter>
</receiver>
</application>''')
s=s.replace('</application>','<meta-data android:name="com.google.android.gms.car.application" android:resource="@xml/automotive_app_desc"/><meta-data android:name="androidx.car.app.TintableAttributionIcon" android:resource="@drawable/ic_wavedrive_notification"/></application>')
s=s.replace('</application>','''<provider android:name="androidx.core.content.FileProvider" android:authorities="${applicationId}.updates" android:exported="false" android:grantUriPermissions="true"><meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/update_paths"/></provider></application>''')
p.write_text(s)
x=Path('android/app/src/main/res/xml/automotive_app_desc.xml')
x.parent.mkdir(parents=True,exist_ok=True)
x.write_text('<automotiveApp><uses name="media"/></automotiveApp>')
x.with_name('update_paths.xml').write_text('<paths xmlns:android="http://schemas.android.com/apk/res/android"><cache-path name="updates" path="updates/"/></paths>')
res=Path('android/app/src/main/res')
(res/'drawable').mkdir(parents=True,exist_ok=True)
(res/'drawable'/'ic_wavedrive_notification.xml').write_text('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="24dp" android:height="24dp" android:viewportWidth="24" android:viewportHeight="24"><path android:fillColor="#FFFFFFFF" android:pathData="M3,10h2v4H3z M7,6h2v12H7z M11,2h2v20h-2z M15,6h2v12h-2z M19,10h2v4h-2z"/></vector>')
(res/'raw').mkdir(parents=True,exist_ok=True)
(res/'raw'/'wavedrive_keep.xml').write_text('<resources xmlns:tools="http://schemas.android.com/tools" tools:keep="@drawable/ic_wavedrive_notification,@drawable/audio_service_*"/>')
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
python3 scripts/generate_branding.py
flutter pub get
# just_audio 0.9.x does not expose ExoPlayer's network wake mode in Dart.
# Enable it on the resolved Android player; ExoPlayer releases both locks on pause/stop.
python3 - <<'PY'
import json, re
from pathlib import Path
from urllib.parse import urljoin, urlparse, unquote
config=Path('.dart_tool/package_config.json').resolve()
package=next(p for p in json.loads(config.read_text())['packages'] if p['name']=='just_audio')
root=Path(unquote(urlparse(urljoin(config.as_uri(), package['rootUri'])).path))
source=root/'android/src/main/java/com/ryanheise/just_audio/AudioPlayer.java'
code=source.read_text()
if 'setWakeMode(C.WAKE_MODE_NETWORK)' not in code:
    match=re.search(r'(?m)^(\s*)player\s*=\s*[^;\n]+\.build\(\);',code)
    assert match, 'Cannot locate just_audio ExoPlayer initialization; check package version'
    code=code[:match.end()]+ '\n'+match.group(1)+'player.setWakeMode(C.WAKE_MODE_NETWORK);'+code[match.end():]
    source.write_text(code)
print('Enabled ExoPlayer network wake mode')
PY
flutter analyze --no-fatal-infos --no-fatal-warnings lib
flutter build apk --release --split-per-abi
