import Foundation
import WattKit

/// Storico del degrado della batteria, su disco.
///
/// A differenza delle temperature, che vivono in un buffer circolare in
/// memoria e non interessano piu' dopo pochi minuti, qui la grandezza
/// interessante e' proprio la *lentezza*: la capacita' a piena carica cala di
/// qualche decina di mAh al mese, e un grafico che riparte da zero a ogni
/// riavvio non puo' mostrarlo. Per questo lo storico e' l'unica cosa che Watt
/// scrive sul disco oltre alle preferenze.
///
/// Il file e' JSON leggibile, non un formato binario: e' un dato che riguarda
/// l'hardware dell'utente, e deve poterselo portare via o cancellare senza
/// bisogno dell'app.
@MainActor
final class BatteryHistory {

    struct Entry: Codable, Sendable {
        var at: Date
        var cycleCount: Int?
        /// Capacita' a piena carica in mAh: la curva del degrado.
        var fullChargeMAh: Int?
        /// La versione filtrata dal gas gauge, quella su cui Apple calcola
        /// la percentuale mostrata in Impostazioni di Sistema.
        var nominalMAh: Int?
        var designMAh: Int?
        var chargePercent: Int?
        var temperatureC: Double?

        var healthPercent: Double? {
            guard let full = fullChargeMAh, let design = designMAh, design > 0
            else { return nil }
            return Double(full) / Double(design) * 100
        }
    }

    private(set) var entries: [Entry] = []

    /// Un punto ogni sei ore basta e avanza per una grandezza che si muove
    /// di mesi. Un campione al secondo produrrebbe in un giorno piu' dati di
    /// quanti ne servano in un anno, e nessuna informazione in piu'.
    private static let minimumInterval: TimeInterval = 6 * 3600

    /// Poco piu' di tre anni di punti a cadenza piena. Oltre, i piu' vecchi
    /// cadono: e' comunque piu' della vita utile di una batteria.
    private static let capacity = 5000

    private let url: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
        let folder = (support ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Watt", isDirectory: true)
        url = folder.appendingPathComponent("battery-history.json")
        load()
    }

    /// Annota un punto, se ne vale la pena.
    ///
    /// Due condizioni: è passato abbastanza tempo, **oppure** il contatore
    /// dei cicli è avanzato — che è un evento vero, e il punto in cui
    /// avviene è esattamente quello che si vuole nel grafico.
    ///
    /// La capacità a piena carica **non** è fra le condizioni, per quanto
    /// sia la grandezza che il grafico mostra. Il gas gauge la ristima di
    /// continuo e il valore oscilla di qualche mAh nel giro di minuti:
    /// usandola come innesco si scriveva un punto ogni pochi minuti, e il
    /// grafico del degrado disegnava quel tremolio come se fosse una curva.
    /// Venti minuti di rumore che sembrano un mese di invecchiamento sono
    /// peggio di nessun grafico.
    func record(_ snapshot: BatterySnapshot, temperature: Double?) {
        guard snapshot.batteryInstalled != false,
              snapshot.designCapacityMAh != nil else { return }

        let entry = Entry(at: Date(),
                          cycleCount: snapshot.cycleCount,
                          fullChargeMAh: snapshot.fullChargeCapacityMAh,
                          nominalMAh: snapshot.nominalChargeCapacityMAh,
                          designMAh: snapshot.designCapacityMAh,
                          chargePercent: snapshot.chargePercent,
                          temperatureC: temperature)

        guard let last = entries.last else {
            entries.append(entry)
            save()
            return
        }
        let changed = last.cycleCount != entry.cycleCount
        let elapsed = entry.at.timeIntervalSince(last.at)
        guard changed || elapsed >= Self.minimumInterval else { return }

        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        save()
    }

    // MARK: - Lettura dello storico

    var span: TimeInterval {
        guard let first = entries.first?.at, let last = entries.last?.at
        else { return 0 }
        return last.timeIntervalSince(first)
    }

    /// Giorni di storico prima di poter dire qualcosa sul degrado.
    ///
    /// Una batteria perde circa un punto percentuale ogni venticinque cicli,
    /// cioe' settimane di uso normale. Sotto la settimana il segnale e' piu'
    /// piccolo del tremolio del gas gauge, e riportarlo sarebbe rumore
    /// spacciato per misura.
    private static let minimumDaysForTrend: Double = 7

