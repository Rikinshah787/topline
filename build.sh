#!/bin/zsh
# Builds Topline.app — a customizable replacement for the macOS menu bar.
#   ./build.sh            universal build (Apple Silicon + Intel)
#   ./build.sh --native   faster, this Mac's architecture only
set -euo pipefail
cd "$(dirname "$0")"

APP=Topline.app
VERSION=1.0.0
BUNDLE_ID=io.github.topline-app.Topline
MIN_MACOS=14.0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ "${1:-}" == "--native" ]]; then
    swiftc -O -o "$APP/Contents/MacOS/Topline" Sources/*.swift
else
    BUILD=$(mktemp -d)
    trap 'rm -rf "$BUILD"' EXIT
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macos$MIN_MACOS" -o "$BUILD/Topline-$arch" Sources/*.swift
    done
    lipo -create "$BUILD/Topline-arm64" "$BUILD/Topline-x86_64" -output "$APP/Contents/MacOS/Topline"
fi

cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Topline</string>
    <key>CFBundleDisplayName</key><string>Topline</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Topline</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

# Sign with a stable local certificate (see make-cert.sh) so macOS keeps Accessibility
# access across rebuilds. Falls back to ad-hoc signing, which needs re-granting each build.
signed=""
for IDENTITY in "Topline Local Signing"; do
    if security find-identity -p codesigning | grep -q "$IDENTITY" &&
       codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
        signed="$IDENTITY"; break
    fi
done
if [[ -n "$signed" ]]; then
    echo "Signed with \"$signed\" (Accessibility permission persists across rebuilds)"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "Signed ad-hoc — run ./make-cert.sh once so you don't have to re-grant Accessibility after every build"
fi
echo "Built $(pwd)/$APP"
