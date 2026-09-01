import Foundation

/// Pressione termica riportata da `powermetrics` (chiave `thermal_pressure`).
///
/// E' l'unico segnale onesto di throttling. Una frequenza bassa da sola non
/// lo e': a riposo i P-core stanno a ~900 MHz semplicemente perche' non c'e'
/// lavoro, non perche' il sistema li stia limitando.
public enum ThermalPressure: String, Codable, Sendable {
    case nominal   = "Nominal"
    case moderate  = "Moderate"
    case heavy     = "Heavy"
    case trapping  = "Trapping"
    case sleeping  = "Sleeping"
    case unknown   = "Unknown"

    public init(raw: String?) {
        self = ThermalPressure(rawValue: raw ?? "") ?? .unknown
    }

    public var label: String {
        switch self {
        case .nominal:  return L("Nominal")
        case .moderate: return L("Moderate")
        case .heavy:    return L("Heavy")
        case .trapping: return L("Critical")
        case .sleeping: return L("Forced sleep")
        case .unknown:  return L("Unknown")
        }
    }

    /// `true` quando il sistema segnala una qualsiasi pressione termica.
    public var isThrottling: Bool {
        switch self {
        case .nominal, .unknown: return false
        case .moderate, .heavy, .trapping, .sleeping: return true
        }
    }

    /// `true` solo quando la limitazione e' abbastanza grave da valere un
    /// allarme.
    ///
    /// `ProcessInfo` riporta "fair" gia' sotto un carico ordinario, e in quel
    /// momento i core girano ancora quasi al massimo. Accendere l'allarme li'
    /// significherebbe accenderlo quasi sempre, e un avviso sempre acceso non
    /// e' un avviso.
    ///
    /// Serve soprattutto a non confondere l'inattivita' con la limitazione:
    /// a riposo i P-core scendono sotto il gigahertz perche' non c'e' lavoro,
    /// non perche' il sistema li stia frenando.
    public var demandsAttention: Bool {
        switch self {
        case .nominal, .unknown, .moderate: return false
        case .heavy, .trapping, .sleeping:  return true
        }
    }

    /// Traduce `ProcessInfo.thermalState`, che e' API pubblica e non
    /// richiede privilegi ne' processi esterni. E' meno granulare del
    /// `thermal_pressure` di powermetrics ma distingue comunque il caso che
    /// conta: se il sistema sta limitando le prestazioni oppure no.
    public init(processInfoState: ProcessInfo.ThermalState) {
        switch processInfoState {
        case .nominal:  self = .nominal
        case .fair:     self = .moderate
        case .serious:  self = .heavy
        case .critical: self = .trapping
        @unknown default: self = .unknown
        }
    }

    /// Traduce il livello pubblicato dal kernel su
    /// `com.apple.system.thermalpressurelevel`.
    ///
    /// Su macOS `OSThermalPressureLevel` e' un enum senza valori espliciti a
    /// partire da zero: 0…4 nell'ordine nominale, moderata, pesante,
    /// trapping, sleeping. Su iOS la stessa enum e' numerata 0, 10, 20, 30,
    /// 40, 50 e ha un livello "light" in piu': un valore fuori da 0…4 non e'
    /// un livello di questa piattaforma e va trattato come sconosciuto,
    /// **non** ricondotto al piu' vicino. Dire "nominale" davanti a un
    /// numero che non si e' capito e' l'errore che questa app esiste per non
    /// commettere.
    public init?(kernelLevel: UInt64) {
        switch kernelLevel {
        case 0: self = .nominal
        case 1: self = .moderate
        case 2: self = .heavy
        case 3: self = .trapping
        case 4: self = .sleeping
        default: return nil
        }
    }

    public var symbolName: String {
        switch self {
        case .nominal, .unknown: return "checkmark.circle.fill"
        case .moderate:          return "thermometer.medium"
        case .heavy:             return "thermometer.high"
        case .trapping, .sleeping: return "exclamationmark.triangle.fill"
        }
    }
}

