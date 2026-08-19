import Foundation
import WattKit

/// Fotografia delle impostazioni di sistema come erano *prima* che Watt
/// toccasse qualcosa.
///
/// E' il pezzo che rende l'app reversibile. Viene scritta una volta sola,
/// alla prima applicazione di un profilo, e non viene mai sovrascritta: se
/// la si riscrivesse a ogni cambio profilo, dopo il primo passaggio in
/// "Prestazioni" la baseline conterrebbe gia' Spotlight in pausa e
/// "Automatico" non riporterebbe piu' il Mac allo stato di partenza.
struct Baseline: Codable {
    var lowPowerMode: Bool
    var powerNap: Bool
    var sleepDisabled: Bool
    var spotlightIndexing: Bool
    var timeMachineAutomatic: Bool
    var appNapDisabled: Bool
    var capturedAt: Date
}

enum BaselineStore {
    private static let url = URL(fileURLWithPath: WattIdentifiers.baselinePath)

    static func load() -> Baseline? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.watt.decode(Baseline.self, from: data)
    }

    /// Scrive la baseline solo se non esiste gia'. Ritorna quella in vigore.
    @discardableResult
    static func captureIfNeeded(_ make: () -> Baseline) -> Baseline {
        if let existing = load() { return existing }
        let fresh = make()
        persist(fresh)
        return fresh
    }

    static func persist(_ baseline: Baseline) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(baseline) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

extension JSONDecoder {
    static let watt: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
