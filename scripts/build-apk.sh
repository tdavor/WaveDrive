#!/usr/bin/env bash
set -euo pipefail
flutter create --platforms=android,ios --org com.wavedrive --project-name wavedrive --no-pub .
python3 - <<'PY'
from pathlib import Path
p=Path('android/app/src/main/AndroidManifest.xml')
s=p.read_text().replace('<application','<uses-permission android:name="android.permission.INTERNET"/>\n    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>\n    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>\n    <application',1).replace('android:label="wavedrive"','android:label="WaveDrive" android:usesCleartextTraffic="true"').replace('android:name=".MainActivity"','android:name="com.ryanheise.audioservice.AudioServiceActivity"')
s=s.replace('</application>','''<service android:name="com.ryanheise.audioservice.AudioService" android:foregroundServiceType="mediaPlayback" android:exported="true">
<intent-filter><action android:name="android.media.browse.MediaBrowserService"/></intent-filter>
</service>
<receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver" android:exported="true">
<intent-filter><action android:name="android.intent.action.MEDIA_BUTTON"/></intent-filter>
</receiver>
</application>''')
p.write_text(s)
PY
flutter pub get
flutter analyze --no-fatal-infos --no-fatal-warnings lib
flutter build apk --release --split-per-abi