/// Da dove viene la pressione termica di un campione.
///
/// Non e' un dettaglio di implementazione: cambia quanto ci si puo' fidare
/// del valore, e quindi cosa l'app ha il diritto di dichiarare. Tenere le
/// fonti indistinguibili era il motivo per cui Watt taceva mentre asitop
/// segnalava, e poi — corretta la prima volta a meta' — il motivo per cui
/// una misura pagata con un powermetrics veniva sovrascritta da una stima.
public enum ThermalPressureSource: String, Codable, Sendable {
    /// `com.apple.system.thermalpressurelevel`, letta dal kernel. E' la
    /// stessa sorgente che legge `powermetrics`, ma senza processi ne'
    /// privilegi, quindi disponibile a ogni giro.
    case kernel
    /// Campo `thermal_pressure` di `powermetrics`, via helper.
    case powermetrics
    /// `ProcessInfo.thermalState`: quattro gradini, e sbaglia di un livello
    /// intero rispetto alla misura. Ripiego, non misura.
    case processInfo
    case unknown

    /// `true` quando il valore e' quello che il sistema usa davvero per
    /// dichiarare la limitazione.
    public var isMeasured: Bool {
        switch self {
        case .kernel, .powermetrics: return true
        case .processInfo, .unknown: return false
        }
    }

    public var label: String {
        switch self {
        case .kernel:       return L("kernel")
        case .powermetrics: return L("powermetrics")
        case .processInfo:  return L("ProcessInfo estimate")
        case .unknown:      return L("unknown")
        }
    }
}

/// Quanto e' grave la situazione termica, ai fini di cosa mostrare.
///
/// Tre gradini invece di due perche' una misura vera di "Moderata" merita di
/// essere detta — asitop la conta gia' come `throttle: yes` — ma non merita
/// il triangolo rosso che si usa per "Pesante". Con una sola soglia si
/// finisce o per allarmare sempre o per tacere quando conta.
public enum ThermalSeverity: Sendable {
    case none, notice, alarm
}

/// Campione di telemetria prodotto dall'helper via `powermetrics`.
///
/// Le unita' sono quelle native del plist di `powermetrics`, verificate su
/// Mac14,15 / macOS 27: `freq_hz` in hertz, le potenze in **milliwatt**
/// (un M2 Air a riposo riporta ~800, cioe' 0,8 W).
public struct PowerSample: Codable, Sendable {
    /// Frequenza media dei P-core, in MHz.
    ///
    /// Attenzione: **non e' la stessa grandezza** a seconda di chi riempie
    /// il campo, e il commento che stava qui sosteneva il contrario.
    ///
    /// - da `IOReportSampler`, che e' la fonte usata dall'app, e' la media
    ///   *mentre i core lavoravano*: gli stati di riposo sono esclusi;
    /// - da `powermetrics`, che e' la fonte usata dall'helper, `freq_hz` e'
    ///   una media sull'intervallo intero.
    ///
    /// A cluster saturo coincidono alla cifra — `--verify-freq` sotto carico
    /// da' scarto nullo su quattro campioni su quattro. A cluster fermo
    /// divergono di centinaia di megahertz, e la vecchia affermazione
    /// ("powermetrics scorpora gia' l'inattivita'") faceva sembrare quella
    /// divergenza un errore di calcolo di Watt.
    ///
    /// Quella che va mostrata e' la prima: e' l'unica in cui una limitazione
    /// termica si distingue dall'assenza di lavoro.
    public var pCoreMHz: Double?
    public var eCoreMHz: Double?
    /// Massimo stato DVFM esposto dal cluster: il tetto reale del silicio.
    public var pCoreCeilingMHz: Double?
    public var eCoreCeilingMHz: Double?
    /// Quota di tempo in cui il cluster P e' rimasto inattivo (0...1).
    public var pCoreIdleRatio: Double?

