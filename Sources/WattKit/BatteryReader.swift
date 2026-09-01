import Foundation
import IOKit
import IOKit.ps

/// Tutto quello che il Mac sa della propria batteria.
///
/// La fonte e' `AppleSmartBattery` nel registro IO, cioe' la stessa da cui
/// leggono coconutBattery, `system_profiler SPPowerDataType` e il pannello
/// Batteria di Impostazioni di Sistema. Non richiede privilegi: e' un nodo
/// del registro leggibile da qualunque processo utente, quindi resta
/// nell'app e funziona anche senza helper.
///
/// Le unita' sono quelle native del gas gauge: **mAh** per le capacita',
/// **mV** per le tensioni, **mA** per le correnti. Non vengono convertite
/// alla lettura: convertirle qui vorrebbe dire perdere l'unita' in cui il
/// dato e' stato misurato, e riconvertirle piu' avanti per un confronto
/// significa introdurre un errore che nessuno sa piu' da dove venga.
public struct BatterySnapshot: Codable, Sendable {

    // MARK: - Capacita'

    /// Capacita' di progetto, in mAh. Non cambia mai.
    public var designCapacityMAh: Int?
    /// Capacita' a piena carica **misurata adesso**, in mAh. E' il numero
    /// che scende invecchiando, ed e' quello su cui coconutBattery calcola
    /// la salute.
    public var fullChargeCapacityMAh: Int?
    /// Capacita' nominale: la stessa grandezza, filtrata dal gas gauge.
    ///
    /// E' il numero che Apple usa per la "Capacita' massima" mostrata in
    /// Impostazioni di Sistema, ed e' sistematicamente un paio di punti piu'
    /// alto di quello grezzo. Mostrarli entrambi e' l'unico modo di
    /// rispondere a "perche' Watt dice 80 e il Mac dice 82".
    public var nominalChargeCapacityMAh: Int?
    /// Carica residua, in mAh.
    public var remainingCapacityMAh: Int?
    /// Percentuale di carica cosi' come la mostra il sistema.
    public var chargePercent: Int?

    // MARK: - Usura

    public var cycleCount: Int?
    /// Cicli per cui la batteria e' progettata: 1000 su tutti gli Apple
    /// Silicon portatili.
    public var designCycleCount: Int?
    /// Giudizio del sistema: "Normal", "Service Recommended"…
    public var condition: String?

    // MARK: - Elettrico

    public var voltageMV: Int?
    /// Corrente istantanea in mA: **positiva in carica**, negativa in
    /// scarica. Il registro la espone come intero con segno; lo zero e'
    /// normale con l'alimentatore collegato e la batteria ferma.
    public var amperageMA: Int?
    public var instantAmperageMA: Int?

    // MARK: - Stato

    public var isCharging: Bool?
    public var isFullyCharged: Bool?
    public var externalConnected: Bool?
    public var batteryInstalled: Bool?
    /// Codice grezzo del motivo per cui non sta caricando pur essendo
    /// collegata. I singoli bit non sono documentati e qui **non** vengono
    /// interpretati: indovinarne il significato per scrivere "carica
    /// ottimizzata" sarebbe un'affermazione senza misura dietro. Lo stato
    /// mostrato all'utente si deduce solo da fatti osservabili.
    public var notChargingReason: Int?
    public var chargingThermallyLimitedSeconds: Int?

    /// Minuti alla scarica completa, dal framework IOPowerSources.
    ///
    /// Non si legge da `AvgTimeToEmpty` del registro: quel campo vale 65535
    /// ("sconosciuto") ogni volta che l'alimentatore e' collegato, e in
    /// scarica riporta stime a tre cifre di ore quando il consumo e'
    /// bassissimo. IOPowerSources espone la stima che usa il sistema.
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?

    // MARK: - Identita'

