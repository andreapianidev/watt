#!/bin/bash
#
# Misura la curva di throttling termico di questo Mac.
#
# Satura tutti i core e campiona `powermetrics` a intervalli regolari,
# stampando frequenza dei cluster, potenza del package e pressione termica.
# E' l'esperimento che sta alla base delle scelte di progetto di Watt: serve
# a vedere con i propri occhi quanto e in quanto tempo la macchina rallenta.
#
#   ./scripts/thermal-curve.sh [campioni] [intervallo_secondi]
#
# Richiede sudo, perche' `powermetrics` non e' leggibile senza privilegi.
set -euo pipefail

SAMPLES="${1:-10}"
INTERVAL="${2:-15}"
OUT="$(mktemp -t thermal-curve.XXXXXX)"
CORES=$(sysctl -n hw.ncpu)
DURATION=$((SAMPLES * INTERVAL + 10))

# Il carico lo genera Watt, non la shell.
#
# La versione precedente lanciava un ciclo `while :; do :; done` per core.
# Sembrava saturare la macchina e non misurava niente: un processo di shell
# eredita la classe QoS `background`, e macOS confina i thread di quella
# classe sugli E-core. Otto cicli facevano sudare il cluster E mentre il
# cluster P restava a 1188 MHz per tutta la prova — cioe' la curva di
# throttling veniva misurata su dei core che non stavano lavorando.
#
# `Watt --load` apre i thread a QoS `userInteractive`, che e' quella di
# un'applicazione in primo piano: lo scheduler li mette sui P-core e la
# frequenza sale davvero al massimo multicore.
WATT=""
for candidate in "$(dirname "$0")/../build/Watt.app/Contents/MacOS/Watt" \
                 "/Applications/Watt.app/Contents/MacOS/Watt" \
                 "$(command -v Watt || true)"; do
    if [[ -x "$candidate" ]]; then WATT="$candidate"; break; fi
done
if [[ -z "$WATT" ]]; then
    echo "ERRORE: Watt non trovato. Compilalo con ./scripts/build.sh" >&2
    exit 1
fi

echo "==> $(sysctl -n hw.model), $CORES core"
echo "==> $SAMPLES campioni ogni ${INTERVAL}s (circa $((SAMPLES * INTERVAL))s totali)"
echo "==> Carico su $CORES thread a QoS userInteractive"

"$WATT" --load "$CORES" "$DURATION" >/dev/null 2>&1 &
LOAD=$!
# Il carico va fermato comunque, anche se lo script viene interrotto a meta'.
trap 'kill "$LOAD" 2>/dev/null || true' EXIT INT TERM

sudo powermetrics --samplers cpu_power,thermal \
    -n "$SAMPLES" -i "$((INTERVAL * 1000))" --format plist > "$OUT" 2>/dev/null

kill "$LOAD" 2>/dev/null || true

python3 - "$OUT" "$INTERVAL" <<'PYEOF'
import plistlib, sys

path, interval = sys.argv[1], int(sys.argv[2])
raw = open(path, 'rb').read()
# powermetrics separa i campioni con un byte NUL.
chunks = [c for c in raw.split(b'\x00') if b'<plist' in c]

print()
print(f"{'t':>6}  {'P-core':>10}  {'E-core':>10}  {'pacchetto':>11}  {'termico':>10}")
print("-" * 56)

first_p = None
for index, chunk in enumerate(chunks):
    doc = plistlib.loads(chunk)
    proc = doc['processor']
    clusters = {c['name']: c for c in proc['clusters']}

    def mhz(prefix):
        for name, cluster in clusters.items():
            if name.upper().startswith(prefix):
                return cluster['freq_hz'] / 1e6
        return 0.0

    p, e = mhz('P'), mhz('E')
    if first_p is None:
        first_p = p
    watts = proc['combined_power'] / 1000
    print(f"{index * interval:>5}s  {p:>7.0f}MHz  {e:>7.0f}MHz  "
          f"{watts:>9.2f} W  {doc['thermal_pressure']:>10}")

if first_p and chunks:
    last = plistlib.loads(chunks[-1])
    clusters = {c['name']: c for c in last['processor']['clusters']}
    final = next((c['freq_hz'] / 1e6 for n, c in clusters.items()
                  if n.upper().startswith('P')), 0.0)
    drop = (1 - final / first_p) * 100 if first_p else 0
    print("-" * 56)
    print(f"Calo dei P-core dal primo all'ultimo campione: {drop:.0f}%")
PYEOF

rm -f "$OUT"