    public var packageMilliwatts: Double?
    public var cpuMilliwatts: Double?
    public var gpuMilliwatts: Double?
    public var aneMilliwatts: Double?

    public var thermalPressureRaw: String?
    /// `true` quando `thermalPressureRaw` viene da `powermetrics` e non
    /// dalla traduzione di `ProcessInfo.thermalState`.
    ///
    /// I due non sono la stessa cosa. `powermetrics` riporta il campo
    /// `thermal_pressure` che il sistema usa per dichiarare la limitazione —
    /// e' quello, e solo quello, che asitop mostra come "throttle: yes".
    /// `ProcessInfo` ne da' una versione a quattro gradini che segnala
    /// "fair" gia' sotto un carico ordinario. Trattarli allo stesso modo
    /// significa o allarmare sempre o non allarmare mai: distinguerli
    /// permette di credere al primo e restare prudenti col secondo.
    ///
    /// Il campo e' opzionale nella codifica di proposito. La decodifica
    /// sintetizzata di Swift **non** applica i valori predefiniti: una
    /// proprieta' non opzionale aggiunta qui fa fallire la decodifica di
    /// ogni campione prodotto da un helper piu' vecchio, e l'app perde di
    /// colpo watt, frequenze e pressione — tutto, non solo il campo nuovo.
    /// Un helper si aggiorna con `sudo`, l'app no: devono potersi parlare
    /// anche disallineati.
    private var thermalPressureMeasuredRaw: Bool?
    /// Sorgente esplicita, aggiunta dopo il flag booleano. Anche questa e'
    /// opzionale per la stessa ragione: un helper piu' vecchio non la manda,
    /// e la sua assenza non deve far fallire la decodifica dell'intero
    /// campione.
    private var thermalPressureSourceRaw: String?

    public var thermalPressureSource: ThermalPressureSource {
        get {
            if let raw = thermalPressureSourceRaw,
               let source = ThermalPressureSource(rawValue: raw) {
                return source
            }
            // Campione prodotto da un helper che conosce solo il flag:
            // se dice "misurata", l'unica misura che sapeva fare era
            // powermetrics.
            if thermalPressureMeasuredRaw == true { return .powermetrics }
            return thermalPressureRaw == nil ? .unknown : .processInfo
        }
        set {
            thermalPressureSourceRaw = newValue.rawValue
            // Il flag resta scritto per gli *altri* lettori: un binario
            // vecchio che decodifica un campione nuovo continua a capire
            // se fidarsi.
            thermalPressureMeasuredRaw = newValue.isMeasured
        }
    }

    public var thermalPressureMeasured: Bool { thermalPressureSource.isMeasured }
    public var sampledAt: Date

    public init(pCoreMHz: Double? = nil, eCoreMHz: Double? = nil,
                pCoreCeilingMHz: Double? = nil, eCoreCeilingMHz: Double? = nil,
                pCoreIdleRatio: Double? = nil,
                packageMilliwatts: Double? = nil, cpuMilliwatts: Double? = nil,
                gpuMilliwatts: Double? = nil, aneMilliwatts: Double? = nil,
                thermalPressureRaw: String? = nil, sampledAt: Date = Date()) {
        self.pCoreMHz = pCoreMHz
        self.eCoreMHz = eCoreMHz
        self.pCoreCeilingMHz = pCoreCeilingMHz
        self.eCoreCeilingMHz = eCoreCeilingMHz
        self.pCoreIdleRatio = pCoreIdleRatio
        self.packageMilliwatts = packageMilliwatts
        self.cpuMilliwatts = cpuMilliwatts
        self.gpuMilliwatts = gpuMilliwatts
        self.aneMilliwatts = aneMilliwatts
        self.thermalPressureRaw = thermalPressureRaw
        self.sampledAt = sampledAt
    }

    public var thermalPressure: ThermalPressure {
        ThermalPressure(raw: thermalPressureRaw)
    }

