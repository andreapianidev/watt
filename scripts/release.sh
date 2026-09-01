#!/bin/bash
#
# Compila, firma, notarizza e impacchetta Watt per la distribuzione diretta.
#
#   ./scripts/release.sh                 build + notarizza + DMG
#   ./scripts/release.sh --app-only      si ferma dopo aver notarizzato l'app
#   ./scripts/release.sh --check         verifica solo i prerequisiti ed esce
#
# Perche' non l'App Store: Watt installa un demone che gira come root e
# risolve a runtime diciassette simboli non dichiarati in header pubblici
# (IOHID* per le temperature, IOReport* per le frequenze). Nessuna delle due
# cose e' compatibile con il sandbox obbligatorio sul Mac App Store. La via
# e' quella di tutti gli strumenti di questa categoria: Developer ID,
# notarizzazione, download diretto.
#
# CREDENZIALI
#   Nessuna nel repository. La chiave API di App Store Connect viene dal
#   vault, ~/.secrets/appstoreconnect-api.env, che definisce ASC_KEY_ID,
#   ASC_ISSUER_ID e ASC_PRIVATE_KEY_PATH. `notarytool` accetta una chiave API
#   al posto della coppia Apple ID + password specifica per app, il che evita
#   di far transitare una password dall'ambiente.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
APP="$ROOT/build/Watt.app"
STAGE="$ROOT/build/stage"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$ROOT/Resources/App-Info.plist" 2>/dev/null || echo 0.0)"
DMG="$ROOT/build/Watt-$VERSION.dmg"
ZIP="$ROOT/build/Watt-$VERSION.zip"

MODE="${1:-}"

# --------------------------------------------------------------- prerequisiti

fail() { echo "ERRORE: $*" >&2; exit 1; }

echo "==> Prerequisiti"

# 1. Il certificato. Un "Apple Development" firma ma non si notarizza: Apple
#    accetta solo Developer ID Application. E' l'errore piu' facile da fare,
#    perche' build.sh ripiega su Apple Development in silenzio e l'app
#    risultante gira benissimo su questa macchina — e su nessun'altra.
IDENTITY=$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"') || true
if [[ -z "$IDENTITY" ]]; then
    cat >&2 <<'MSG'
ERRORE: nessun certificato "Developer ID Application" in questo portachiavi.

  Un certificato "Apple Development" non basta: Apple rifiuta la
  notarizzazione di qualunque cosa non sia firmata Developer ID.

  Va creato una volta sola, su developer.apple.com → Certificates,
  Identifiers & Profiles → Certificates → + → Developer ID Application.
  Serve il ruolo Account Holder: un ruolo Admin non puo' crearlo.

  Nota: il Common Name del certificato riporta il nome legale del team, e
  quel nome e' cio' che Gatekeeper mostra all'utente al primo avvio.
MSG
    exit 1
fi
echo "    identita'   $IDENTITY"

# 2. Le credenziali per notarytool.
VAULT="$HOME/.secrets/appstoreconnect-api.env"
[[ -f "$VAULT" ]] || fail "manca $VAULT"
set -a; source "$VAULT"; set +a
: "${ASC_KEY_ID:?ASC_KEY_ID non definito in $VAULT}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID non definito in $VAULT}"
: "${ASC_PRIVATE_KEY_PATH:?ASC_PRIVATE_KEY_PATH non definito in $VAULT}"
[[ -f "$ASC_PRIVATE_KEY_PATH" ]] || fail "chiave assente: $ASC_PRIVATE_KEY_PATH"
echo "    chiave API  $ASC_KEY_ID (issuer ${ASC_ISSUER_ID:0:8}…)"

NOTARY=(--key "$ASC_PRIVATE_KEY_PATH" --key-id "$ASC_KEY_ID"
        --issuer "$ASC_ISSUER_ID")

xcrun notarytool --version >/dev/null 2>&1 \
    || fail "notarytool assente: servono gli strumenti da riga di comando di Xcode"

[[ "$MODE" == "--check" ]] && { echo "    tutto a posto."; exit 0; }

# ------------------------------------------------------------------- build

# WATT_TIMESTAMP=1: la marca temporale sicura e' obbligatoria per la
# notarizzazione, e senza Apple risponde con un errore che non la nomina.
echo
WATT_TIMESTAMP=1 "$ROOT/scripts/build.sh" "$IDENTITY"

# ---------------------------------------------------------------- notarizza

# Si invia uno zip e non la .app nuda: notarytool vuole un contenitore, e lo
# zip va fatto con ditto, non con `zip`, perche' solo ditto conserva i link
# simbolici e gli attributi estesi del bundle.
submit() {
    local what="$1"
    echo
    echo "==> Notarizzazione di $(basename "$what")"
    local log; log="$(mktemp -t watt-notary.XXXXXX)"
    if ! xcrun notarytool submit "$what" "${NOTARY[@]}" --wait \
            --output-format json > "$log"; then
        cat "$log" >&2
        fail "invio fallito"
    fi
    local id status
    id=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$log")
    status=$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$log")
    echo "    id $id — $status"
    if [[ "$status" != "Accepted" ]]; then
        # Il verdetto da solo non dice cosa correggere: il log si', ed e'
        # l'unica cosa che distingue "manca la marca temporale" da "un
        # eseguibile annidato non e' firmato".
        echo "--- log di notarizzazione ---" >&2
        xcrun notarytool log "$id" "${NOTARY[@]}" >&2 || true
        fail "notarizzazione rifiutata"
    fi
    rm -f "$log"
}

rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
submit "$ZIP"

# La graffetta va sull'app, non solo sullo zip: senza, il primo avvio su una
# macchina offline deve chiedere ad Apple e fallisce.
echo "==> Graffetta sull'app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Lo zip va rifatto: quello inviato contiene l'app senza graffetta.
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

[[ "$MODE" == "--app-only" ]] && { echo; echo "Pronto: $ZIP"; exit 0; }

# ---------------------------------------------------------------------- DMG

echo
echo "==> DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
/usr/bin/ditto "$APP" "$STAGE/Watt.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Watt $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Anche il DMG si notarizza e si graffetta: e' il file che l'utente scarica,
# ed e' su quello che Gatekeeper fa il primo controllo.
submit "$DMG"
xcrun stapler staple "$DMG"

# ------------------------------------------------------------------ verifica

echo
echo "==> Verifica finale"
xcrun stapler validate "$DMG" | sed 's/^/    /'
# `spctl` e' il giudizio di Gatekeeper, cioe' esattamente quello che vedra'
# chi scarica. Verificare la firma con codesign non basta: una firma valida
# ma non notarizzata passa codesign e viene bloccata da Gatekeeper.
spctl --assess --type exec --verbose=4 "$APP" 2>&1 | sed 's/^/    /'
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "Pronto:"
echo "  $DMG"
echo "  $ZIP"
echo
shasum -a 256 "$DMG" "$ZIP" | sed 's/^/  /'
