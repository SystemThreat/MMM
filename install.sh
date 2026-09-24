#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# A failed or interrupted build leaves a partial, unsigned bundle: never install one.
mmm_ok() {
 codesign --verify --deep --strict "$1" 2>/dev/null || return 1
 for f in MacOS/MMM Info.plist Resources/NerdMiner Resources/MMM.icns Resources/index.html Resources/style.css Resources/app.js Resources/identicon.js Resources/pickaxe-white.svg; do [[ -f "$1/Contents/$f" ]] || return 1; done
}
mmm_ok build/MMM.app || ./build.sh
mmm_ok build/MMM.app || { echo 'build/MMM.app is incomplete or fails codesign verification; not installing.' >&2; exit 1; }
mkdir -p "$HOME/Applications"
if pgrep -x MMM >/dev/null 2>&1; then echo 'Quit MMM before installing an update.'; exit 1; fi
# Copy beside the old app, verify, then swap: ditto over the old app would merge
# (stale files break its seal) and a failed copy would leave it half-updated.
DEST="$HOME/Applications/MMM.app" NEW="$HOME/Applications/.MMM.app.new" OLD="$HOME/Applications/.MMM.app.old"
rm -rf "$NEW" "$OLD"
trap 'rm -rf "$NEW"; if [[ ! -e "$DEST" && -e "$OLD" ]]; then mv "$OLD" "$DEST"; fi' EXIT
ditto build/MMM.app "$NEW"
mmm_ok "$NEW" || { echo "The copy at $NEW fails codesign verification; not installing." >&2; exit 1; }
if [[ -e "$DEST" ]]; then mv "$DEST" "$OLD"; fi
mv "$NEW" "$DEST"
rm -rf "$OLD"
python3 - "$HOME/Applications/MMM.app" <<'PY'
import plistlib,subprocess,sys,pathlib
app=pathlib.Path(sys.argv[1]).resolve()
raw=subprocess.check_output(['defaults','export','com.apple.dock','-'])
prefs=plistlib.loads(raw)
uri=app.as_uri()+'/'
items=prefs.get('persistent-apps',[])
if not any(x.get('tile-data',{}).get('file-data',{}).get('_CFURLString')==uri for x in items):
    tile={'tile-data':{'file-data':{'_CFURLString':uri,'_CFURLStringType':15},'file-label':'MMM','file-type':41},'tile-type':'file-tile'}
    # Only append the new entry; preserve all other Dock preferences.
    xml=plistlib.dumps(tile).decode()
    subprocess.run(['defaults','write','com.apple.dock','persistent-apps','-array-add',xml],check=True)
    subprocess.run(['killall','Dock'],check=False)
PY
open "$HOME/Applications/MMM.app"
