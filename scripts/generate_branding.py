"""Generate Android launcher and native splash resources from the supplied logo."""
from pathlib import Path
from PIL import Image
import hashlib

source = Path('assets/branding/wavedrive.webp')
assert hashlib.sha256(source.read_bytes()).hexdigest() == '053bbc7ad573944d49f3dc7d3c9de85e3cbaffdc47b476e810b76bfb0ac9759f'
logo = Image.open(source).convert('RGB')
res = Path('android/app/src/main/res')
def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
def square(size, inset=0):
    canvas = Image.new('RGB', (size, size), 'black')
    art = logo.resize((size-2*inset, size-2*inset), Image.Resampling.LANCZOS)
    canvas.paste(art, (inset, inset))
    return canvas

for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    path = res / f'mipmap-{density}' / 'ic_launcher.png'
    path.parent.mkdir(parents=True, exist_ok=True)
    square(size).save(path, optimize=True)
    round_path = path.with_name('ic_launcher_round.png')
    square(size).save(round_path, optimize=True)

drawable = res / 'drawable-nodpi'
drawable.mkdir(parents=True, exist_ok=True)
square(432, 88).save(drawable/'wavedrive_launcher_foreground.png', optimize=True)
square(288, 56).save(drawable/'wavedrive_system_splash.png', optimize=True)
square(384).save(drawable/'wavedrive_launch_logo.png', optimize=True)
adaptive = '''<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@android:color/black"/>
    <foreground android:drawable="@drawable/wavedrive_launcher_foreground"/>
</adaptive-icon>
'''
for name in ['ic_launcher','ic_launcher_round']:
    write(res/'mipmap-anydpi-v26'/f'{name}.xml', adaptive)

launch = '''<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@android:color/black"/>
    <item>
        <bitmap android:gravity="center" android:src="@drawable/wavedrive_launch_logo"/>
    </item>
</layer-list>
'''
for folder in ['drawable','drawable-v21']:
    write(res/folder/'launch_background.xml', launch)
# Android 12+ limits the native system splash to a masked central icon.
# Flutter follows it with an edge-to-edge black screen and the full logo.
style = '''<resources>
    <style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar">
        <item name="android:windowSplashScreenBackground">@android:color/black</item>
        <item name="android:windowSplashScreenAnimatedIcon">@drawable/wavedrive_system_splash</item>
        <item name="android:windowSplashScreenIconBackgroundColor">@android:color/black</item>
        <item name="android:windowBackground">@android:color/black</item>
        <item name="android:statusBarColor">@android:color/black</item>
        <item name="android:navigationBarColor">@android:color/black</item>
        <item name="android:windowLightStatusBar">false</item>
    </style>
</resources>
'''
for folder in ['values-v31','values-night-v31']:
    write(res/folder/'styles.xml',style)
print('WaveDrive launcher and splash resources generated')
