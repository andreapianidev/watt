import Foundation
import IOKit

/// Legge i sensori di temperatura del Mac.
///
/// Su Apple Silicon i sensori termici non passano piu' dall'SMC come sui Mac
/// Intel: sono esposti come servizi HID nella pagina "Apple Vendor", ed e'
/// da li' che li prendono gli strumenti che mostrano le temperature. Un M2
/// Air ne espone una quarantina.
///
/// Non servono privilegi, quindi la lettura resta nell'app: far passare da
/// un demone root qualcosa che root non lo richiede sarebbe solo superficie
/// d'attacco in piu'.
///
/// Le funzioni non sono dichiarate in header pubblici e si risolvono a
/// runtime: se un aggiornamento di macOS le spostasse, `init?` fallisce e
/// l'app perde le temperature invece di crollare.
public final class ThermalSensors {

    /// Famiglia di appartenenza di un sensore, dedotta dal nome.
    ///
    /// La classificazione avviene una volta sola alla costruzione: farla a
    /// ogni lettura significherebbe ripetere trentanove confronti di stringhe
    /// ogni secondo per un dato che non cambia mai.
    public enum Category: String, Codable, Sendable, CaseIterable {
        case die, power, storage, battery, other

        public var label: String {
            switch self {
            case .die:     return L("SoC")
            case .power:   return L("Power")
            case .storage: return L("Storage")
            case .battery: return L("Battery")
            case .other:   return L("Other")
            }
        }

        public var symbolName: String {
            switch self {
            case .die:     return "cpu"
            case .power:   return "bolt"
            case .storage: return "internaldrive"
            case .battery: return "battery.100"
            case .other:   return "sensor"
            }
        }

        static func infer(from name: String) -> Category {
            let lower = name.lowercased()
            if lower.contains("tdie") { return .die }
            if lower.contains("battery") || lower.contains("gas gauge") { return .battery }
            if lower.contains("nand") || lower.contains("ssd") { return .storage }
            if lower.contains("tdev") || lower.contains("tcal")
                || lower.contains("pmu") { return .power }
            return .other
        }
    }

    public struct Reading: Sendable {
        public var name: String
        public var celsius: Double
        public var category: Category
    }

    public struct Summary: Sendable {
        /// Temperatura del die del SoC: il massimo fra i sensori `tdie`.
        ///
        /// Si prende il massimo e non la media perche' e' il punto piu' caldo
        /// a determinare quando il sistema inizia a limitare le prestazioni.
        public var socCelsius: Double?
        /// Media dei soli sensori sul die: dice se sta scaldando tutto il SoC
        /// o un punto solo.
        public var socAverageCelsius: Double?
        public var batteryCelsius: Double?
        public var storageCelsius: Double?
        public var all: [Reading]

        /// Letture raggruppate per famiglia, ciascun gruppo dal piu' caldo.
        public var byCategory: [(Category, [Reading])] {
            Category.allCases.compactMap { category in
                let group = all.filter { $0.category == category }
                return group.isEmpty ? nil : (category, group)
            }
        }

        public static func format(_ celsius: Double?) -> String {
            guard let celsius else { return "n/d" }
            return String(format: "%.0f °C", celsius)
        }
    }

    // MARK: - Simboli