    public var serial: String?
    public var deviceName: String?
    /// Sigla del fabbricante delle celle, come "COS", "SWD", "SMP", "ATL".
    public var cellVendorCode: String?
    /// Codice di lotto delle celle, cosi' com'e' scritto nel pacco.
    public var cellLotCode: String?
    public var firmwareVersion: String?
    public var hardwareRevision: String?
    public var cellRevision: String?
    /// Numero di celle in serie, dedotto dalla struttura del pacco nel
    /// registro (un `AppleSmartBatteryBank` per gruppo in serie).
    public var seriesCells: Int?

    // MARK: - Alimentatore

    public var adapterName: String?
    public var adapterWatts: Int?
    public var adapterManufacturer: String?
    public var adapterSerial: String?
    public var adapterVoltageMV: Int?
    public var adapterCurrentMA: Int?
    public var adapterDescription: String?

    // MARK: - Telemetria di sistema

    /// Potenza che entra nel Mac dall'alimentatore, in mW.
    ///
    /// Viene da `PowerTelemetryData` ed e' una misura del **sistema
    /// intero** — schermo compreso — mentre i watt di `powermetrics` sono
    /// quelli del solo SoC. Sono due grandezze diverse e vanno mostrate
    /// come tali: confonderle fa sembrare che l'app si contraddica.
    public var systemPowerInMW: Int?
    public var systemVoltageInMV: Int?
    public var systemCurrentInMA: Int?
    /// Quanto si perde nell'alimentatore, in mW. E' la differenza fra quello
    /// che esce dal muro e quello che arriva al Mac.
    public var adapterEfficiencyLossMW: Int?
    /// Potenza che la batteria sta erogando (o assorbendo), in mW.
    public var batteryPowerMW: Int?

    public var sampledAt: Date = Date()

    public init() {}

    // MARK: - Grandezze derivate

    /// Salute come la calcola coconutBattery: capacita' a piena carica sulla
    /// capacita' di progetto.
    public var healthPercent: Double? {
        guard let full = fullChargeCapacityMAh, let design = designCapacityMAh,
              design > 0 else { return nil }
        return Double(full) / Double(design) * 100
    }

    /// La stessa salute come la mostra Impostazioni di Sistema.
    ///
    /// Apple parte dalla capacita' *nominale* invece che da quella grezza e
    /// **tronca** invece di arrotondare: su questa macchina 4771/5760 fa
    /// 82,8%, e il Mac scrive 82%. La differenza con il numero di
    /// coconutBattery (80%) non e' un errore di nessuno dei due: sono due
    /// campi diversi del gas gauge.
    public var applePercent: Int? {
        guard let nominal = nominalChargeCapacityMAh,
              let design = designCapacityMAh, design > 0 else { return nil }
        return Int(Double(nominal) / Double(design) * 100)
    }

    /// Quota di cicli consumata rispetto a quelli di progetto.
    public var cycleFraction: Double? {
        guard let cycles = cycleCount, let design = designCycleCount,
              design > 0 else { return nil }
        return Double(cycles) / Double(design)
    }

    /// Tensione nominale del pacco, in volt.
    ///
    /// Il registro non la espone: si ricava dal numero di celle in serie a
    /// 3,85 V l'una, che e' la nominale standard delle celle agli ioni di
    /// litio Apple. Su questa macchina da' 11,55 V, e 5760 mAh × 11,55 V =
    /// 66,5 Wh — esattamente il dato di targa del MacBook Air 15" M2. Resta
    /// comunque una **derivazione**, non una lettura: le energie in
    /// wattora che ne discendono vanno mostrate come approssimate.
    public var nominalPackVolts: Double? {
        guard let series = seriesCells ?? impliedSeriesCells else { return nil }
        return Double(series) * 3.85
    }

    /// Ripiego quando la struttura del pacco non e' leggibile: il numero di
    /// celle in serie si deduce dalla tensione attuale, che per una cella
    /// agli ioni di litio sta sempre fra 3,0 e 4,4 V.
    private var impliedSeriesCells: Int? {
        guard let mv = voltageMV, mv > 0 else { return nil }
        return max(1, Int((Double(mv) / 1000 / 3.85).rounded()))
    }

