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
        case .nominal:  return "Nominale"
        case .moderate: return "Moderata"
        case .heavy:    return "Pesante"
        case .trapping: return "Critica"
        case .sleeping: return "Sospensione forzata"
        case .unknown:  return "Sconosciuta"
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

    public var symbolName: String {
        switch self {
        case .nominal, .unknown: return "checkmark.circle.fill"
        case .moderate:          return "thermometer.medium"
        case .heavy:             return "thermometer.high"
        case .trapping, .sleeping: return "exclamationmark.triangle.fill"
        }
    }
}

/// Campione di telemetria prodotto dall'helper via `powermetrics`.
///
/// Le unita' sono quelle native del plist di `powermetrics`, verificate su
/// Mac14,15 / macOS 27: `freq_hz` in hertz, le potenze in **milliwatt**
/// (un M2 Air a riposo riporta ~800, cioe' 0,8 W).
public struct PowerSample: Codable, Sendable {
    /// Frequenza media dei P-core **mentre erano attivi**, in MHz.
    ///
    /// `powermetrics` calcola gia' `freq_hz` scorporando l'inattivita': la
    /// somma di `used_ratio` sugli stati DVFM equivale a `1 - idle_ratio`, e
    /// la media pesata su quegli stati restituisce esattamente `freq_hz`.
    /// Dividerla ancora per la quota attiva la gonfierebbe.
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
