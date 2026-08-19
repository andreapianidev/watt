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
fi

SUSPENDED="/Library/Application Support/Watt/suspended.json"
if [[ -f "$SUSPENDED" ]]; then
    echo "==> Riattivo i servizi congelati"
    # Un processo fermato con SIGSTOP resta fermo finche' qualcuno non gli
    # manda SIGCONT. Se l'helper sparisce prima, quel qualcuno non esiste
    # piu' e Spotlight resta fermo fino al riavvio.
    python3 - "$SUSPENDED" <<'PY_RESUME'
import json, os, signal, subprocess, sys
state = json.load(open(sys.argv[1]))
resumed = 0
for pid, name in zip(state.get("pids", []), state.get("names", [])):
    # Il PID puo' essere stato riciclato: si riattiva solo se porta ancora
    # lo stesso nome.
    actual = subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(pid)],
                            capture_output=True, text=True).stdout.strip()
    if not actual or os.path.basename(actual) != name:
        continue
    try:
        os.kill(pid, signal.SIGCONT)
        resumed += 1
    except OSError:
        pass
print(f"    riattivati {resumed} processi")
PY_RESUME
    rm -f "$SUSPENDED"
fi

rmdir "/Library/Application Support/Watt" 2>/dev/null || true

echo "==> Scarico il demone"
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -f "/Library/PrivilegedHelperTools/$LABEL"
echo "    rimosso"
