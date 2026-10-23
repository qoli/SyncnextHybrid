#!/usr/bin/env bash
set -euo pipefail
umask 077

TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacStartupProbe"
APP_BUNDLE="$TASK_ROOT/dist/$APP_NAME.app"
MODE="${1:-run}"
case "$MODE" in
  run|--build-only|--launch-only|--debug|--logs|--telemetry|--verify) [[ $# -eq 0 ]] || shift ;;
  *) MODE=run ;;
esac

if [[ "$MODE" != --build-only ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
if [[ "$MODE" != --launch-only ]]; then
  swift build --package-path "$TASK_ROOT" -c release --product "$APP_NAME"
  TASK_BIN_DIR="$(swift build --package-path "$TASK_ROOT" -c release --show-bin-path)"
  mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks"
  cp "$TASK_BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
  for framework in "$TASK_BIN_DIR"/*.framework; do
    [[ -d "$framework" ]] || continue
    ditto "$framework" "$APP_BUNDLE/Contents/Frameworks/$(basename "$framework")"
  done
  for resource in "$TASK_BIN_DIR"/*.bundle; do
    [[ -d "$resource" ]] || continue
    ditto "$resource" "$APP_BUNDLE/Contents/Resources/$(basename "$resource")"
  done
  chmod -R u+w "$APP_BUNDLE/Contents/Frameworks"
  if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | rg -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
  fi
  cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacStartupProbe</string>
<key>CFBundleIdentifier</key><string>com.qoli.SyncnextMacStartupProbe</string>
<key>CFBundleName</key><string>MacStartupProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
  codesign --force --deep --sign - "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
fi
[[ -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]] || { echo 'Build the native probe before --launch-only.' >&2; exit 1; }
[[ "$MODE" != --build-only ]] || exit 0
if [[ "$MODE" == --debug ]]; then
  exec lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$@"
fi
/usr/bin/open -n "$APP_BUNDLE" --args "$@"
case "$MODE" in
  --logs|--telemetry) exec /usr/bin/log stream --info --style compact --predicate 'process == "MacStartupProbe"' ;;
  --verify) pgrep -x "$APP_NAME" ;;
esac
