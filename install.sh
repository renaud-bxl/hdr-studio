#!/bin/bash
# Installe HDR Studio sur un Mac Apple Silicon (macOS 14+).
# Usage: ./install.sh
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
here="$(cd "$(dirname "$0")" && pwd)"

echo "== Verification des outils =="
command -v brew >/dev/null || { echo "Homebrew requis: https://brew.sh"; exit 1; }
for t in ffmpeg dovi_tool MP4Box; do
  if ! command -v "$t" >/dev/null; then
    case "$t" in
      ffmpeg) brew install ffmpeg ;;
      dovi_tool) brew install dovi_tool ;;
      MP4Box) brew install gpac ;;
    esac
  fi
done
command -v xcrun >/dev/null || { echo "Outils Xcode requis: xcode-select --install"; exit 1; }

echo "== Installation des moteurs =="
mkdir -p "$HOME/.local/bin"
cp "$here/src/hdrvideo.sh" "$HOME/.local/bin/hdrvideo.sh"
chmod +x "$HOME/.local/bin/hdrvideo.sh"
xcrun swiftc -O "$here/src/hdrphoto.swift" -o "$HOME/.local/bin/hdrphoto"

echo "== Compilation de l'application =="
xcrun swiftc -O "$here/src/app.swift" -o "$here/HDRStudio"
APP="$here/HDR Studio Claude.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$here/HDRStudio" "$APP/Contents/MacOS/HDRStudio"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>HDR Studio Claude</string>
<key>CFBundleExecutable</key><string>HDRStudio</string>
<key>CFBundleIdentifier</key><string>be.composeweb.hdrstudio.claude</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PL
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "== Copie sur le Bureau =="
rm -rf "$HOME/Desktop/HDR Studio Claude.app"
cp -R "$APP" "$HOME/Desktop/HDR Studio Claude.app"
echo "Termine. 'HDR Studio Claude.app' est sur ton Bureau. Double-clique pour lancer."
