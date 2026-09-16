#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[[ -d build/MMM.app ]] || ./build.sh
mkdir -p "$HOME/Applications"
if pgrep -x MMM >/dev/null 2>&1; then echo 'Quit MMM before installing an update.'; exit 1; fi
ditto build/MMM.app "$HOME/Applications/MMM.app"
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
