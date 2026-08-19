#!/bin/bash
#
# Rimuove watt-helper installato con install-helper.sh.
#
# Prima fa ripristinare al demone la baseline del sistema, poi lo scarica:
# nell'ordine inverso non resterebbe nessuno a riaccendere Spotlight.
#
#   sudo ./scripts/uninstall-helper.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Serve root: sudo $0" >&2
    exit 1
fi

LABEL="dev.andreapiani.watt.helper"
BASELINE="/Library/Application Support/Watt/baseline.json"

if [[ -f "$BASELINE" ]]; then
    echo "==> Ripristino le impostazioni originali"
    # Rilegge la baseline e la riapplica con i tool di sistema: non dipende
    # dall'helper, che potrebbe gia' essere stato rimosso a meta'.
    python3 - "$BASELINE" <<'PYEOF'
import json, subprocess, sys
baseline = json.load(open(sys.argv[1]))
def pmset(key, value):
    subprocess.run(["/usr/bin/pmset", "-a", key, "1" if value else "0"])
pmset("lowpowermode", baseline.get("lowPowerMode", False))
pmset("powernap", baseline.get("powerNap", False))
pmset("disablesleep", baseline.get("sleepDisabled", False))
subprocess.run(["/usr/bin/mdutil", "-a", "-i",
                "on" if baseline.get("spotlightIndexing", True) else "off"])
subprocess.run(["/usr/bin/tmutil",
                "enable" if baseline.get("timeMachineAutomatic", True) else "disable"])
print("    baseline riapplicata")
PYEOF
    rm -f "$BASELINE"
    rmdir "/Library/Application Support/Watt" 2>/dev/null || true
fi

echo "==> Scarico il demone"
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -f "/Library/PrivilegedHelperTools/$LABEL"
echo "    rimosso"
