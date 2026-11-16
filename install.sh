#!/bin/bash
# Compile et installe HDR Studio (Mac Apple Silicon ou Intel, macOS 14+).
# Usage : ./install.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
here="$(cd "$(dirname "$0")" && pwd)"
build="$here/build"
name="HDR Studio Claude"
app="$build/$name.app"

echo "== Outils =="
command -v xcrun >/dev/null || { echo "Outils Xcode requis : xcode-select --install"; exit 1; }
command -v brew >/dev/null || { echo "Homebrew requis : https://brew.sh"; exit 1; }
command -v ffmpeg >/dev/null || brew install ffmpeg
command -v dovi_tool >/dev/null || brew install dovi_tool
command -v MP4Box >/dev/null || brew install gpac

echo "== Compilation =="
rm -rf "$build"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -suppress-warnings "$here/src/app.swift" -o "$app/Contents/MacOS/HDRStudio"
cp "$here/src/hdrvideo.sh" "$app/Contents/Resources/hdrvideo.sh"
chmod +x "$app/Contents/Resources/hdrvideo.sh"

echo "== Icône =="
if xcrun swiftc -O -suppress-warnings "$here/Scripts/make-icon.swift" -o "$build/make-icon" 2>/dev/null \
   && "$build/make-icon" "$build/icon.png"; then
  set_dir="$build/AppIcon.iconset"
  mkdir -p "$set_dir"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$build/icon.png" --out "$set_dir/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$build/icon.png" --out "$set_dir/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set_dir" -o "$app/Contents/Resources/AppIcon.icns" || echo "(icône ignorée)"
else
  echo "(icône ignorée)"
fi

cat > "$app/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>HDR Studio</string>
<key>CFBundleDisplayName</key><string>HDR Studio Claude</string>
<key>CFBundleExecutable</key><string>HDRStudio</string>
<key>CFBundleIdentifier</key><string>be.composeweb.hdrstudio.claude</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PL
codesign --force --deep --sign - "$app" 2>/dev/null || true

echo "== Installation sur le Bureau =="
rm -rf "$HOME/Desktop/$name.app"
cp -R "$app" "$HOME/Desktop/$name.app"
echo "Terminé : « $name.app » est sur ton Bureau."
