import Foundation

/// Campionamento periodico, piu' fitto mentre il menu e' aperto.
///
/// Ogni campione fa girare `powermetrics` per mezzo secondo. Tenerlo raro a
/// menu chiuso evita che un'app nata per misurare i consumi diventi essa
/// stessa una voce di consumo.
@MainActor
final class MetricsPoller {

    private var timer: Timer?
    private let action: () -> Void
    private var foreground = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func start() { schedule() }

    /// Da chiamare quando cambia la cadenza scelta dall'utente.
    func restart() { schedule() }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Da chiamare all'apertura e chiusura del menu.
    func setForeground(_ active: Bool) {
        guard foreground != active else { return }
        foreground = active
        if active { action() }
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        // A menu aperto si aggiorna comunque ogni secondo: è il momento in
        // cui l'utente sta guardando i numeri, e mezzo punto di CPU per
        // qualche secondo non è un problema.
        let interval = foreground ? 1 : Preferences.metricsInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.action() }
        }
        // `.common` perche' con il menu aperto il run loop entra in
        // `eventTracking` e un timer di default smetterebbe di scattare
        // proprio quando l'utente sta guardando i numeri.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        action()
    }
}