    /// Quanti punti percentuali di salute si sono persi da quando lo storico
    /// esiste, e in quanti giorni.
    ///
    /// Gli estremi sono **medie** dei primi e degli ultimi punti, non i due
    /// singoli valori: il gas gauge ristima la capacita' a piena carica di
    /// continuo, e prendere due letture isolate significa misurare la
    /// differenza fra due oscillazioni invece che fra due stati.
    var degradation: (points: Double, days: Double, cycles: Int)? {
        let health = entries.compactMap(\.healthPercent)
        guard health.count >= 4, let first = entries.first, let last = entries.last
        else { return nil }
        let days = last.at.timeIntervalSince(first.at) / 86400
        guard days >= Self.minimumDaysForTrend else { return nil }

        let window = max(2, min(5, health.count / 3))
        let start = health.prefix(window).reduce(0, +) / Double(window)
        let end = health.suffix(window).reduce(0, +) / Double(window)
        let cycles = (last.cycleCount ?? 0) - (first.cycleCount ?? 0)
        return (start - end, days, cycles)
    }

    /// `true` quando lo storico copre abbastanza tempo perche' una curva
    /// abbia un significato.
    var isTrendMeaningful: Bool {
        span / 86400 >= Self.minimumDaysForTrend && entries.count >= 4
    }

    /// Stima di quando la salute scendera' sotto l'80%, la soglia oltre la
    /// quale Apple considera la batteria da sostituire.
    ///
    /// È una **estrapolazione lineare** su quanto osservato finora, e il
    /// degrado di una batteria non è lineare: vale come ordine di grandezza,
    /// non come data. Restituisce `nil` finché la pendenza misurata non è
    /// negativa, perché estrapolare da una curva piatta o in salita produce
    /// numeri assurdi con l'aria di essere previsioni.
    var monthsToEightyPercent: Double? {
        guard let degradation, degradation.points > 0,
              let current = entries.last?.healthPercent, current > 80
        else { return nil }
        let perDay = degradation.points / degradation.days
        guard perDay > 0 else { return nil }
        return (current - 80) / perDay / 30.44
    }

    // MARK: - Disco

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let raw = (try? decoder.decode([Entry].self, from: data)) ?? []
        entries = thinned(raw)
        // Il diradamento si scrive subito. Tenerlo solo in memoria vorrebbe
        // dire rifarlo a ogni avvio su un file che non migliora mai, e nel
        // frattempo lasciare sul disco dei punti che questa versione ha gia'
        // deciso di non considerare dati.
        if entries.count != raw.count { save() }
    }

    /// Applica a cio' che e' gia' sul disco la stessa regola con cui oggi si
    /// scrive: un punto ogni sei ore, piu' ogni avanzamento del contatore
    /// dei cicli.
    ///
    /// Serve perche' una versione precedente annotava un punto **anche** a
    /// ogni variazione della capacita' a piena carica, e quella variazione
    /// e' in gran parte tremolio del gas gauge: in ventiquattro minuti di
    /// prova ne aveva scritti sette, con la capacita' che oscillava di 76
    /// mAh — un punto e mezzo di "salute" avanti e indietro. Lasciati li',
    /// quei punti resterebbero per sempre come uno scalino verticale
    /// all'inizio del grafico, e schiaccerebbero la scala di tutto il resto.
    ///
    /// Nessun dato viene perso che non sia gia' rumore: di ogni finestra si
    /// tiene l'ultima lettura, che e' la piu' recente delle stime.
    private func thinned(_ raw: [Entry]) -> [Entry] {
        var result: [Entry] = []
        for entry in raw.sorted(by: { $0.at < $1.at }) {
            guard let last = result.last else {
                result.append(entry)
                continue
            }
            if last.cycleCount != entry.cycleCount
                || entry.at.timeIntervalSince(last.at) >= Self.minimumInterval {
                result.append(entry)
            } else {
                result[result.count - 1] = entry
            }
        }
        return result
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Scrittura atomica: un'app in barra dei menu viene chiusa nel mezzo
        // di qualunque cosa, e un file JSON troncato a meta' e' uno storico
        // perso per sempre — quello e' il dato che non si puo' ricostruire.
        try? data.write(to: url, options: .atomic)
    }
}
