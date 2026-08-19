#!/bin/bash
#
# Installa watt-helper direttamente in launchd, senza passare da
# SMAppService.
#
# SMAppService e' la strada moderna e quella giusta per distribuire l'app ad
# altri: mostra il demone in Impostazioni di Sistema e lo rende
# disinstallabile con un clic. In cambio pretende che l'utente lo approvi a
# mano, e finche' non lo fa nulla funziona.
#
# Questo script fa l'installazione classica: binario in
# /Library/PrivilegedHelperTools, plist in /Library/LaunchDaemons, bootstrap
# immediato. Serve root e non serve nessun clic.
#
#   sudo ./scripts/install-helper.sh [percorso/Watt.app]
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Serve root: sudo $0" >&2
    exit 1
fi

APP="${1:-/Applications/Watt.app}"
LABEL="dev.andreapiani.watt.helper"
SRC="$APP/Contents/MacOS/watt-helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[[ -x "$SRC" ]] || { echo "Helper non trovato in $SRC" >&2; exit 1; }

# Lo stderr di un demone launchd non finisce nel log unificato in modo
# affidabile, e su file e' l'unico modo di diagnosticare un comando che
# fallisce solo in quel contesto. Resta pero' spento: un file di log che
# nessuno ruota cresce senza limite per sempre.
#
#   WATT_DEBUG=1 sudo ./scripts/install-helper.sh
LOG_ENTRY=""
if [[ "${WATT_DEBUG:-0}" == "1" ]]; then
    LOG_ENTRY=$'    <key>StandardErrorPath</key>\n    <string>/var/log/watt-helper.log</string>'
    echo "==> Diagnostica attiva: /var/log/watt-helper.log"
fi

# Verifica la firma prima di installare qualcosa come root: se il binario e'
# stato manomesso dopo la build, e' l'ultimo momento utile per accorgersene.
if ! codesign --verify --strict "$SRC" 2>/dev/null; then
    echo "ATTENZIONE: firma dell'helper non valida." >&2
    echo "Installo comunque solo se WATT_FORCE=1." >&2
    [[ "${WATT_FORCE:-0}" == "1" ]] || exit 1
fi

echo "==> Scarico eventuale versione precedente"
launchctl bootout "system/$LABEL" 2>/dev/null || true

echo "==> Copio l'helper in $DEST"
mkdir -p /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel "$SRC" "$DEST"

echo "==> Scrivo $PLIST"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>Program</key>
    <string>$DEST</string>
    <!-- Avvio su richiesta alla prima connessione XPC: nessun RunAtLoad, un
         demone root residente senza motivo e' superficie d'attacco gratuita.
         L'helper esce da solo dopo tre minuti di inattivita'. -->
    <key>MachServices</key>
    <dict>
        <key>$LABEL</key>
        <true/>
    </dict>
$LOG_ENTRY
</dict>
</plist>
PLISTEOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "==> Carico il demone"
launchctl bootstrap system "$PLIST"

echo "==> Verifica"
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "    $LABEL registrato e in ascolto."
else
    echo "    ERRORE: il demone non risulta registrato." >&2
    exit 1
fi
