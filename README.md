# Watt

Selettore di profilo energetico nella barra dei menu per Mac Apple Silicon
senza ventola, con misura reale del throttling termico.

Nasce da una domanda semplice — «posso avere sul MacBook Air la stessa voce
Bassa / Automatica / Alta che hanno i MacBook Pro?» — e da una risposta
scomoda: no, non quella. Watt fa la cosa utile che si può fare davvero.

## Perché High Power Mode non è replicabile

Non è un blocco software da aggirare. Su un MacBook Air M2 (`Mac14,15`):

```
$ pmset -a highpowermode 1
Usage: pmset <options>        ← rifiutato al parsing, non "permission denied"
```

`pmset` scarta l'opzione **prima** di controllare i privilegi: non è
registrata come valida su questo hardware. `IOPMrootDomain` conferma —
`Supported Features` elenca `Hibernation`, `AdaptiveDimming`, wake-on-LAN, e
nessuna modalità prestazionale. Da root il risultato è identico.

Il motivo è fisico: High Power Mode alza il tetto di RPM della ventola e il
limite termico. Su una macchina fanless non c'è niente da alzare.

Vale anche la pena dirlo perché è controintuitivo: **su Apple Silicon non
esiste un turbo nascosto da sbloccare**. I P-core dell'M2 boostano già a
3504 MHz di default, a batteria come in carica, e il DVFS non è esposto né a
userspace né a kext. Non esiste un equivalente di Turbo Boost Switcher.

## Cosa limita davvero un Air, con i numeri

Otto processi in busy-loop, `powermetrics` campionato ogni 15 secondi
(riproducibile con `./scripts/thermal-curve.sh`):

| t | P-core | E-core | Pacchetto | Pressione |
|---:|---:|---:|---:|:---|
| 0 s | **3143 MHz** | 2424 MHz | 18,5 W | Heavy |
| 30 s | 2871 MHz | 2423 MHz | 14,7 W | Heavy |
| 60 s | 2675 MHz | 2423 MHz | 12,8 W | Heavy |
| 90 s | 1379 MHz | 2422 MHz | 5,1 W | Heavy |
| 135 s | **1188 MHz** | 2419 MHz | 3,5 W | Heavy |

Due fatti che nessuna interfaccia di sistema mostra:

1. **I P-core perdono il 62% del clock in circa 90 secondi** di carico
   sostenuto, e la potenza del package crolla da 18,5 W a 3,5 W. Il pavimento
   è 1188 MHz. È questo il vero limite della macchina, non un'impostazione.
2. **Gli E-core non throttlano mai** — 2424 MHz all'inizio, 2419 alla fine.
   Sotto pressione termica l'M2 sacrifica i P-core e protegge gli E-core.

Il secondo punto è ciò che rende sensato il profilo *Massimo*: confinare i
daemon di sistema sugli E-core li sposta su core che restano a piena
velocità, liberando quelli che stanno collassando.

## I quattro profili

| | Cosa fa | Alza il clock? |
|:--|:--|:--|
| **Risparmio** | Low Power Mode, Power Nap spento | Lo **abbassa**, in modo reale |
| **Automatico** | Ripristina lo stato registrato alla prima esecuzione | — |
| **Prestazioni** | Low Power Mode spento, Spotlight e Time Machine in pausa, App Nap disattivato, sospensione inibita | No: toglie contesa |
| **Massimo** | Come sopra, più i daemon noti confinati sugli E-core | No: toglie contesa |

Low Power Mode è l'unica leva che incide davvero sulla frequenza, e agisce in
una sola direzione. Gli altri profili liberano CPU e I/O da lavoro
rinviabile; su un carico che stava già saturando i core il guadagno esiste ma
è modesto, e sparisce comunque quando arriva il limite termico.

La barra dei menu mostra la frequenza dei P-core e, quando `thermal_pressure`
non è `Nominal`, cambia icona per dirti che stai throttlando. È
l'informazione per cui vale la pena installare l'app.

## Come legge i dati: IOReport, non powermetrics

Il numero in barra dei menu **non** viene da `powermetrics`. `powermetrics`
è solo un client di **IOReport**, l'API IOKit che espone i contatori del
silicio, e Watt la interroga direttamente:

