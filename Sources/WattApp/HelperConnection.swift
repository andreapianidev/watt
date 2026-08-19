import Foundation
import ServiceManagement
import WattKit

/// Installazione e dialogo con l'helper privilegiato.
@MainActor
final class HelperConnection {

    enum InstallState {
        case installed
        case needsApproval
        case failed(String)

        var isUsable: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    private var connection: NSXPCConnection?

    // MARK: - Installazione

    private var service: SMAppService {
        SMAppService.daemon(plistName: WattIdentifiers.helperPlistName)
    }

    var installState: InstallState {
        switch service.status {
        case .enabled:          return .installed
        case .requiresApproval: return .needsApproval
        case .notRegistered:    return .failed("Helper non registrato.")
        case .notFound:         return .failed("Helper assente dal bundle.")
        @unknown default:       return .failed("Stato helper sconosciuto.")
        }
    }

    /// Registra il demone. macOS chiede all'utente di approvarlo in
    /// Impostazioni di Sistema; finche' non lo fa, lo stato resta
    /// `requiresApproval` e nessuna chiamata XPC andra' a buon fine.
    @discardableResult
    func install() -> InstallState {
        if case .installed = installState { return .installed }
        do {
            try service.register()
        } catch let error as NSError {
            // `kSMErrorAlreadyRegistered`: gia' presente, non e' un errore.
            if error.code == 2 { return installState }
            return .failed(error.localizedDescription)
        }
        return installState
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Ripristina la baseline e deregistra il demone.
    ///
    /// L'ordine conta: se si deregistrasse per primo non ci sarebbe piu'
    /// nessuno a rimettere a posto Spotlight e Time Machine, e il Mac
    /// resterebbe con l'indicizzazione in pausa senza piu' un'interfaccia per
    /// riattivarla.
    func uninstall(completion: @escaping @MainActor @Sendable (String?) -> Void) {
        callHelper(onFailure: { completion($0) }) { proxy in
            proxy.restoreAndCleanUp { @Sendable message in
                Task { @MainActor in
                    self.disconnect()
                    try? self.service.unregister()
                    completion(message)
                }
            }
        }
    }

    // MARK: - XPC

    private func proxy(onFailure: @escaping @MainActor @Sendable (String) -> Void) -> WattHelperProtocol? {
        if connection == nil {
            let newConnection = NSXPCConnection(
                machServiceName: WattIdentifiers.helperMachService,
                options: .privileged)
            newConnection.remoteObjectInterface =
                NSXPCInterface(with: WattHelperProtocol.self)
            newConnection.invalidationHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            newConnection.interruptionHandler = { @Sendable [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            newConnection.resume()
            connection = newConnection
        }

        return connection?.remoteObjectProxyWithErrorHandler { @Sendable error in
            Task { @MainActor in
                self.connection = nil
                onFailure(Self.describe(error))
            }
        } as? WattHelperProtocol
    }

    private func callHelper(onFailure: @escaping @MainActor @Sendable (String) -> Void,
                            _ body: (WattHelperProtocol) -> Void) {
        guard let proxy = proxy(onFailure: onFailure) else {
            onFailure("Helper non raggiungibile.")
            return
        }
        body(proxy)
    }

    private func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    /// Il messaggio di sistema piu' comune e' un criptico "Couldn't
    /// communicate with a helper application": quasi sempre significa che
    /// l'utente non ha ancora approvato il demone.
    private static func describe(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.lowercased().contains("couldn't communicate") {
            return "L'helper non risponde: probabilmente va approvato in "
                 + "Impostazioni di Sistema, in Generali - Elementi login."
        }
        return text
    }

    // MARK: - Chiamate

    func applyProfile(_ profile: PowerProfile,
                      completion: @escaping @MainActor @Sendable (String?) -> Void) {
        callHelper(onFailure: { completion($0) }) { proxy in
            proxy.applyProfile(profile.rawValue) { @Sendable message in
                Task { @MainActor in completion(message) }
            }
        }
    }

    func readSystemState(completion: @escaping @MainActor @Sendable (SystemState?) -> Void) {
        callHelper(onFailure: { _ in completion(nil) }) { proxy in
            proxy.readSystemState { @Sendable data in
                let state = data.flatMap {
                    try? JSONDecoder().decode(SystemState.self, from: $0)
                }
                Task { @MainActor in completion(state) }
            }
        }
    }

    func sampleMetrics(completion: @escaping @MainActor @Sendable (PowerSample?) -> Void) {
        callHelper(onFailure: { _ in completion(nil) }) { proxy in
            proxy.sampleMetrics { @Sendable data in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let sample = data.flatMap {
                    try? decoder.decode(PowerSample.self, from: $0)
                }
                Task { @MainActor in completion(sample) }
            }
        }
    }
}
