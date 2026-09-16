#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/logs
mmm_step=0
mmm_active_pid=""
trap 'if [[ -n "$mmm_active_pid" ]]; then kill -TERM "$mmm_active_pid" 2>/dev/null || true; fi; printf "\nBuild interrupted. Run ./build.sh again to finish.\n"; exit 130' INT TERM
run_step() {
 local label="$1"
 shift
 mmm_step=$((mmm_step + 1))
 local logfile="$PWD/build/logs/step-${mmm_step}.log"
 printf '\n[%s/5] %s\n' "$mmm_step" "$label"
 printf '  Command:'
 printf ' %q' "$@"
 printf '\n'
 "$@" >"$logfile" 2>&1 &
 local mmm_pid=$! mmm_started=$SECONDS mmm_tick=0
 mmm_active_pid="$mmm_pid"
 local frames=('|' '/' '-' '\\')
 while kill -0 "$mmm_pid" 2>/dev/null; do
  printf '\r  %s Running · PID %s · %ss elapsed   ' "${frames[$((mmm_tick % 4))]}" "$mmm_pid" "$((SECONDS - mmm_started))"
  mmm_tick=$((mmm_tick + 1))
  sleep 1
 done
 if wait "$mmm_pid"; then
  mmm_active_pid=""
  printf '\r  ✓ Done in %ss                                  \n' "$((SECONDS - mmm_started))"
  if [[ -s "$logfile" ]]; then cat "$logfile"; fi
 else
  local result=$?
  mmm_active_pid=""
  printf '\n  FAILED (exit %s) — %s\n' "$result" "$logfile"
  cat "$logfile"
  return "$result"
 fi
}
printf '\nMMM / BUILD + INSTALL\nFive stages · detailed logs in build/logs\n'
mkdir -p build/module-cache build/MMM.app/Contents/{MacOS,Resources} build/MMM.iconset
APP="$PWD/build/MMM.app"
run_step "Compile MMM window and menu bar" swiftc -module-cache-path build/module-cache -O App.swift MenuBar.swift Pickaxe.swift PoolCredential.swift -o "$APP/Contents/MacOS/MMM" -framework Cocoa -framework WebKit -framework Security
run_step "Compile and optimize MetalDAG mining engine" swiftc -module-cache-path build/module-cache -O Engine/main.swift Engine/Login.swift Engine/StatsServer.swift Engine/MetalDAGEngine.swift Engine/MetalDAGShader.swift -o "$APP/Contents/Resources/NerdMiner" -framework Metal -framework CoreGraphics
run_step "Bundle four-tab dashboard and themes" cp index.html style.css app.js identicon.js pickaxe-white.svg "$APP/Contents/Resources/"
run_step "Compile icon renderer" swiftc -module-cache-path build/module-cache Icon.swift -o build/make-icon
build/make-icon build/MMM.png
for size in 16 32 128 256 512; do
 sips -z "$size" "$size" build/MMM.png --out "build/MMM.iconset/icon_${size}x${size}.png" >/dev/null
 double=$((size * 2))
 sips -z "$double" "$double" build/MMM.png --out "build/MMM.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 make_icns.py
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MMM</string>
<key>CFBundleIdentifier</key><string>com.xcoin.mmm</string>
<key>CFBundleName</key><string>MMM</string>
<key>CFBundleDisplayName</key><string>MMM</string>
<key>CFBundleIconFile</key><string>MMM.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PLIST
run_step "Sign and verify app" bash -c 'codesign --force --sign - "$1/Contents/Resources/NerdMiner" && codesign --force --deep --sign - "$1" && codesign --verify --deep --strict "$1"' _ "$APP"
printf 'Built %s\n' "$APP"
if [[ "${1:-}" == "--install" ]]; then printf "\nInstalling MMM and adding its Dock icon…\n"; ./install.sh; else printf "Ready to install: ./install.sh\n"; fi