    private typealias FnCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias FnMatching = @convention(c) (AnyObject?, CFDictionary?) -> Void
    private typealias FnServices = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias FnProperty = @convention(c) (AnyObject?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias FnEvent = @convention(c) (AnyObject?, Int64, Int32, UInt64) -> Unmanaged<AnyObject>?
    private typealias FnFloat = @convention(c) (AnyObject?, UInt32) -> Double

    private let copyProperty: FnProperty
    private let copyEvent: FnEvent
    private let floatValue: FnFloat

    private let client: AnyObject
    /// Elenco dei servizi, risolto una volta sola: enumerarli a ogni lettura
    /// costerebbe piu' della lettura stessa.
    private let services: [AnyObject]
    /// Nome di ciascun servizio, appaiato per indice a `services`.
    private let names: [String]
    private let categories: [Category]
    /// Indici dei sensori che la barra dei menu mostra sempre.
    ///
    /// La barra dei menu ha bisogno solo di questi. Leggere tutti e trentanove
    /// i sensori costa circa 52 ms contro i 17 del sottoinsieme, e a un
    /// aggiornamento al secondo la differenza è fra il 5% e l'1,7% di un core
    /// occupato per sempre: troppo, per un'app che sta in barra dei menu
    /// giorni interi.
    private let dieIndices: [Int]
    private let barIndices: [Int]
    private let slowIndices: [Int]

    /// Stato del campionamento adattivo.
    private var tick = 0
    private var hotIndices: [Int] = []
    private var lastSlow: [Reading] = []

    private static let appleVendorPage: Int64 = 0xff00
    private static let temperatureUsage: Int64 = 5
    private static let temperatureEvent: Int64 = 15
    /// I campi di un evento HID sono indicizzati per tipo: base = tipo << 16.
    private static let temperatureField = UInt32(temperatureEvent << 16)

    // MARK: - Costruzione

    public init?() {
        guard let library = dlopen(
            "/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        else { return nil }

        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard
            let create = symbol("IOHIDEventSystemClientCreate", FnCreate.self),
            let setMatching = symbol("IOHIDEventSystemClientSetMatching", FnMatching.self),
            let copyServices = symbol("IOHIDEventSystemClientCopyServices", FnServices.self),
            let copyProperty = symbol("IOHIDServiceClientCopyProperty", FnProperty.self),
            let copyEvent = symbol("IOHIDServiceClientCopyEvent", FnEvent.self),
            let floatValue = symbol("IOHIDEventGetFloatValue", FnFloat.self),
            let clientRaw = create(kCFAllocatorDefault)
        else { return nil }

        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.floatValue = floatValue
        self.client = clientRaw.takeRetainedValue()

        let filter: [String: Int64] = [
            "PrimaryUsagePage": Self.appleVendorPage,
            "PrimaryUsage": Self.temperatureUsage,
        ]
        setMatching(client, filter as CFDictionary)

        guard let listRaw = copyServices(client),
              let list = listRaw.takeRetainedValue() as? [AnyObject],
              !list.isEmpty
        else { return nil }

        self.services = list
        let resolved = list.map { service in
            (copyProperty(service, "Product" as CFString)?
                .takeRetainedValue() as? String) ?? "?"
        }
        self.names = resolved
        self.categories = resolved.map(Category.infer(from:))
        // Die, batteria e archiviazione: sono le tre righe che il menu mostra
        // sempre. Restano esclusi i sensori di alimentazione e calibrazione,
        // che sono la meta' del totale e che nessuno guarda se non aprendo
        // l'elenco completo.
        self.dieIndices = categories.enumerated()
            .filter { [.die, .battery, .storage].contains($0.element) }
            .map(\.offset)
        self.barIndices = categories.enumerated()
            .filter { $0.element == .die }
            .map(\.offset)
        self.slowIndices = categories.enumerated()
            .filter { [.battery, .storage].contains($0.element) }
            .map(\.offset)
        // Finche' non e' stata fatta la prima scansione completa l'insieme
        // caldo e' tutto il die: meglio pagare un giro pieno che partire
        // mostrando la temperatura sbagliata.
        self.hotIndices = self.barIndices
    }

    // MARK: - Lettura

    /// Legge tutti i sensori. Da usare quando l'elenco completo e' a schermo.
    public func read() -> Summary {
        summary(from: readValues(at: Array(services.indices)))
    }

    /// Legge i soli sensori mostrati di continuo.
    ///
    /// Leggere solo quelli sul die faceva sparire batteria e SSD dal menu: la
    /// lettura veloce sovrascriveva quella completa un secondo dopo averla
    /// fatta, e le due righe tornavano a "n/d" da sole.
    public func readEssential() -> Summary {
        summary(from: readValues(at: dieIndices))
    }

    /// Lettura continua, il piu' economica possibile a parita' di risultato.
    ///
    /// Ogni sensore costa un giro di IPC verso il sistema HID: circa un
    /// millisecondo, e su questo Mac i sensori sono trentacinque. Leggerli
    /// tutti una volta al secondo significa il 5% di un core solo per
    /// guardare un termometro — cioe' un'app che si mangia le prestazioni
    /// che dice di misurare.
    ///
    /// Qui si sfrutta il fatto che i sedici sensori del die non si muovono
    /// in modo indipendente: sono lo stesso pezzo di silicio, e gli otto
    /// piu' caldi stanno in un grado e mezzo l'uno dall'altro. Quindi:
    ///
    /// - a ogni giro si leggono i quattro piu' caldi conosciuti, che sono
    ///   quelli da cui il massimo esce quasi sempre;
    /// - ogni dieci giri si rilegge il die per intero, cosi' se il carico si
    ///   sposta da un cluster all'altro l'insieme caldo si aggiorna;
    /// - batteria e SSD si rileggono ogni trenta giri, perche' cambiano di
    ///   un grado in qualche minuto, e nel frattempo si tiene l'ultimo valore
    ///   invece di far sparire la riga dal menu.
    ///
    /// Il prezzo e' che subito dopo uno spostamento di carico il massimo puo'
    /// essere sottostimato di un grado o due, per meno di dieci secondi.
    public func readAdaptive() -> Summary {
        defer { tick += 1 }

        let fullDie = tick % Self.dieRescanEvery == 0
        let withSlow = tick % Self.slowRescanEvery == 0

        var indices = fullDie ? barIndices : hotIndices
        if withSlow { indices += slowIndices }

        var readings = readValues(at: indices)

        if fullDie {
            // Aggiorna l'insieme caldo con i piu' caldi appena misurati.
            let ranked = readings.filter { $0.category == .die }
                .sorted { $0.celsius > $1.celsius }
            let names = Set(ranked.prefix(Self.hotCount).map(\.name))
            let updated = barIndices.filter { names.contains(self.names[$0]) }
            if !updated.isEmpty { hotIndices = updated }
        }

        // Batteria e SSD: se non sono stati riletti in questo giro, si
        // riusa l'ultima misura invece di lasciare la riga vuota.
        if withSlow {
            lastSlow = readings.filter { $0.category != .die }
        } else {
            readings += lastSlow
        }

        return summary(from: readings)
    }

    private static let hotCount = 4
    private static let dieRescanEvery = 10
    private static let slowRescanEvery = 30

    /// Legge i soli sensori del die: e' tutto cio' che servono la barra dei
    /// menu e il grafico.
    ///
    /// Ogni sensore costa un giro di IPC verso il sistema HID, per cui il
    /// costo e' lineare nel numero di sensori letti. Batteria e SSD cambiano
    /// di un grado in qualche minuto: rileggerli ogni secondo e' spesa senza
    /// informazione.
    public func readBar() -> Summary {
        summary(from: readValues(at: barIndices))
    }

    private func readValues(at indices: [Int]) -> [Reading] {
        var readings: [Reading] = []
        readings.reserveCapacity(indices.count)
        for index in indices {
            guard let eventRaw = copyEvent(
                services[index], Self.temperatureEvent, 0, 0) else { continue }
            let celsius = floatValue(
                eventRaw.takeRetainedValue(), Self.temperatureField)
            // Uno zero non e' una temperatura plausibile per un Mac acceso:
            // e' un sensore che in quel momento non ha un valore.
            guard celsius > 0, celsius < 150 else { continue }
            readings.append(Reading(name: names[index], celsius: celsius,
                                    category: categories[index]))
        }
        return readings
    }

    private func summary(from readings: [Reading]) -> Summary {
        func hottest(_ category: Category) -> Double? {
            readings.filter { $0.category == category }.map(\.celsius).max()
        }
        let die = readings.filter { $0.category == .die }.map(\.celsius)

        return Summary(
            socCelsius: die.max(),
            socAverageCelsius: die.isEmpty
                ? nil : die.reduce(0, +) / Double(die.count),
            batteryCelsius: hottest(.battery),
            storageCelsius: hottest(.storage),
            all: readings.sorted { $0.celsius > $1.celsius })
    }

}