- **nessun processo lanciato a ogni campione** — e quindi nessuna delle gare
  sui descrittori dei pipe che affliggono chi fa `fork`/`exec` in
  concorrenza;
- **nessun privilegio richiesto** — le frequenze si vedono anche con
  l'helper disinstallato;
- **risposta immediata**, contro il mezzo secondo di una sessione di
  `powermetrics`.

Le frequenze si ricavano dalle residenze per stato DVFS dei due complessi
(`CPU Stats` → `CPU Complex Performance States`), pesate sulla tabella
`voltage-states` letta dal nodo `pmgr` del registro IO. Quella tabella
non è inchiodata nel codice: su questo M2 restituisce 3504 MHz per i P-core
e 2424 per gli E-core, ma su un altro Apple Silicon restituirà i suoi.

La media esclude gli stati di riposo, perché la domanda a cui la barra dei
menu risponde è «a che velocità gira quando lavora», non «quanto ha
lavorato»: includerli farebbe crollare il numero proprio quando il Mac è
fermo, cioè quando interessa meno. È la stessa convenzione di `freq_hz` in
`powermetrics`, verificata ricalcolandola a mano dalle residenze.

La pressione termica arriva da `ProcessInfo.thermalState`, che è API
pubblica e gratuita. `powermetrics` resta usato per una cosa sola, i watt
del package, e solo mentre il menu è aperto.

I simboli IOReport vivono in `/usr/lib/libIOReport.dylib` e non sono
dichiarati in alcun header pubblico, quindi si risolvono a runtime: se un
aggiornamento di macOS li spostasse, Watt perde quelle letture e continua a
funzionare invece di crollare.

## Come è fatto

```
Watt.app
├─ Contents/MacOS/Watt              app AppKit, LSUIElement + modalità CLI
├─ Contents/MacOS/watt-helper       demone root, on-demand via launchd
└─ Contents/Library/LaunchDaemons/  per la registrazione via SMAppService
```

Servono privilegi di root solo per **applicare** i profili: `pmset`,
`mdutil`, `tmutil`, `taskpolicy`, `purge`. Tutte le **letture** — frequenze,
tetto DVFS, stato termico, memoria — avvengono nell'app senza privilegi.

Scelte che vale la pena conoscere prima di leggere il codice:

- **L'helper verifica chi lo chiama.** Ogni connessione XPC è validata contro
  un requisito di codesign (identifier + team ID) usando l'*audit token*, non
  il PID: i PID sono riciclabili e un controllo basato su di essi è
  aggirabile. Se il token non è leggibile la connessione viene rifiutata, mai
  accettata «nel dubbio». Senza questo, un demone root sarebbe pilotabile da
  qualunque processo dell'utente.
- **Ogni modifica è reversibile.** Alla prima esecuzione l'helper fotografa
  lo stato del sistema in `/Library/Application Support/Watt/baseline.json` e
  non lo sovrascrive più. *Automatico* ci ritorna sopra. Se Spotlight era già
  spento prima di installare Watt, Watt non lo riaccende.
- **La sospensione si inibisce con una `IOPMAssertion`, non con
  `pmset disablesleep`.** L'assertion muore col processo, anche per crash.
  L'impostazione di pmset sopravvivrebbe, lasciando un Mac che non dorme più
  e nessun indizio sul perché.
- **App Nap lo scrive l'app, non l'helper.** `defaults -g` eseguito da root
  finisce nelle preferenze di root, dove non ha alcun effetto sulla sessione
  grafica.
- **Lo stato mostrato è riletto dal sistema**, non dedotto dal profilo
  selezionato: se cambi Low Power Mode da Impostazioni di Sistema, il menu lo
  dice.
- **L'helper serializza ogni esecuzione di comandi.** Lanciare processi in
  concorrenza dallo stesso demone produce una gara sui descrittori: un figlio
  eredita l'estremo in scrittura del pipe di un altro, e il lettore resta
  bloccato su un EOF che non arriva mai. Costava un `powermetrics` che
  sembrava non terminare, con zero byte letti.
- **Il confino dei daemon sugli E-core si applica solo se cambia.**
  Rilanciare `taskpolicy` su tutta la lista a ogni cambio di profilo costava
  quasi dieci secondi per clic, quasi sempre per non cambiare nulla.