    public func wattHours(_ mAh: Int?) -> Double? {
        guard let mAh, let volts = nominalPackVolts else { return nil }
        return Double(mAh) * volts / 1000
    }

    public var designWattHours: Double? { wattHours(designCapacityMAh) }
    public var fullChargeWattHours: Double? { wattHours(fullChargeCapacityMAh) }
    public var remainingWattHours: Double? { wattHours(remainingCapacityMAh) }

    /// Potenza che sta attraversando la batteria, in watt: positiva in
    /// carica, negativa in scarica.
    ///
    /// Si preferisce `batteryPowerMW`, che il sistema misura direttamente,
    /// e si ripiega sul prodotto tensione × corrente quando manca.
    public var batteryWatts: Double? {
        if let mw = batteryPowerMW, mw != 0 { return Double(mw) / 1000 }
        guard let mv = voltageMV, let ma = amperageMA ?? instantAmperageMA,
              ma != 0 else { return nil }
        return Double(mv) * Double(ma) / 1_000_000
    }

    /// Potenza assorbita dal Mac intero, in watt.
    public var systemWatts: Double? {
        guard let mw = systemPowerInMW, mw > 0 else { return nil }
        return Double(mw) / 1000
    }

    /// Stato leggibile, dedotto **solo** da fatti osservabili.
    ///
    /// Il registro espone anche `NotChargingReason`, ma i suoi bit non sono
    /// documentati: scrivere "carica ottimizzata" decodificandoli a naso
    /// sarebbe esattamente il tipo di affermazione senza misura che questa
    /// app cerca di non fare. Quando il Mac e' collegato e non carica, si
    /// dice che non carica, e il codice grezzo resta consultabile.
    public var stateLabel: String {
        guard batteryInstalled != false else { return L("no battery") }
        if isCharging == true { return L("charging") }
        if externalConnected == true {
            if isFullyCharged == true { return L("fully charged") }
            return L("plugged in, not charging")
        }
        return L("on battery")
    }

    /// Autonomia o tempo alla carica completa, gia' formattato.
    public var timeRemainingText: String? {
        let minutes = isCharging == true ? minutesToFull : minutesToEmpty
        guard let minutes, minutes > 0 else { return nil }
        return minutes >= 60
            ? String(format: "%dh %02dm", minutes / 60, minutes % 60)
            : L("%d min", minutes)
    }
}

/// Lettura del nodo `AppleSmartBattery`.
public enum BatteryReader {

