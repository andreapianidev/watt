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

[English](README.md) · [andreapiani.com](https://andreapiani.com) · [Installazione](#installazione) · [I numeri](#-i-numeri-misurati-su-un-macbook-air-m2)

</div>

<div align="center">
  <img src="docs/watt-menu.png" alt="L'elemento di Watt in barra dei menu e il suo pannello: frequenza e temperatura in barra, diagnosi delle limitazioni, profili di potenza, misure in tempo reale e grafico della temperatura" width="380">
</div>

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

Nessuna dipendenza esterna, nessun framework di terze parti, ~3.400 righe di
Swift. L'interfaccia è **bilingue, italiano e inglese**, e segue da sola la
lingua di macOS.

### Ti dice cosa ti sta rallentando davvero

La cosa più utile non è il selettore di profili — misurato, vale lo 0,1%. È la
diagnosi:

```console
$ Watt --diagnose

!! LA RAM NON BASTA: IL SISTEMA STA SCRIVENDO SU DISCO
      5,69 GB di swap in uso, 1,90 GB compressi
      → Chiudi ciò che non ti serve adesso — i più ingombranti sono
        Unity (1,1 GB), WebKit (0,6 GB). «Libera memoria» non aiuta in
        questo caso: purge scarta la cache dei file, non riporta in RAM
        ciò che è già finito sullo swap.
      base: una pagina letta dallo swap costa ordini di grandezza più di
        una in RAM, e nessun profilo energetico la sposta di un microsecondo
```

È una esecuzione reale sulla macchina di sviluppo, con Unity aperto, ed è
riportata com'è uscita. Oggi lo stesso verdetto apre anche con la velocità,
perché lo swap occupato da solo si è rivelato non voler dire niente: macOS non
lo restituisce finché non gli serve la stanza, quindi restano gigabyte lì per
giorni con la pressione di memoria verde e nemmeno una pagina che si muove. A
far scattare l'avviso adesso sono le pagine al secondo che vanno su disco. Il
Mac
**non** era limitato dal calore né dalla CPU: stava swappando, e nessuno dei
quattro profili tocca quel problema. Quattro volte su cinque il collo di
bottiglia non è quello che immagini, ed è esattamente il motivo per cui un
selettore da solo non basta.

Ogni verdetto porta con sé la base su cui poggia. Un consiglio senza un numero
dietro è un'opinione, e di opinioni sulle prestazioni ce ne sono già
abbastanza.

---

### In parole semplici, senza uscire dal Mac

Un verdetto come quello qui sopra è preciso e, per qualcuno, illeggibile. Watt
lo può riscrivere con il modello di Apple Intelligence che gira sul dispositivo:

```console
$ Watt --explain

!! LA RAM NON BASTA: IL SISTEMA STA SCRIVENDO SU DISCO
      12 MB/s su swap adesso, 3.40 GB in uso, 5.10 GB compressi
      ...

in parole semplici:
      Il sistema sta scrivendo sul disco invece di usare la memoria.
      Chiudi ciò che non hai bisogno adesso, i più grandi sono Xcode e Chrome.
```

Le due frasi sono quelle che il modello ha restituito davvero per quei numeri.
I numeri invece gli sono stati dati come caso di prova, non letti dai sensori
in quel momento.

Anche nel menu, sotto la diagnosi, come «Spiegamelo in parole semplici».

**Il modello non diagnostica.** La causa, la misura e il rimedio li decide il
codice leggendo i sensori, e il modello si limita a riscriverli. È una riga che
vale la pena tenere ferma, perché il contrario è stato provato: dati i numeri
grezzi e chiesto cosa non andasse, il modello sul dispositivo si è inventato
una causa che non esisteva («la pressione sul pacchetto di 3,5 watt») e ha
proposto un rimedio che non vuol dire niente. Vincolato a riformulare, non
sbanda.

La generazione è guidata e non libera per la stessa ragione. A testo libero,
sugli stessi fatti, aggiungeva una condizione che nessuno gli aveva dato («se
non c'è aria fresca»). Due campi corti da riempire non gliene lasciano lo
spazio.

In pratica:

| | |
|---|---|
| Dove gira | Sul Mac. Niente rete, niente account, niente chiave API. |
| Cosa manda fuori | Niente. |
| Cosa vedi sempre | I numeri misurati, parola per parola, sopra il testo riscritto. |
| Se Apple Intelligence è spenta | La voce non compare. Nient'altro cambia. |
| Su macOS 14 e 15 | Il framework è collegato in modo debole. L'app parte normalmente e la funzione si dichiara assente. |

Misurato su un M2 Air: da 2,3 a 3,8 secondi per spiegazione.

---

### Gli avvisi li scegli tu

Tre avvisi, ognuno con il suo interruttore in Impostazioni, perché quale conti
dipende da cosa fai:

| Avviso | Scatta quando | Acceso di suo |
|---|---|---|
| Quando scalda | Il die supera la soglia scelta, da 80 a 95 °C | sì |
| Quando le prestazioni iniziano a essere limitate | Nel momento in cui il Mac smette di andare al massimo, con quanto ha perso | sì |
| Quando il sistema inizia a scrivere su disco | Le pagine cominciano davvero ad andare su disco | no |

Lo swap è spento di suo perché chi non compila non lo incontra mai, e un
avviso che non riguarda chi lo riceve insegna a ignorare gli altri due.

Ogni avviso ha la sua pausa di dieci minuti e la sua isteresi: restare limitati
per venti minuti è una notizia sola, non venti.

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
| Pressione termica | `com.apple.system.thermalpressurelevel`, notify(3) | nessuno |
| Batteria, alimentatore, presa | `AppleSmartBattery` nel registro IO | nessuno |
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
lavora*, non *quanto ha lavorato*. Non è la stessa definizione che
`powermetrics` usa per `freq_hz`, che media su tutto l'intervallo. A cluster
saturo le due coincidono **alla cifra** — `--verify-freq` sotto carico dà
scarto 0 MHz su entrambi i cluster; a cluster fermo divergono di centinaia di
megahertz e hanno ragione tutt'e due, perché stanno rispondendo a due domande
diverse. `--verify-freq` adesso scarta i campioni in cui una delle due parti
dichiara più del 10% di riposo, e lo scrive.

### La pressione termica senza `powermetrics`

Neanche `powermetrics` misura la pressione termica: la legge. Fra le stringhe
del suo binario c'è `thermal pressure notifications`, e la notifica in
questione è `kOSThermalNotificationPressureLevelName` di
`<libkern/OSThermalNotification.h>`, cioè la chiave notify(3)
`com.apple.system.thermalpressurelevel`. Il kernel ci pubblica un intero, su
macOS da 0 a 4, che corrisponde uno a uno ai nomi che `powermetrics` stampa
in `thermal_pressure` — lo stesso campo che asitop riduce a
`throttle: yes/no`.

Watt quindi la legge direttamente. Verificata appaiata con `powermetrics`
sugli stessi istanti da `Watt --verify-pressure`: accordo su tutti i campioni,
compresa una transizione `Heavy → Moderate` colta a metà. Costa **0,01 ms**
contro i ~500 ms di un campione di `powermetrics`, non richiede root e
funziona con l'helper disinstallato — il che significa che la misura vera è
disponibile **sempre**, non solo a menu aperto. `ProcessInfo.thermalState`
resta come ultimo ripiego ed è etichettato come stima quando viene usato: è
più grosso di grana, ed è stato osservato dire `Moderata` mentre la misura
diceva `Pesante`.

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

La barra dei menu mostra il **massimo** fra i sensori `tdie`, mai la media:
è il punto più caldo a decidere quando il sistema limita. La media sta nel
grafico, dove risponde a un'altra domanda — se scalda tutto il SoC o un
punto solo.

**Costo, misurato** (`Watt --bench` su M2 Air): tutti e 35 i sensori 52 ms,
i soli 16 del die 19 ms, la lettura adattiva 6 ms. L'adattiva legge a ogni
giro i quattro sensori più caldi conosciuti, rilegge il die intero ogni dieci
giri, e lo rilegge **subito** ogni volta che l'insieme caldo si muove di più
di 2 °C — soglia scelta sopra il rumore del sensore, che lo stesso benchmark
misura in circa 0,5 °C fra due letture complete consecutive.

Di quello schema sono stati corretti due artefatti, trovati entrambi
guardando quanti sensori entrano in ciascun giro con `Watt --watch-temps`:

- la **media** veniva calcolata su qualunque sensore fosse stato letto in
  quel giro: 4 sensori caldi del die nei giri veloci, 16 del die più
  batteria e SSD in quelli completi. La media saltava di 6 °C ogni dieci
  giri — un dente di sega perfetto, che si legge come throttling
  intermittente e non lo è. Adesso massimo e media stanno su tutta la
  popolazione del die, con l'ultimo valore noto per i sensori non riletti;
- il **massimo** era il massimo di quattro sensori in nove giri su dieci. Se
  il carico si spostava su un cluster fuori dall'insieme caldo, il picco in
  barra era sottostimato fino a venti secondi — cioè proprio quando qualcuno
  lo sta guardando. La rilettura innescata dal movimento chiude quella
  finestra.

### Quanto costa l'app

Misurato su M2 Air a menu chiuso, campionando il processo:

| cosa c'è in barra | cadenza | costo |
|:--|:--|:--|
| frequenza + picco | 2 s | 1,9% di un core |
| solo picco | 2 s | 1,2% |
| un valore che cambia di rado | 10 s | 0,4% |

Il campionamento vero e proprio è quello 0,4%. Tutto il resto è AppKit che
ridisegna l'elemento in barra ogni volta che il testo cambia — nel profilo
del processo è `NSStatusItem _updateReplicants`, due terzi del totale. Da
cui: rallentare la cadenza aiuta molto meno di quanto sembri, e scegliere una
grandezza che cambia di rado aiuta molto di più. Il menu della cadenza
scriveva una percentuale per ciascuna opzione, ricavata dai soli tempi di
lettura dei sensori: erano numeri sbagliati e sono stati tolti invece che
corretti — un numero misurato male è peggio di nessun numero.

---

## 🔋 Batteria

Tutto quello che mostra coconutBattery, letto da dove lo legge lui — il nodo
`AppleSmartBattery` del registro IO, senza privilegi — più due cose che lui
non mostra e che qui hanno senso.

| | |
|:--|:--|
| Salute | capacità a piena carica ÷ capacità di progetto, in mAh |
| «Capacità massima» di macOS | capacità *nominale* ÷ progetto, troncata |
| Cicli | contati e di progetto |
| Elettrico | tensione del pacco, corrente, watt in entrata o uscita |
| Alimentatore | modello, watt negoziati, volt × ampere, seriale |
| Sistema dalla presa | quanto assorbe **tutto il Mac**, in watt |
| Perdita alimentatore | quanto si brucia nell'alimentatore |
| Pacco | modello del gas gauge, fabbricante e lotto delle celle, firmware |

**Due percentuali di salute, entrambe giuste.** Watt dice 80,3% e
Impostazioni di Sistema dice 82%, e non mente nessuno dei due: il numero di
coconutBattery è `FullChargeCapacity ÷ DesignCapacity` (4626 ÷ 5760), quello
di Apple parte da `NominalChargeCapacity` — la stima filtrata dal gas gauge —
e tronca invece di arrotondare (4770 ÷ 5760 = 82,8% → 82%). Mostrarne uno e
nascondere l'altro lascia davanti a due numeri discordi senza spiegazione,
quindi Watt li mostra tutt'e due e li etichetta.

**La potenza dalla presa** viene da `PowerTelemetryData` ed è una grandezza
diversa dai watt del package di `powermetrics`: quelli sono il SoC, questi
sono la macchina intera, schermo compreso. Sono etichettati separatamente per
questo.

**Il degrado nel tempo** sta su disco, in JSON leggibile, in
`~/Library/Application Support/Watt/battery-history.json`: un punto ogni sei
ore, più uno ogni volta che il contatore dei cicli avanza. È l'unica cosa che
Watt scrive oltre alle preferenze, perché è l'unica grandezza il cui senso
sta proprio nel muoversi lentamente.

Il grafico si rifiuta di disegnare una curva prima di avere una settimana di
storico, e la «perdita misurata» media i primi e gli ultimi punti invece di
prendere due letture isolate. Servono entrambi i freni perché il gas gauge
ristima di continuo la capacità a piena carica: in ventiquattro minuti di
prova ha oscillato di 76 mAh — un punto e mezzo di «salute», avanti e
indietro. Una versione precedente annotava un punto a ogni variazione e
disegnava quel tremolio come se fosse invecchiamento. Venti minuti di rumore
che sembrano un anno di usura sono peggio di nessun grafico.

Niente viene dedotto da bit non documentati. Quando il Mac è collegato e non
carica, Watt scrive «collegato, non in carica» e stampa il codice grezzo di
`NotChargingReason`; non indovina «carica ottimizzata» da una configurazione
di bit che nessuno ha documentato.

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
Watt --diagnose                # cosa sta limitando la macchina adesso
Watt --explain                 # come sopra, in parole semplici
Watt --temps                   # tutti i sensori, dal più caldo
Watt --battery                 # salute, cicli, alimentatore, presa
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

### Rilasciare

```bash
./scripts/release.sh --check     # verifica i prerequisiti e si ferma
./scripts/release.sh --app-only  # notarizza e mette la graffetta sulla .app
./scripts/release.sh             # …più un DMG notarizzato e graffettato
```

Compila, firma con Developer ID, notarizza tramite App Store Connect, applica
la graffetta, impacchetta in un DMG, notarizza e graffetta anche quello, poi
verifica il risultato con `spctl` — che è il giudizio di Gatekeeper, l'unico
che conta: una firma può essere perfettamente valida, passare
`codesign --verify`, ed essere comunque bloccata perché non è mai stata
notarizzata.

Le credenziali non entrano mai nel repository. A `notarytool` viene passata
una chiave API di App Store Connect letta da
`~/.secrets/appstoreconnect-api.env`, il che evita di far transitare del tutto
una password dall'ambiente.

Due cose che fanno fallire la notarizzazione in silenzio, e che qui sono
gestite:

- **la marca temporale sicura.** Apple rifiuta qualunque firma che non ne
  abbia una, con un errore che non nomina mai la marca temporale. `build.sh`
  non la mette per impostazione predefinita — renderebbe impossibile una build
  offline — quindi `release.sh` la accende con `WATT_TIMESTAMP=1`;
- **il certificato.** `build.sh` ripiega su *Apple Development* quando non
  trova un Developer ID, e l'app che ne esce gira benissimo sulla macchina che
  l'ha compilata e su nessun'altra. Apple non la notarizza. `release.sh` si
  rifiuta di partire invece di scoprirlo dopo il caricamento.

**Una build `WATT_UNSIGNED=1` non va distribuita mai.** La firma ad-hoc
imposta `skipClientVerification`, che disattiva il controllo di codesign che
l'helper fa sui propri client XPC — cioè un demone root che accetta qualunque
chiamante. Esiste perché il progetto compili senza certificato, nient'altro.

### Perché non il Mac App Store

Lì il sandbox è obbligatorio, e Watt ha bisogno di due cose che il sandbox
vieta: un LaunchDaemon che gira come root (per `pmset`, `mdutil`, `tmutil`,
`taskpolicy`, `purge`, `powermetrics` e il SIGSTOP ai servizi differibili) e
diciassette simboli risolti a runtime che non sono dichiarati in header
pubblici — `IOHIDEventSystemClient*` per le temperature, `IOReport*` per le
frequenze. Togliendoli resta batteria e memoria: un'altra app, e senza niente
di particolare da dire. Tutti gli strumenti di questa categoria si
distribuiscono così, per lo stesso motivo.

### Diagnostica

```bash
./scripts/thermal-curve.sh [campioni] [intervallo]  # misura il throttling
Watt --bench                                        # costo di un giro
Watt --load 8 60                                    # carico a QoS alta
Watt --verify-freq 5                                # IOReport vs powermetrics
Watt --verify-pressure 10                           # kernel vs powermetrics
Watt --watch-temps 40                               # sensori letti per giro
Watt --debug-freq                                   # la frequenza, stato per stato
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

## Licenza e attribuzione

Rilasciato con **licenza MIT** — vedi [LICENSE](LICENSE). GitHub riconosce il
repository come MIT, quindi valgono i termini standard: usalo, modificalo,
distribuiscilo anche commercialmente, senza obblighi oltre a conservare la nota
di copyright e il testo della licenza nelle copie o nelle porzioni sostanziali.

Se ci costruisci sopra qualcosa, un rimando a
[github.com/andreapianidev/watt](https://github.com/andreapianidev/watt) è
gradito ma non richiesto.

Di [Andrea Piani](https://andreapiani.com).

<div align="center">
<sub>

© 2026 Watt · Andrea Piani · NIE 02915190306-Z · El Paso, Santa Cruz de Tenerife · Islas Canarias

</sub>
</div>
