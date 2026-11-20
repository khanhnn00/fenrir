#!/usr/bin/env bash
# Builds build/Fenrir with swiftc. Use this when `swift build` is unavailable
# (Command Line Tools only, no Xcode). With Xcode installed, `cd app && swift build` also works.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$ROOT/build"; DEPS="$B/deps"; mkdir -p "$B/lib" "$DEPS"
ST_REV=1.2.0
[ -d "$DEPS/SwiftTerm" ] || git clone -q --depth 1 --branch "$ST_REV" https://github.com/migueldeicaza/SwiftTerm.git "$DEPS/SwiftTerm"
# Local SwiftTerm changes: seamless box-drawing cells, scrollback that stays put while output arrives, 10k-line history.
if ! git -C "$DEPS/SwiftTerm" apply --reverse --check "$ROOT/scripts/swiftterm.patch" 2>/dev/null; then
  git -C "$DEPS/SwiftTerm" apply "$ROOT/scripts/swiftterm.patch"; rm -f "$B/lib/libSwiftTerm.a"
fi
"$ROOT/scripts/build-core.sh"
# CLT ships a duplicate SwiftBridging modulemap that breaks every swiftc run; overlay hides one copy.
: > "$B/empty.modulemap"; sed "s#@EMPTY@#$B/empty.modulemap#" "$ROOT/scripts/cltfix.yaml.in" > "$B/clt-vfs.yaml"
SDK_FLAGS=(-swift-version 5 -O -target arm64-apple-macosx14.0 -Xfrontend -vfsoverlay -Xfrontend "$B/clt-vfs.yaml")
if [ ! -f "$B/lib/libSwiftTerm.a" ]; then
  # shellcheck disable=SC2046
  swiftc "${SDK_FLAGS[@]}" -module-name SwiftTerm -parse-as-library -emit-library -static \
    -emit-module -emit-module-path "$B/lib/SwiftTerm.swiftmodule" -o "$B/lib/libSwiftTerm.a" \
    $(find "$DEPS/SwiftTerm/Sources/SwiftTerm" -name '*.swift' -not -path '*/iOS/*')
fi
APP="$ROOT/app/Sources"
swiftc "${SDK_FLAGS[@]}" -module-name Fenrir -parse-as-library \
  -I "$B/lib" -I "$APP/CFenrirCore/include" -Xcc -fmodule-map-file="$APP/CFenrirCore/include/module.modulemap" \
  "$APP"/Fenrir/*.swift "$APP"/Fenrir/Generated/*.swift \
  -L "$B/lib" -lSwiftTerm -L "$ROOT/core/target/release" -lfenrir_core -lresolv \
  -o "$B/Fenrir"
echo "built $B/Fenrir"

# Bundle: notifications need a bundle identifier; ad-hoc signing is enough for local use.
APPDIR="$B/Fenrir.app"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
# Unlink first so a copy of Fenrir that is already running keeps its old inode.
unlink "$APPDIR/Contents/MacOS/Fenrir" 2>/dev/null || true
cp "$B/Fenrir" "$APPDIR/Contents/MacOS/Fenrir"
cp "$ROOT/design/Fenrir.icns" "$APPDIR/Contents/Resources/Fenrir.icns"
cat > "$APPDIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.fenrir.Fenrir</string>
<key>CFBundleName</key><string>Fenrir</string>
<key>CFBundleDisplayName</key><string>Fenrir</string>
<key>CFBundleExecutable</key><string>Fenrir</string>
<key>CFBundleIconFile</key><string>Fenrir</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>UTExportedTypeDeclarations</key><array><dict>
<key>UTTypeIdentifier</key><string>app.fenrir.sftp-items</string>
<key>UTTypeDescription</key><string>Fenrir transfer items</string>
<key>UTTypeConformsTo</key><array><string>public.data</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APPDIR"
echo "bundled $APPDIR"
