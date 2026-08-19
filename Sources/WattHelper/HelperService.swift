import Foundation
import WattKit

/// Implementazione delle chiamate XPC. Un'unica coda seriale serializza
/// tutte le mutazioni: due profili applicati in parallelo si
/// sovrascriverebbero a meta' strada, lasciando il sistema in uno stato misto.
final class HelperService: NSObject, WattHelperProtocol {

    private let queue = DispatchQueue(label: "dev.andreapiani.watt.helper.work")

    /// Coda dedicata e **seriale** per il campionamento.
    ///
    /// `powermetrics` viene lanciato sia dall'app in barra dei menu sia da
    /// eventuali invocazioni da riga di comando. Servendole su una coda
    /// concorrente, ogni chiamata bloccava un thread in attesa del processo
    /// piu' due per la lettura dei pipe: bastavano poche richieste
    /// sovrapposte a esaurire il pool di GCD, e le letture non venivano piu'
    /// schedulate. Il risultato era un `powermetrics` che sembrava non
    /// terminare mai e restituiva zero byte.
    private let samplerQueue = DispatchQueue(label: "dev.andreapiani.watt.helper.sampler")

    /// Ultimo campione, condiviso fra chiamanti ravvicinati.
    private var cachedSample: (sample: PowerSample, takenAt: Date)?
    /// Sotto questa eta' il campione precedente viene riusato: due client che
    /// chiedono i consumi nello stesso istante non hanno motivo di far girare
    /// `powermetrics` due volte, e ogni esecuzione consuma a sua volta.
    private let cacheLifetime: TimeInterval = 2

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
        // Coda propria, separata da quella dei profili: un campione dura
        // mezzo secondo e non deve ritardare l'applicazione di un profilo
        // scelto nel frattempo. Ma seriale, mai concorrente.
        samplerQueue.async {
            let sample: PowerSample
            if let cached = self.cachedSample,
               Date().timeIntervalSince(cached.takenAt) < self.cacheLifetime {
                sample = cached.sample
            } else {
                sample = PowerMetricsSampler.sample()
                self.cachedSample = (sample, Date())
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            reply(try? encoder.encode(sample))
        }
    }

    func throttleHeavyBackground(protectedPIDs: [NSNumber],
                                 reply: @escaping (Data?) -> Void) {
        activity()
        queue.async {
            let protectedSet = Set(protectedPIDs.map { $0.int32Value })
            let report = SmartThrottle.throttleHeavyBackground(
                protectedPIDs: protectedSet)
            NSLog("[Watt] rallentati %d processi", report.throttled.count)
            reply(try? JSONEncoder().encode(report))
        }
    }

    func restoreThrottled(reply: @escaping (String?) -> Void) {
        activity()
        queue.async { reply(SmartThrottle.restoreThrottled()) }
    }

    func processSnapshot(reply: @escaping (Data?) -> Void) {
        activity()
        samplerQueue.async {
            let table = ProcessTable.sample()
            // Due classifiche unite: i piu' esosi di CPU e i piu' ingombranti
            // di memoria. Filtrando solo per CPU, un processo che occupa
            // gigabyte stando fermo — cioe' proprio quello da chiudere quando
            // il Mac swappa — non comparirebbe mai.
            let byCPU = table.filter { $0.cpuPercent >= 1 }
                .sorted { $0.cpuPercent > $1.cpuPercent }.prefix(25)
            let byMemory = table.sorted { $0.memoryMB > $1.memoryMB }.prefix(15)

            var seen = Set<Int32>()
            let entries = (byCPU + byMemory)
                .filter { seen.insert($0.pid).inserted }
                .map { entry in
                    ProcessSnapshot.Entry(
                        name: ProcessTable.displayName(for: entry.pid,
                                                       fallback: entry.name),
                        pid: entry.pid,
                        cpuPercent: entry.cpuPercent,
                        memoryMB: entry.memoryMB)
                }
            reply(try? JSONEncoder().encode(ProcessSnapshot(entries: entries)))
        }
    }

    func suspendServices(reply: @escaping (Data?) -> Void) {
        activity()
        queue.async {
            let report = ServiceSuspender.suspend()
            reply(Self.encode(report))
        }
    }

    func resumeServices(reply: @escaping (Data?) -> Void) {
        activity()
        queue.async {
            let report = ServiceSuspender.resume()
            reply(Self.encode(report))
        }
    }

    private static func encode(_ report: SuspensionReport) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(report)
    }

    func purgeMemory(reply: @escaping (String?) -> Void) {
        activity()
        queue.async {
            var report = ProfileApplier.Report()
            ProfileApplier.purgeMemory(&report)
            reply(report.summary)
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

        connection.exportedInterface = makeWattHelperInterface()
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