    public static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }

        var snapshot = BatterySnapshot()

        // `BatteryData` e' il sottodizionario degli Apple Silicon; sui Mac
        // Intel le stesse grandezze stanno in cima. Si guarda prima dentro e
        // poi fuori, cosi' un solo percorso di lettura copre entrambi.
        let data = properties["BatteryData"] as? [String: Any] ?? [:]
        func capacity(_ key: String) -> Int? {
            (data[key] as? NSNumber)?.intValue
                ?? (properties[key] as? NSNumber)?.intValue
        }

        snapshot.designCapacityMAh = capacity("DesignCapacity")
        snapshot.fullChargeCapacityMAh = capacity("FullChargeCapacity")
            ?? capacity("AppleRawMaxCapacity")
        snapshot.nominalChargeCapacityMAh = capacity("NominalChargeCapacity")
        snapshot.remainingCapacityMAh = capacity("RemainingCapacity")
            ?? capacity("AppleRawCurrentCapacity")

        // `CurrentCapacity` e' ambiguo: nel sottodizionario e' la
        // percentuale, in cima ai Mac Intel sono mAh. Si prende la
        // percentuale solo dal posto in cui e' certo che sia tale.
        snapshot.chargePercent = (properties["CurrentCapacity"] as? NSNumber)?.intValue

        snapshot.cycleCount = (properties["CycleCount"] as? NSNumber)?.intValue
        snapshot.designCycleCount =
            (properties["DesignCycleCount9C"] as? NSNumber)?.intValue
            ?? (properties["DesignCycleCount"] as? NSNumber)?.intValue

        snapshot.voltageMV = (properties["Voltage"] as? NSNumber)?.intValue
            ?? (properties["AppleRawBatteryVoltage"] as? NSNumber)?.intValue
        snapshot.amperageMA = (properties["Amperage"] as? NSNumber)?.intValue
        snapshot.instantAmperageMA =
            (properties["InstantAmperage"] as? NSNumber)?.intValue

        snapshot.isCharging = properties["IsCharging"] as? Bool
        snapshot.isFullyCharged = properties["FullyCharged"] as? Bool
        snapshot.externalConnected = properties["ExternalConnected"] as? Bool
        snapshot.batteryInstalled = properties["BatteryInstalled"] as? Bool
        snapshot.serial = properties["Serial"] as? String
        snapshot.deviceName = properties["DeviceName"] as? String

        if let charger = properties["ChargerData"] as? [String: Any] {
            snapshot.notChargingReason =
                (charger["NotChargingReason"] as? NSNumber)?.intValue
            snapshot.chargingThermallyLimitedSeconds =
                (charger["TimeChargingThermallyLimited"] as? NSNumber)?.intValue
        }

        if let adapter = properties["AdapterDetails"] as? [String: Any] {
            snapshot.adapterName = (adapter["Name"] as? String)?
                .trimmingCharacters(in: .whitespaces)
            snapshot.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
            snapshot.adapterManufacturer = adapter["Manufacturer"] as? String
            snapshot.adapterSerial = adapter["SerialString"] as? String
            snapshot.adapterVoltageMV =
                (adapter["AdapterVoltage"] as? NSNumber)?.intValue
            snapshot.adapterCurrentMA = (adapter["Current"] as? NSNumber)?.intValue
            snapshot.adapterDescription = adapter["Description"] as? String
        }

        if let telemetry = properties["PowerTelemetryData"] as? [String: Any] {
            func value(_ key: String) -> Int? {
                (telemetry[key] as? NSNumber)?.intValue
            }
            snapshot.systemPowerInMW = value("SystemPowerIn")
            snapshot.systemVoltageInMV = value("SystemVoltageIn")
            snapshot.systemCurrentInMA = value("SystemCurrentIn")
            snapshot.adapterEfficiencyLossMW = value("AdapterEfficiencyLoss")
            snapshot.batteryPowerMW = value("BatteryPower")
        }

        if let blob = properties["ManufacturerData"] as? Data {
            decodeManufacturerData(blob, into: &snapshot)
        }

        snapshot.seriesCells = countSeriesBanks(under: service)
        readPowerSources(into: &snapshot)
        return snapshot
    }

    // MARK: - Struttura del pacco

    /// Conta gli `AppleSmartBatteryBank` figli: un banco per ogni gruppo di
    /// celle in serie.
    ///
    /// Serve solo a ricavare la tensione nominale del pacco, e quindi i
    /// wattora. Dedurla dalla tensione istantanea funziona ma dipende dallo
    /// stato di carica; contare i banchi e' un fatto strutturale.
    private static func countSeriesBanks(under battery: io_service_t) -> Int? {
        var packIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(
            battery, kIOServicePlane, &packIterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(packIterator) }

        while case let pack = IOIteratorNext(packIterator), pack != 0 {
            defer { IOObjectRelease(pack) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(pack, &name)
            guard String(cString: name) == "AppleSmartBatteryPack" else { continue }

            var bankIterator: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(
                pack, kIOServicePlane, &bankIterator) == KERN_SUCCESS
            else { return nil }
            defer { IOObjectRelease(bankIterator) }

            var banks = 0
            while case let bank = IOIteratorNext(bankIterator), bank != 0 {
                defer { IOObjectRelease(bank) }
                var bankName = [CChar](repeating: 0, count: 128)
                IORegistryEntryGetName(bank, &bankName)
                if String(cString: bankName) == "AppleSmartBatteryBank" {
                    banks += 1
                }
            }
            return banks > 0 ? banks : nil
        }
        return nil
    }

    // MARK: - ManufacturerData

    /// Estrae dal blob del pacco le stesse voci che `system_profiler` mostra
    /// sotto "Model Information".
    ///
    /// Struttura verificata confrontando byte per byte con l'output di
    /// `system_profiler SPPowerDataType` sulla stessa macchina: cinque
    /// interi a 16 bit (lotto pacco, lotto PCB, versione firmware, revisione
    /// hardware, revisione celle) seguiti da stringhe con la lunghezza in
    /// testa, l'ultima delle quali e' la sigla del fabbricante delle celle.
    ///
    /// Il formato non e' documentato: se un giorno cambiasse, questa
    /// funzione deve smettere di riempire i campi, non produrre stringhe di
    /// spazzatura. Per questo ogni stringa viene accettata solo se e'
    /// interamente alfanumerica.
    private static func decodeManufacturerData(
        _ blob: Data, into snapshot: inout BatterySnapshot
    ) {
        let bytes = [UInt8](blob)
        guard bytes.count >= 10 else { return }

        // I byte sono nell'ordine in cui `system_profiler` li stampa, non
        // invertiti: firmware 0x0b 0x00 si legge "0b00", che e' esattamente
        // la "Firmware Version" mostrata dal pannello di sistema. Prendere
        // l'ordine sbagliato dava "000b" — una stringa plausibile e falsa,
        // il tipo di errore che senza un riscontro esterno non si scopre.
        func hex16(_ offset: Int) -> String {
            String(format: "%02x%02x", bytes[offset], bytes[offset + 1])
        }
        snapshot.firmwareVersion = hex16(4)
        snapshot.hardwareRevision = hex16(6)
        snapshot.cellRevision = hex16(8)

        // Fra gli interi e le stringhe ci sono byte a zero il cui numero non
        // e' garantito: si salta il riempimento invece di inchiodare
        // l'offset a dodici, che funzionerebbe su questo pacco e su nessun
        // altro.
        var strings: [String] = []
        var index = 10
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        while index < bytes.count {
            let length = Int(bytes[index])
            guard length > 0, length < 32, index + 1 + length <= bytes.count
            else { break }
            let text = String(decoding: bytes[(index + 1)...(index + length)],
                              as: UTF8.self)
            guard text.allSatisfy({ $0.isLetter || $0.isNumber }) else { break }
            strings.append(text)
            index += 1 + length
        }
        // L'ultima e' la sigla del fabbricante, la prima il lotto delle
        // celle. Se ne compare una sola non si sa quale sia: meglio nessuna
        // etichetta che l'etichetta sbagliata.
        if strings.count >= 2 {
            snapshot.cellLotCode = strings.first
            snapshot.cellVendorCode = strings.last
        }
    }

    // MARK: - IOPowerSources

    /// Stime di autonomia e condizione, dal framework che le pubblica.
    private static func readPowerSources(into snapshot: inout BatterySnapshot) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?
                .takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            // macOS scrive una condizione **solo quando c'e' qualcosa da
            // dire**: a batteria sana la chiave non compare affatto. E'
            // anche il modo in cui `system_profiler` arriva a stampare
            // "Condition: Normal", verificato a fianco su questa macchina.
            // Lasciare la riga vuota farebbe sembrare che il dato manchi,
            // quando invece l'assenza *e'* il dato.
            let condition = (description["BatteryHealthCondition"] as? String)
                ?? (description[kIOPSBatteryHealthKey] as? String)
            if let condition, !condition.isEmpty {
                snapshot.condition = condition
            } else if description[kIOPSIsPresentKey] as? Bool == true {
                snapshot.condition = L("Normal")
            }

            // -1 significa "sto ancora calcolando": mostrarlo come tempo
            // rimanente darebbe "-1 min".
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
                snapshot.minutesToEmpty = minutes
            }
            if let minutes = description[kIOPSTimeToFullChargeKey] as? Int,
               minutes > 0 {
                snapshot.minutesToFull = minutes
            }
            if snapshot.chargePercent == nil,
               let percent = description[kIOPSCurrentCapacityKey] as? Int {
                snapshot.chargePercent = percent
            }
            return
        }
    }
}
