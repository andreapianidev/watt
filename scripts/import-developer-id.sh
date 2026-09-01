#!/bin/bash
#
# Completa l'emissione del certificato Developer ID Application.
#
#   ./scripts/import-developer-id.sh ~/Downloads/developerID_application.cer
#
# La chiave privata e' gia' stata generata e sta nel vault: questo script la
# unisce al certificato scaricato da Apple e installa l'identita' nel
# portachiavi, dove `codesign` la trova.
#
# Perche' la chiave e' nel vault e non solo nel portachiavi: un portachiavi
# non si copia su un'altra macchina e non finisce nell'archivio cifrato su
# iCloud. Un certificato Developer ID senza la sua chiave privata e' carta
# straccia, e Apple non la rigenera — si puo' solo revocare e ricominciare.
set -euo pipefail

CER="${1:-}"
[[ -n "$CER" && -f "$CER" ]] || {
    echo "Uso: $0 <certificato.cer scaricato da developer.apple.com>" >&2
    exit 2
}

VAULT="$HOME/.secrets/appstoreconnect-developerid.env"
[[ -f "$VAULT" ]] || { echo "ERRORE: manca $VAULT" >&2; exit 1; }
set -a; source "$VAULT"; set +a
: "${DEVELOPER_ID_KEY_PATH:?}" "${DEVELOPER_ID_P12_PASSWORD:?}"
[[ -f "$DEVELOPER_ID_KEY_PATH" ]] || {
    echo "ERRORE: chiave privata assente: $DEVELOPER_ID_KEY_PATH" >&2; exit 1; }

WORK="$(mktemp -d -t watt-devid.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
umask 077

# Apple consegna il certificato in DER; openssl lo vuole in PEM per costruire
# il PKCS#12.
openssl x509 -inform DER -in "$CER" -out "$WORK/cert.pem" 2>/dev/null \
    || cp "$CER" "$WORK/cert.pem"

SUBJECT=$(openssl x509 -in "$WORK/cert.pem" -noout -subject)
echo "==> Certificato"
echo "    $SUBJECT"
case "$SUBJECT" in
    *"Developer ID Application"*) ;;
    *) echo "ERRORE: non e' un Developer ID Application." >&2; exit 1 ;;
esac

# La chiave e il certificato devono corrispondere. Se non corrispondono
# l'importazione riesce lo stesso e il fallimento arriva molto piu' tardi,
# come una firma che il portachiavi rifiuta senza spiegare perche'.
KEY_MOD=$(openssl rsa  -in "$DEVELOPER_ID_KEY_PATH" -noout -modulus | openssl md5)
CRT_MOD=$(openssl x509 -in "$WORK/cert.pem"         -noout -modulus | openssl md5)
[[ "$KEY_MOD" == "$CRT_MOD" ]] || {
    echo "ERRORE: il certificato non appartiene a questa chiave privata." >&2
    echo "        Hai caricato una CSR diversa da quella nel vault?" >&2
    exit 1
}
echo "    chiave e certificato corrispondono"

openssl pkcs12 -export -legacy \
    -inkey "$DEVELOPER_ID_KEY_PATH" -in "$WORK/cert.pem" \
    -name "Developer ID Application" \
    -out "$WORK/identity.p12" -passout "pass:$DEVELOPER_ID_P12_PASSWORD" 2>/dev/null \
|| openssl pkcs12 -export \
    -inkey "$DEVELOPER_ID_KEY_PATH" -in "$WORK/cert.pem" \
    -name "Developer ID Application" \
    -out "$WORK/identity.p12" -passout "pass:$DEVELOPER_ID_P12_PASSWORD"

echo "==> Importazione nel portachiavi"
# -T /usr/bin/codesign: senza, ogni firma apre una finestra di conferma.
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security

# Copia del .p12 nel vault: e' il formato che si reinstalla su una macchina
# nuova con un comando solo.
cp "$WORK/identity.p12" "$HOME/.secrets/appstoreconnect-developerid-application.p12"
chmod 600 "$HOME/.secrets/appstoreconnect-developerid-application.p12"

echo "==> Verifica"
security find-identity -v -p codesigning | grep "Developer ID Application" || {
    echo "ERRORE: l'identita' non compare fra quelle valide per la firma." >&2
    exit 1
}

cat <<'MSG'

Fatto. Due cose da sapere:

  · Alla prima firma macOS puo' chiedere il permesso di usare la chiave.
    Scegli "Consenti sempre", altrimenti lo richiedera' a ogni build.
    Per evitarlo del tutto, una volta sola:

      security set-key-partition-list -S apple-tool:,apple: \
        -k "<password del tuo login>" ~/Library/Keychains/login.keychain-db

  · Il .p12 e la chiave privata sono nel vault. Ricostruisci l'archivio
    cifrato su iCloud prima di considerare finita la cosa:

      P=$(security find-generic-password -s secrets-vault-backup -w)
      tar czf - -C ~/.secrets . | openssl enc -aes-256-cbc -pbkdf2 \
        -iter 600000 -salt -pass "pass:$P" \
        -out ~/Library/Mobile\ Documents/com~apple~CloudDocs/secrets-vault-backup/secrets-vault-$(date +%FT%H%M%S).tar.gz.enc

Poi:  ./scripts/release.sh
MSG
