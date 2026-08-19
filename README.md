<div align="center">

# ⚡ Watt

**Monitor termico e profili energetici per Mac Apple Silicon senza ventola.**

Ti dice quando il Mac sta rallentando per il calore — e quanto —
invece di lasciartelo scoprire aspettando.

![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%20%C2%B7%20M2%20%C2%B7%20M3%20%C2%B7%20M4-0071e3)
![Swift](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)
![Licenza](https://img.shields.io/badge/licenza-MIT-3fb950)
![Dipendenze](https://img.shields.io/badge/dipendenze-nessuna-8957e5)

</div>

```
┌──────────────────────────────────────┐
│ ⚠️ 1.19 GHz · 91°           ← in barra│
├──────────────────────────────────────┤
│  PRESTAZIONI LIMITATE   34% del max  │
│  Temperatura SoC              91 °C  │
│  P-core            1.19 di 3.50 GHz  │
│  Pacchetto                    3.5 W  │
│  Memoria disponibile         2.4 GB  │
│  Batteria / SSD          39° / 46°   │
├──────────────────────────────────────┤
│      ╭─────────────────────────╮     │
│      │  ╱╲    grafico 20 min   │     │
│      │ ╱  ╲___╱╲___ max        │     │
│      │╱─────────── media       │     │
│      ╰─────────────────────────╯     │
├──────────────────────────────────────┤
│  ● Risparmio  Automatico             │
│    Prestazioni  Massimo              │
├──────────────────────────────────────┤
│  Sveglia: durante le build (cargo)   │
│  Congela i servizi differibili       │
│  Tutti i sensori              ▸      │
└──────────────────────────────────────┘
```

---

## Installazione

```bash
git clone https://github.com/andreapianidev/watt.git && cd watt
./scripts/build.sh                          # compila e firma
sudo cp -R build/Watt.app /Applications/
sudo ./scripts/install-helper.sh            # registra l'helper privilegiato
open -a /Applications/Watt.app
```

> Va aperta con `open`, non eseguendo il binario da terminale: in quel caso
> Background Task Management attribuisce la richiesta alla shell e la
> registrazione del demone fallisce con un opaco `Operation not permitted`.

---

## 🌡 Cosa fa

| | |
|:--|:--|
| **Temperature in tempo reale** | 39 sensori, cadenza scelta da te fra 1 e 10 secondi, con il costo in CPU dichiarato accanto a ciascuna voce |
| **Avviso di throttling** | quando il sistema limita, l'icona diventa rossa e mostra a che percentuale del massimo stai girando |
| **Grafico** | massima e media degli ultimi venti minuti, con la soglia di allerta tracciata |
| **Notifiche** | soglia a 80, 85, 90 o 95 °C, con isteresi e pausa perché non diventino rumore |
| **Quattro profili energetici** | dal risparmio reale al confinamento dei servizi in background |
| **Sospensione servizi** | congela con `SIGSTOP` indicizzazione, backup e analisi foto — riprendono da dove erano |
| **Sveglia** | come Amphetamine, con in più una modalità *finché dura la build* |
| **Riga di comando** | `Watt --run massimo -- xcodebuild …` avvolge una build e ripristina da solo |

Nessuna dipendenza esterna, nessun framework di terze parti, ~2.700 righe di Swift.

---

## 📊 I numeri, misurati su un MacBook Air M2

Tutto quello che segue è riproducibile con gli script nel repository.
Nessuno di questi numeri è stimato.

### Il muro termico

Otto processi in busy-loop, campionamento ogni 15 secondi
(`./scripts/thermal-curve.sh`):

| t | P-core | E-core | Pacchetto |
|--:|--:|--:|--:|
| 0 s | **3143 MHz** | 2424 MHz | 18,5 W |
| 60 s | 2675 MHz | 2423 MHz | 12,8 W |
| 90 s | 1379 MHz | 2422 MHz | 5,1 W |
| 135 s | **1188 MHz** | 2419 MHz | 3,5 W |

**−62% di clock in 90 secondi.** E gli E-core non throttlano mai: sotto
pressione termica l'M2 sacrifica i P-core e protegge gli E-core.

### I profili servono davvero?

Stesso lavoro, tre ripetizioni alternate per annullare la deriva termica:

| profilo | mediana | differenza |
|:--|--:|--:|
| Automatico | 6,66 s | — |
| **Massimo** | 6,65 s | **+0,1%** |
| **Risparmio** | 10,68 s | **−60%** |

A macchina scarica **Massimo non dà nulla**, e va detto. L'unico profilo che
sposta il clock è Risparmio, e lo sposta all'ingiù.

### Dove invece si guadagna

Sei processi in competizione, con controprova:

| | tempo |
|:--|--:|
| macchina libera | 7,36 s |
| sei processi in competizione | 12,48 s |
| **declassati** con `taskpolicy -b` | 8,51 s |
| **congelati** con `SIGSTOP` | **6,66 s** — pari alla macchina libera |
| controprova, di nuovo attivi | 12,01 s |

Congelare riporta esattamente ai tempi della macchina libera. La CPU dei
processi congelati, misurata, è **0,0%**.

### Si può overclockare?

No, e non è una questione di permessi.

| tentativo | esito |
|:--|:--|
| `sysctl hw.cpufrequency` | vuoto su Apple Silicon, esiste solo su Intel |
| `kern.sched_recommended_cores` | sola lettura |
| scrittura tabelle DVFS in IORegistry | `kIOReturnUnsupported`, **identico da root** |
| `taskpolicy -t 0` (tier massimo) | 6,629 s contro i 6,633 s del default |

**Il default è già il massimo.** Si può solo scendere — fino a 3,8× più lenti
con `taskpolicy -b`.

---

## Perché High Power Mode non esiste su questi Mac

```console
$ pmset -a highpowermode 1
Usage: pmset <options>        ← rifiutato al parsing, non "permission denied"
```

`pmset` scarta l'opzione **prima** di controllare i privilegi: non è
registrata come valida su hardware senza ventola. `IOPMrootDomain` conferma —
`Supported Features` elenca `Hibernation`, `AdaptiveDimming`, wake-on-LAN, e
nessuna modalità prestazionale.

Il motivo è fisico: High Power Mode alza il tetto di RPM della ventola e il
limite termico. Su una macchina fanless non c'è niente da alzare.

---

## I quattro profili

| | Risparmio | Automatico | Prestazioni | Massimo |
|:--|:-:|:-:|:-:|:-:|
| `pmset lowpowermode` | **1** | baseline | 0 | 0 |
| `pmset powernap` | 0 | baseline | 0 | 0 |
| Spotlight | — | baseline | pausa | pausa |
| Time Machine | — | baseline | pausa | pausa |
| App Nap | — | — | off | off |
| Sospensione inibita | — | — | ✓ | ✓ |
| Daemon sugli E-core | — | — | — | ✓ |
| Servizi congelati | — | — | — | ✓ |
| `purge` memoria | — | — | — | ✓ |

Solo **una** riga tocca la frequenza: `lowpowermode`. Tutte le altre tolgono
lavoro concorrente — ed è il motivo per cui a macchina scarica non cambiano
niente.

*Automatico* non è un profilo neutro: ripristina esattamente lo stato
registrato alla prima esecuzione. Se Spotlight era già spento prima di
installare Watt, Watt non lo riaccende.

---

## 🔬 Come legge i dati

Il numero in barra **non** viene da `powermetrics`. `powermetrics` è solo un
client di **IOReport**, l'API IOKit che espone i contatori del silicio, e
Watt la interroga direttamente.

| dato | fonte | privilegi |
|:--|:--|:--|
| Frequenza P/E-core | IOReport, `CPU Complex Performance States` | nessuno |
| Tetto DVFS | nodo `pmgr` del registro IO, `voltage-states` | nessuno |
| Temperature | servizi HID nella pagina Apple Vendor | nessuno |
| Pressione termica | `ProcessInfo.thermalState` | nessuno |
| Memoria | `host_statistics64` | nessuno |
| Watt del package | `powermetrics`, solo a menu aperto | root |
| Applicare i profili | `pmset`, `mdutil`, `tmutil`, `taskpolicy`, `purge` | root |

Conseguenze concrete:

- **nessun processo lanciato a ogni campione**, e quindi nessuna delle gare
  sui descrittori dei pipe che affliggono chi fa `fork`/`exec` in concorrenza;
- **le letture funzionano anche con l'helper disinstallato**;
- il tetto DVFS non è inchiodato nel codice: su un M2 restituisce 3504 e 2424
  MHz, su un altro Apple Silicon restituirà i suoi.

Le frequenze si ricavano dalle residenze per stato DVFS, escludendo gli stati
di riposo: la domanda a cui la barra risponde è *a che velocità gira quando
lavora*, non *quanto ha lavorato*.

I simboli IOReport e IOHID non sono dichiarati in header pubblici e si
risolvono a runtime: se un aggiornamento di macOS li spostasse, Watt perde
quelle letture e continua a funzionare invece di crollare.

---

## 🌡 Temperature

| famiglia | sensori |
|:--|:--|
| **SoC** | `PMU tdie1..8`, `PMU2 tdie1..8` — i più caldi |
| **Alimentazione** | `PMU tdev*`, `tcal` |
| **Archiviazione** | `NAND CH*` |
| **Batteria** | `gas gauge battery` |

Il menu mostra il **massimo** fra i sensori `tdie`, non la media: è il punto
più caldo a decidere quando il sistema limita.

**Costo, misurato:** leggere tutti e 39 i sensori richiede 52 ms, i soli 16
sul die 17 ms. La barra legge solo questi ultimi; l'elenco completo si legge
quando lo apri. A un aggiornamento al secondo sono ~1,7% di un core, e la
voce di menu lo scrive accanto a ciascuna cadenza invece di nasconderlo.

---

## ☕ Sveglia

Come Amphetamine: sempre attiva, a tempo (15 min → 5 ore), oppure **finché
dura una build** — resta sveglio finché è in esecuzione `xcodebuild`,
`swift-frontend`, `cargo`, `ninja`, `ffmpeg` e simili, e lascia dormire il
Mac appena finiscono. Il menu mostra *quale* processo la sta tenendo attiva.

La lista è deliberatamente ristretta a strumenti inequivocabili: includere
`python3` o `node` significherebbe non addormentarsi mai su una macchina da
sviluppo, che è l'opposto dello scopo.

Usa `IOPMAssertion`, che il kernel rilascia da sé quando il processo termina,
anche per crash o `kill -9`.

---

## ⌨️ Riga di comando

L'app **è** anche la CLI, pensata per gli script di build:

```bash
Watt --status                  # frequenze, temperature, stato
Watt --temps                   # tutti i sensori, dal più caldo
Watt --apply massimo           # applica un profilo
Watt --suspend / --resume      # congela i servizi differibili
Watt --throttle / --unthrottle # rallenta i background che consumano
Watt --purge                   # libera la memoria inattiva
Watt --login on                # apertura automatica all'accesso
Watt --uninstall               # ripristina tutto e deregistra

# La più utile: applica, esegue, ripristina il profilo precedente
Watt --run massimo -- xcodebuild -scheme App build
```

`--run` ripristina anche se il comando fallisce o viene interrotto: uno
script morto a metà non deve lasciarti un Mac con l'indicizzazione in pausa.

---

## 🔐 Come è fatto

```
Watt.app
├─ Contents/MacOS/Watt              app AppKit (LSUIElement) + modalità CLI
├─ Contents/MacOS/watt-helper       demone root, on-demand via launchd
└─ Contents/Library/LaunchDaemons/  per la registrazione via SMAppService
```

Scelte che vale la pena conoscere prima di leggere il codice:

- **L'helper verifica chi lo chiama.** Ogni connessione XPC è validata contro
  un requisito di codesign usando l'*audit token*, non il PID: i PID sono
  riciclabili e un controllo basato su di essi è aggirabile. Se il token non
  è leggibile la connessione viene rifiutata, mai accettata «nel dubbio».
- **Ogni modifica è reversibile.** Alla prima esecuzione l'helper fotografa
  lo stato del sistema in `/Library/Application Support/Watt/baseline.json` e
  non lo sovrascrive più.
- **Le sospensioni scadono.** Trenta minuti, dopo i quali i servizi si
  riattivano da soli. Se Watt muore mentre li tiene fermi, nessuno
  collegherebbe mai Spotlight che non indicizza a un'app chiusa il giorno
  prima.
- **Non si tocca mai nulla che abbia un'interfaccia.** L'elenco dei PID
  protetti arriva dall'app; l'helper da solo non potrebbe distinguere Xcode
  che compila da un daemon che indicizza.
- **L'helper serializza ogni comando.** `fork`/`exec` concorrenti dallo stesso
  processo producono una gara sui descrittori: un figlio eredita l'estremo in
  scrittura del pipe di un altro, e il lettore attende un EOF che non arriva.
- **La sospensione usa `IOPMAssertion`, non `pmset disablesleep`**, che
  sopravvivrebbe a un crash lasciando un Mac che non dorme più.

### Compilare

```bash
./scripts/build.sh                                  # identità automatica
./scripts/build.sh "Developer ID Application: ..."  # identità esplicita
WATT_UNSIGNED=1 ./scripts/build.sh                  # ad-hoc, solo per compilare
```

Il Team ID del requisito di codesign viene letto **dalla firma reale**, non
dal nome del certificato: in un'identità *Apple Development* il valore fra
parentesi è l'ID personale dello sviluppatore e differisce dal team. Usarlo
produce un requisito che nessuna firma potrà soddisfare, e l'helper
rifiuterebbe la propria stessa app senza dire perché.

### Diagnostica

```bash
./scripts/thermal-curve.sh [campioni] [intervallo]  # misura il throttling
watt-helper --sample                                # campiona come via XPC
watt-helper --parse campione.plist                  # verifica il parser
WATT_DEBUG=1 sudo ./scripts/install-helper.sh       # stderr su file
```

---

## Disinstallare

```bash
Watt --uninstall                    # ripristina la baseline e deregistra
sudo ./scripts/uninstall-helper.sh  # rimuove il demone
```

Farlo **prima** di cestinare l'app: altrimenti Spotlight resta in pausa senza
più un'interfaccia per riattivarlo.

---

## ⚠️ Limiti noti

- **Nessun profilo sposta il limite termico.** Su un Mac senza ventola non
  esiste software che lo faccia, e questo è il fattore che domina tutti gli
  altri: essere caldi costa il 37%, il miglior profilo lo 0,1%.
- Il rallentamento mirato è stato **provato con processi sintetici**, non
  durante una build reale.
- `purge` libera circa 1 GB in 1,3 s, ma **il beneficio su una build non è
  dimostrato**: sfratta anche la cache dei file.
- `tmutil enable/disable` può richiedere Accesso completo al disco anche a
  root. Watt lo riporta come errore invece di fingere successo.
- `NSAppSleepDisabled` vale per i processi lanciati **dopo** il cambio.
- Provato solo su MacBook Air M2 (`Mac14,15`) con macOS 27.

---

## Licenza

MIT — vedi [LICENSE](LICENSE).

<div align="center">
<sub>

© 2026 Watt · Andrea Piani · NIE 02915190306-Z · El Paso, Santa Cruz de Tenerife · Islas Canarias

</sub>
</div>
