import Foundation
import WattKit

// Demone privilegiato di Watt. Avviato da launchd su richiesta tramite il
// Mach service dichiarato in Contents/Library/LaunchDaemons.

setvbuf(stdout, nil, _IOLBF, 0)

// `watt-helper --parse <file.plist>` stampa come viene interpretato un
// output di powermetrics gia' catturato. Serve a verificare il parser su
// hardware e versioni di macOS diverse da quelli di sviluppo, senza dover
// installare l'helper ne' avere i privilegi di root.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--parse" {
    let path = CommandLine.arguments[2]
    guard let data = FileManager.default.contents(atPath: path) else {
        FileHandle.standardError.write(Data("file illeggibile: \(path)\n".utf8))
        exit(1)
    }
    let sample = PowerMetricsSampler.parsePlist(data)
        ?? PowerMetricsSampler.parseText(String(decoding: data, as: UTF8.self))
    print("P-core        : \(sample.pCoreSummary ?? "n/d")")
    print("E-core        : \(sample.eCoreGHzText ?? "n/d")"
        + " (tetto \(sample.eCoreCeilingMHz.map { String(format: "%.0f MHz", $0) } ?? "n/d"))")
    print("Inattivita' P : "
        + (sample.pCoreIdleRatio.map { String(format: "%.1f%%", $0 * 100) } ?? "n/d"))
    print("Pacchetto     : \(sample.packageWattsText ?? "n/d")")
    print("Termico       : \(sample.thermalPressure.label)"
        + " (throttling: \(sample.thermalPressure.isThrottling ? "si" : "no"))")
    print("Quota tetto   : "
        + (sample.pCoreCeilingFraction.map { String(format: "%.0f%%", $0 * 100) } ?? "n/d"))
    exit(0)
}

NSLog("[Watt] helper %@ avviato", WattHelperVersion.current)

/// Uscita per inattivita': launchd rilancia il demone alla prima connessione
/// successiva. Un demone root che resta residente senza motivo e' superficie
/// d'attacco gratuita.
final class IdleExit {
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "dev.andreapiani.watt.helper.idle")
    private var work: DispatchWorkItem?

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    func touch() {
        queue.async {
            self.work?.cancel()
            let item = DispatchWorkItem {
                NSLog("[Watt] helper inattivo, esco")
                exit(0)
            }
            self.work = item
            self.queue.asyncAfter(deadline: .now() + self.timeout, execute: item)
        }
    }
}

let idle = IdleExit(timeout: 180)
let service = HelperService(onActivity: { idle.touch() })
let delegate = HelperListenerDelegate(service: service)

let listener = NSXPCListener(machServiceName: WattIdentifiers.helperMachService)
listener.delegate = delegate
listener.resume()

idle.touch()
RunLoop.main.run()
