#!/bin/bash
#
# Compila Watt e assembla Watt.app con l'helper privilegiato all'interno.
#
#   ./scripts/build.sh                                  identita' automatica
#   ./scripts/build.sh "Developer ID Application: ..."  identita' esplicita
#   WATT_UNSIGNED=1 ./scripts/build.sh                  firma ad-hoc
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG=release
APP="$ROOT/build/Watt.app"

# ----------------------------------------------------------------- identita'

IDENTITY="${1:-}"
if [[ -z "$IDENTITY" && "${WATT_UNSIGNED:-0}" != "1" ]]; then
    # Preferisce Developer ID (distribuibile) ad Apple Development (locale).
    IDENTITY=$(security find-identity -v -p codesigning \
        | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"') || true
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY=$(security find-identity -v -p codesigning \
            | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"') || true
    fi
fi

SIGN_OPTS=(--options runtime)
if [[ "${WATT_UNSIGNED:-0}" == "1" || -z "$IDENTITY" ]]; then
    IDENTITY="-"
    TEAM_ID="ADHOC"
    SIGN_OPTS=()
    echo "==> Firma ad-hoc: l'helper non potra' verificare il chiamante."
    echo "    Build adatta solo a compilare, non all'uso reale."
else
    # Il Team ID si ricava firmando un binario di prova e rileggendone la
    # firma. NON va estratto dal nome dell'identita': in un certificato
    # "Apple Development" il valore fra parentesi e' l'ID personale dello
    # sviluppatore, non il team, e i due differiscono. Usare quello produce
    # un requisito che nessuna firma potra' mai soddisfare, e l'helper
    # rifiuterebbe la propria stessa app senza dire perche'.
    PROBE="$(mktemp -t watt-probe.XXXXXX)"
    cp /usr/bin/true "$PROBE"
    codesign --force --sign "$IDENTITY" "$PROBE" >/dev/null 2>&1
    TEAM_ID=$(codesign -d --verbose=4 "$PROBE" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    rm -f "$PROBE"

    if [[ -z "$TEAM_ID" || "$TEAM_ID" == "not set" ]]; then
        echo "ERRORE: impossibile determinare il Team ID da '$IDENTITY'." >&2
        exit 1
    fi
    echo "==> Identita': $IDENTITY"
    echo "==> Team ID  : $TEAM_ID"
fi

# -------------------------------------------------- iniezione del requisito

# Il requisito di codesign che l'helper impone al client deve corrispondere a
# chi sta firmando adesso: inchiodarlo nel sorgente farebbe rifiutare all'
# helper la propria stessa app su qualunque altro Mac.
CONFIG_FILE="Sources/WattKit/BuildConfig.swift"
# Il backup sta fuori da Sources/: dentro, SwiftPM lo segnalerebbe a ogni
# build come file non gestito.
CONFIG_BACKUP="$(mktemp -t watt-buildconfig.XXXXXX)"
cp "$CONFIG_FILE" "$CONFIG_BACKUP"
trap 'mv -f "$CONFIG_BACKUP" "$CONFIG_FILE" 2>/dev/null || true' EXIT

SKIP=false
[[ "$IDENTITY" == "-" ]] && SKIP=true
sed -i '' \
    -e "s/let teamIdentifier = \".*\"/let teamIdentifier = \"$TEAM_ID\"/" \
    -e "s/let skipClientVerification = .*/let skipClientVerification = $SKIP/" \
    "$CONFIG_FILE"

# -------------------------------------------------------------- compilazione

echo "==> Compilazione ($CONFIG)"

# L'helper e' un eseguibile nudo, non un bundle: il suo Info.plist va
# incorporato in __TEXT,__info_plist al momento del link. Senza, codesign non
# gli assegna alcun identificatore e SMAppService rifiuta di registrarlo.
swift build -c "$CONFIG" --product WattHelper \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$ROOT/Resources/Helper-Info.plist"

swift build -c "$CONFIG" --product WattApp \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$ROOT/Resources/App-Info.plist"

# `--show-bin-path` restituisce gia un percorso assoluto.
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

# ------------------------------------------------------------------- bundle

echo "==> Assemblaggio bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchDaemons"

cp "$ROOT/Resources/App-Info.plist" "$APP/Contents/Info.plist"

# Le traduzioni vanno nelle Resources del bundle, non dentro il package: il
# lookup passa da Bundle.main anche quando la chiamata parte da WattKit.
mkdir -p "$APP/Contents/Resources"
for lproj in "$ROOT"/Resources/*.lproj; do
    [[ -d "$lproj" ]] && cp -R "$lproj" "$APP/Contents/Resources/"
done
cp "$ROOT/Resources/dev.andreapiani.watt.helper.plist" \
   "$APP/Contents/Library/LaunchDaemons/"
cp "$BIN/WattApp"    "$APP/Contents/MacOS/Watt"
cp "$BIN/WattHelper" "$APP/Contents/MacOS/watt-helper"

# Se il flag di linker venisse ignorato, l'errore emergerebbe solo molto piu'
# tardi come un rifiuto opaco di SMAppService: meglio fallire qui.
if ! otool -s __TEXT __info_plist "$APP/Contents/MacOS/watt-helper" | grep -q 'Contents of'; then
    echo "ERRORE: Info.plist non incorporato nell'helper." >&2
    exit 1
fi

echo "==> Firma"
# Ordine obbligatorio: prima l'eseguibile annidato, poi il bundle. Firmare
# l'app per prima invaliderebbe il suo sigillo appena si tocca l'helper.
codesign --force --sign "$IDENTITY" "${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"}" \
    --identifier dev.andreapiani.watt.helper \
    "$APP/Contents/MacOS/watt-helper"

codesign --force --sign "$IDENTITY" "${SIGN_OPTS[@]+"${SIGN_OPTS[@]}"}" \
    --identifier dev.andreapiani.watt \
    "$APP"

echo "==> Verifica"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo
echo "Pronto: $APP"
echo "Avvio:  open \"$APP\""
