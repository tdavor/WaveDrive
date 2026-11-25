# WaveDrive APK signing

In-place updates require the same signing certificate and application ID. Earlier test builds used Flutter's generated debug signing configuration, so the first permanently signed build may require uninstalling the old APK (local data will be lost).

On a trusted local computer with JDK and authenticated GitHub CLI:

```bash
mkdir -p "$HOME/.config/wavedrive"
chmod 700 "$HOME/.config/wavedrive"
keytool -genkeypair -keystore "$HOME/.config/wavedrive/wavedrive.p12" -storetype PKCS12 -alias wavedrive -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=WaveDrive"
chmod 600 "$HOME/.config/wavedrive/wavedrive.p12"
base64 -w0 "$HOME/.config/wavedrive/wavedrive.p12" | gh secret set WAVEDRIVE_KEYSTORE_BASE64 --repo tdavor/WaveDrive
gh secret set WAVEDRIVE_KEYSTORE_PASSWORD --repo tdavor/WaveDrive
```

Use the same keystore password when setting the second secret. Keep a secure backup of the keystore and password; never upload either to the repository or regenerate the key for new releases.

The workflow deliberately fails without these secrets. Once configured, run the WaveDrive APK workflow on main.

Update test: install alpha.6, publish a higher-version APK signed with the same key, reopen alpha.6, confirm Android's install prompt. Android may first require permission to install unknown apps from WaveDrive. The updater checks non-draft GitHub releases, includes alpha releases, selects the device ABI, checks the application ID, version code and signing certificate, and requests installation. It does not silently bypass Android consent.