## Compilare

```bash
./scripts/build.sh                 # identità di firma automatica
./scripts/build.sh "Developer ID Application: ..."
WATT_UNSIGNED=1 ./scripts/build.sh # firma ad-hoc, solo per compilare
```

Il requisito di codesign imposto dall'helper viene iniettato a build time
leggendo il Team ID **dalla firma reale**, non dal nome del certificato: in
un certificato *Apple Development* il valore fra parentesi è l'ID personale
dello sviluppatore e differisce dal team, e usarlo produce un requisito che
nessuna firma potrà mai soddisfare.

Poi:

```bash
cp -R build/Watt.app /Applications/
open /Applications/Watt.app
```

Va lanciata con `open`, non eseguendo il binario da terminale: in quel caso
Background Task Management attribuisce la richiesta alla shell e la
registrazione del demone fallisce con un opaco `Operation not permitted`.

Al primo avvio il demone resta in attesa: va abilitato in **Impostazioni di
Sistema → Generali → Elementi login ed estensioni**. Finché non lo fai
restano attivi solo i profili nella parte che non richiede privilegi.

## Sveglia (come Amphetamine)

Il secondo mestiere dell'app. Impedisce al Mac di addormentarsi, con le
modalità che servono davvero:

- **Sempre attiva**, finché non la spegni;
- **a tempo** — 15 minuti, 30, 1 ora, 2, 5;
- **durante le build**, che è quella per cui è nata: tiene sveglio il Mac
  finché è in esecuzione `xcodebuild`, `swift-frontend`, `node`, `cargo`,
  `make`, `docker`, `ffmpeg` e simili, e lo lascia dormire appena finiscono.
  Il menu mostra *quale* processo la sta tenendo attiva, così non è una
  scatola nera.

Opzionale: tenere acceso anche lo schermo. Di default no — un profilo
prestazionale non è una buona ragione per illuminare un pannello che nessuno
guarda.

Usa `IOPMAssertion`, che il kernel rilascia da sé quando il processo termina,
anche per crash o `kill -9`. Non c'è nessuno stato persistente e nessun modo
di lasciare il Mac sveglio per sempre per sbaglio.

## Riga di comando

L'app **è** anche la CLI, ed è pensata per gli script di build:

```bash
Watt --status                  # frequenze, termico, stato (senza helper: funziona lo stesso)
Watt --apply massimo           # applica un profilo
Watt --purge                   # libera la memoria inattiva
Watt --profiles                # cosa fa ciascun profilo

# La più utile: applica un profilo, esegue, ripristina il precedente
Watt --run massimo -- xcodebuild -scheme App build
```

`--run` ripristina il profilo precedente anche se il comando fallisce o viene
interrotto: uno script morto a metà non deve lasciarti un Mac con
l'indicizzazione in pausa.

## Strumenti

```bash
./scripts/thermal-curve.sh [campioni] [intervallo]   # misura il throttling
./build/Watt.app/Contents/MacOS/watt-helper --parse campione.plist
```

Il secondo mostra come Watt interpreta un output di `powermetrics` già
catturato: utile per verificare il parser su hardware o versioni di macOS
diverse, senza installare nulla e senza root.

## Disinstallare

Dal menu, *Ripristina impostazioni e rimuovi helper*: ritorna alla baseline e
deregistra il demone. Farlo **prima** di cestinare l'app, altrimenti Spotlight
resta in pausa senza più un'interfaccia per riattivarlo.

## Limiti noti

- `tmutil enable/disable` può richiedere Accesso completo al disco anche a
  root. Watt lo riporta come errore invece di fingere successo.
- `NSAppSleepDisabled` viene letto da macOS all'avvio di ogni app: vale per i
  processi lanciati dopo, non per quelli già in esecuzione.
- Ogni campione fa girare `powermetrics` per mezzo secondo. L'intervallo di
  default è 15 secondi proprio per non rendere l'app parte del problema che
  dice di misurare.
- Nessuno di questi profili sposta il limite termico. Su un Air non esiste
  software che lo faccia.

## Licenza

MIT — vedi [LICENSE](LICENSE).

© 2026 Watt · Andrea Piani · NIE 02915190306-Z · El Paso, Santa Cruz de Tenerife · Islas Canarias
