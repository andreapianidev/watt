import Foundation
import WattKit

/// Implementazione delle chiamate XPC. Un'unica coda seriale serializza
/// tutte le mutazioni: due profili applicati in parallelo si
/// sovrascriverebbero a meta' strada, lasciando il sistema in uno stato misto.
final class HelperService: NSObject, WattHelperProtocol {

    private let queue = DispatchQueue(label: "dev.andreapiani.watt.helper.work")
    private let activity: () -> Void

    init(onActivity: @escaping () -> Void) {
        self.activity = onActivity
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        activity()
        reply(WattHelperVersion.current)
    }

    func applyProfile(_ profileRaw: String, reply: @escaping (String?) -> Void) {
        activity()
        queue.async {
            guard let profile = PowerProfile(rawValue: profileRaw) else {
                reply("Profilo sconosciuto: \(profileRaw)")
                return
            }
            NSLog("[Watt] applico il profilo %@", profile.title)
            let report = ProfileApplier.apply(profile)
            if let summary = report.summary {
                NSLog("[Watt] profilo %@ con errori: %@", profile.title, summary)
            }
            reply(report.summary)
        }
    }

    func readSystemState(reply: @escaping (Data?) -> Void) {
        activity()
        queue.async {
            let state = SystemReader.currentState()
            reply(try? JSONEncoder().encode(state))
        }
    }

    func sampleMetrics(reply: @escaping (Data?) -> Void) {
        activity()
        // Fuori dalla coda seriale: un campione dura mezzo secondo e non deve
        // ritardare l'applicazione di un profilo scelto nel frattempo.
        DispatchQueue.global(qos: .utility).async {
            let sample = PowerMetricsSampler.sample()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            reply(try? encoder.encode(sample))
        }
    }

    func restoreAndCleanUp(reply: @escaping (String?) -> Void) {
        activity()
        queue.async {
            guard let baseline = BaselineStore.load() else {
                // Nessuna baseline: Watt non ha mai modificato nulla.
                reply(nil)
                return
            }
            var report = ProfileApplier.Report()
            ProfileApplier.restore(baseline, into: &report)
            BaselineStore.clear()
            NSLog("[Watt] ripristino completato")
            reply(report.summary)
        }
    }
}

/// Delegato del listener: e' qui che si decide chi puo' parlare con root.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {

    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            try ClientVerification.validate(
                connection: connection,
                requirement: WattIdentifiers.clientRequirement)
        } catch {
            // Fallire chiuso: una connessione non verificabile viene rifiutata,
            // mai accettata "nel dubbio".
            NSLog("[Watt] connessione rifiutata: %@", String(describing: error))
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: WattHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