    /// `true` quando il sistema sta dichiarando una limitazione termica su
    /// una misura vera, non su una stima.
    ///
    /// E' la condizione in cui asitop scrive "throttle: yes": qualunque
    /// pressione diversa da `Nominal`. A quel punto non e' piu' una
    /// prudenza, e vale la pena dirlo anche a "Moderata".
    public var isThermallyLimited: Bool {
        thermalPressureMeasured && thermalPressure.isThrottling
    }

    /// Cosa mostrare, tenendo conto sia del livello sia di quanto e'
    /// affidabile la fonte.
    ///
    /// Una "Moderata" **misurata** vale un avviso discreto: il sistema sta
    /// gia' limitando qualcosa. La stessa "Moderata" **stimata** da
    /// `ProcessInfo` no: quella compare sotto un carico ordinario, con i
    /// core ancora quasi al tetto, e accendere li' un avviso significa
    /// tenerlo acceso quasi sempre.
    public var thermalSeverity: ThermalSeverity {
        guard thermalPressureMeasured else {
            // Sulla stima si resta al comportamento prudente di prima.
            return thermalPressure.demandsAttention ? .alarm : .none
        }
        switch thermalPressure {
        case .nominal, .unknown:   return .none
        case .moderate:            return .notice
        case .heavy, .trapping, .sleeping: return .alarm
        }
    }

    public var pCoreGHzText: String? {
        format(ghz: pCoreMHz)
    }

    public var eCoreGHzText: String? {
        format(ghz: eCoreMHz)
    }

    private func format(ghz mhz: Double?) -> String? {
        guard let mhz, mhz > 0 else { return nil }
        return String(format: "%.2f GHz", mhz / 1000)
    }

    public var packageWattsText: String? {
        guard let mw = packageMilliwatts, mw > 0 else { return nil }
        return String(format: "%.1f W", mw / 1000)
    }

    /// Frazione del tetto del silicio raggiunta dai P-core quando lavorano.
    ///
    /// Va letta insieme a `thermalPressure`: da sola non distingue "poco
    /// lavoro" da "limitato dal calore".
    public var pCoreCeilingFraction: Double? {
        guard let mhz = pCoreMHz, let ceiling = pCoreCeilingMHz, ceiling > 0
        else { return nil }
        return min(1, mhz / ceiling)
    }

    /// Riga sintetica per la menu bar, es. "1,19 di 3,50 GHz".
    public var pCoreSummary: String? {
        guard let mhz = pCoreMHz else { return nil }
        guard let ceiling = pCoreCeilingMHz, ceiling > 0 else {
            return String(format: "%.2f GHz", mhz / 1000)
        }
        return String(format: "%.2f di %.2f GHz", mhz / 1000, ceiling / 1000)
    }
}

/// Stato effettivo del sistema, letto dall'helper (non dedotto dal profilo
/// selezionato). Serve a mostrare la verita' anche se qualcosa e' stato
/// cambiato fuori dall'app.
public struct SystemState: Codable, Sendable {
    public var lowPowerMode: Bool
    public var powerNap: Bool
    public var sleepDisabled: Bool
    public var spotlightIndexing: Bool
    public var timeMachineAutomatic: Bool
    public var appNapDisabled: Bool
    public var helperVersion: String

    public init(lowPowerMode: Bool = false, powerNap: Bool = false,
                sleepDisabled: Bool = false, spotlightIndexing: Bool = true,
                timeMachineAutomatic: Bool = true, appNapDisabled: Bool = false,
                helperVersion: String = "?") {
        self.lowPowerMode = lowPowerMode
        self.powerNap = powerNap
        self.sleepDisabled = sleepDisabled
        self.spotlightIndexing = spotlightIndexing
        self.timeMachineAutomatic = timeMachineAutomatic
        self.appNapDisabled = appNapDisabled
        self.helperVersion = helperVersion
    }
}
