#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/logs
mmm_step=0
mmm_active_pid=""
# Bundle the wallet CLI (WALLET tab) when a checkout with a built keytool is
# available; without it the app falls back to ~/x-Coin/wallet-cli at runtime.
WALLET_SRC="${XCOIN_WALLET_SRC:-$HOME/x-Coin/xcoin-wallet}"
mmm_wallet=0
if [ -f "$WALLET_SRC/wallet_cli.py" ] && [ -f "$WALLET_SRC/card_seed.py" ] && [ -x "$WALLET_SRC/xcoin-wallet-cli" ] && [ -x "$WALLET_SRC/xcoin-wallet" ]; then mmm_wallet=1; fi
mmm_total=$((5 + mmm_wallet))
trap 'if [[ -n "$mmm_active_pid" ]]; then kill -TERM "$mmm_active_pid" 2>/dev/null || true; fi; printf "\nBuild interrupted. Run ./build.sh again to finish.\n"; exit 130' INT TERM
run_step() {
 local label="$1"
 shift
 mmm_step=$((mmm_step + 1))
 local logfile="$PWD/build/logs/step-${mmm_step}.log"
 printf '\n[%s/%s] %s\n' "$mmm_step" "$mmm_total" "$label"
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
bundle_wallet() { mkdir -p "$1/Contents/Resources/wallet" && cp -X "$2/wallet_cli.py" "$2/card_seed.py" "$2/xcoin-wallet-cli" "$2/xcoin-wallet" "$1/Contents/Resources/wallet/"; }
wallet_warning() { printf '\nWARNING: wallet CLI NOT bundled. %s lacks wallet_cli.py, card_seed.py,\n         xcoin-wallet-cli or a built xcoin-wallet keytool (run its ./build.sh).\n         MMM will look for ~/x-Coin/wallet-cli at runtime. Set XCOIN_WALLET_SRC to bundle it.\n' "$WALLET_SRC" >&2; }
printf '\nMMM / BUILD + INSTALL\n%s stages · detailed logs in build/logs\n' "$mmm_total"
APP="$PWD/build/MMM.app"
# Start from an empty bundle so nothing from an earlier build is signed in.
rm -rf "$APP"
mkdir -p build/module-cache "$APP"/Contents/{MacOS,Resources} build/MMM.iconset
run_step "Compile MMM window and menu bar" swiftc -module-cache-path build/module-cache -O App.swift MenuBar.swift Pickaxe.swift PoolCredential.swift ForumCredential.swift WalletService.swift Schedule.swift QRCode.swift -o "$APP/Contents/MacOS/MMM" -framework Cocoa -framework WebKit -framework Security -framework LocalAuthentication -framework IOKit -framework CoreImage
run_step "Compile and optimize MetalDAG mining engine" swiftc -module-cache-path build/module-cache -O Engine/main.swift Engine/Login.swift Engine/StatsServer.swift Engine/MetalDAGEngine.swift Engine/MetalDAGShader.swift -o "$APP/Contents/Resources/NerdMiner" -framework Metal -framework CoreGraphics
run_step "Bundle seven-tab dashboard and themes" cp -X index.html style.css app.js identicon.js pickaxe-white.svg "$APP/Contents/Resources/"
if [[ $mmm_wallet == 1 ]]; then run_step "Bundle offline wallet CLI" bundle_wallet "$APP" "$WALLET_SRC"; else wallet_warning; fi
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
# FinderInfo or a resource fork on any bundled file makes codesign refuse the bundle.
run_step "Sign and verify app" bash -c 'xattr -cr "$1" && codesign --force --sign - "$1/Contents/Resources/NerdMiner" && codesign --force --deep --sign - "$1" && codesign --verify --deep --strict "$1"' _ "$APP"
printf 'Built %s\n' "$APP"
if [[ $mmm_wallet == 0 ]]; then wallet_warning; fi
if [[ "${1:-}" == "--install" ]]; then printf "\nInstalling MMM and adding its Dock icon…\n"; ./install.sh; else printf "Ready to install: ./install.sh\n"; fi
