import Foundation
import UserNotifications
import WattKit

/// Avvisi di sistema per le condizioni che vale la pena sapere subito.
///
/// Su un Mac senza ventola la temperatura alta non è un guasto: è il normale
/// prezzo di un carico prolungato. L'avviso serve a sapere *quando* smetti di
/// avere le prestazioni per cui credi di stare aspettando, non a spaventare.
/// Per questo ogni allarme si accende e si spegne per conto suo: chi compila
/// tutto il giorno vuole sapere dello swap e non della temperatura, chi monta
/// video il contrario.
@MainActor
final class AlertCenter {

    /// I tipi di allarme, ciascuno con la sua voce nelle impostazioni.
    enum Kind: String, CaseIterable {
        /// Il die ha superato la soglia scelta.
        case temperature
        /// Il sistema ha *iniziato* a limitare le prestazioni.
        case throttling
        /// Il sistema sta scrivendo memoria su disco adesso.
        case swapping

        var settingsLabel: String {
            switch self {
            case .temperature: return L("When it gets hot")
            case .throttling:  return L("When performance starts being limited")
            case .swapping:    return L("When the system starts swapping")
            }
        }

        /// Acceso di suo alla prima installazione.
        ///
        /// La temperatura e la limitazione sì: sono il motivo per cui l'app
        /// esiste. Lo swap no: chi non compila non lo incontra mai, e un
        /// avviso che non riguarda chi lo riceve insegna a ignorare tutti gli
        /// altri.
        var enabledByDefault: Bool { self != .swapping }
    }

    /// Soglie proposte per la temperatura. Un M2 Air in throttling sostenuto
    /// sta stabilmente sopra i 90 °C, quindi soglie più basse produrrebbero
    /// solo rumore.
    static let thresholds: [Double] = [80, 85, 90, 95]

    private var authorized = false
    /// Sopra soglia si resta a lungo: senza una pausa, l'avviso arriverebbe a
    /// ogni campione finché la build non finisce. Una pausa per tipo, così un
    /// allarme non zittisce gli altri.
    private var lastNotified: [Kind: Date] = [:]
    private let quietPeriod: TimeInterval = 10 * 60
    /// Isteresi: si riarma solo dopo essere scesi di qualche grado, altrimenti
    /// oscillare attorno alla soglia genererebbe una raffica di avvisi.
    private let rearmMargin: Double = 4
    private var armed: [Kind: Bool] = [:]

    init() {
        for kind in Kind.allCases { armed[kind] = true }
    }

    func requestAuthorizationIfNeeded() {
        guard Preferences.anyAlertEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// Chiede il permesso adesso perché l'utente ha appena acceso un allarme.
    ///
    /// Senza questo, accendere un allarme a permesso mai chiesto non produce
    /// niente e non lo dice: l'utente resta convinto di essere avvisato.
    func requestAuthorizationNow() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func evaluate(socCelsius: Double?,
                  throttling: Bool,
                  ceilingFraction: Double?,
                  memory: MemoryReader.Snapshot?) {
        evaluateTemperature(socCelsius: socCelsius, throttling: throttling)
        evaluateThrottling(throttling: throttling, fraction: ceilingFraction)
        evaluateSwapping(memory: memory)
    }

    // MARK: - I tre allarmi

    private func evaluateTemperature(socCelsius: Double?, throttling: Bool) {
        guard Preferences.alertEnabled(.temperature), let socCelsius else { return }
        let threshold = Preferences.alertThreshold

        if socCelsius < threshold - rearmMargin { armed[.temperature] = true }
        guard armed[.temperature] == true, socCelsius >= threshold else { return }

        fire(.temperature,
             title: L("SoC at %.0f °C", socCelsius),
             body: throttling
                ? L("The system is limiting performance because of heat. On a "
                  + "fanless Mac there is no way around it: you can only reduce "
                  + "the load or give it a break.")
                : L("Temperature is above your threshold, but performance is not "
                  + "being limited yet."))
    }

    /// Scatta sul *passaggio* a limitato, non sullo stato.
    ///
    /// Quello che interessa sapere è il momento in cui la macchina ha smesso
    /// di andare al massimo. Restare limitati per venti minuti è una notizia
    /// sola, non venti.
    private func evaluateThrottling(throttling: Bool, fraction: Double?) {
        guard Preferences.alertEnabled(.throttling) else { return }
        if !throttling { armed[.throttling] = true; return }
        guard armed[.throttling] == true else { return }

        let measured = fraction.map { String(format: " %.0f%%", $0 * 100) }
        fire(.throttling,
             title: L("The Mac is being limited"),
             body: measured.map {
                L("P-cores are running at%@ of what they could. No power "
                + "profile lifts this: it is heat, and it passes on its own "
                + "when the load drops.", $0)
             } ?? L("The system has started limiting performance."))
    }

    private func evaluateSwapping(memory: MemoryReader.Snapshot?) {
        guard Preferences.alertEnabled(.swapping), let memory else { return }
        if !memory.isSwapping { armed[.swapping] = true; return }
        guard armed[.swapping] == true else { return }

        fire(.swapping,
             title: L("The system is writing memory to disk"),
             body: memory.swapRateText.map {
                L("%@ going to swap. Reading a page back costs orders of "
                + "magnitude more than from RAM, and no power profile changes "
                + "that. Close what you are not using.", $0)
             } ?? L("RAM has run out and the system is falling back to disk."))
    }

    // MARK: - Consegna

    /// Applica pausa e riarmo, poi consegna. Ogni allarme passa di qui: la
    /// logica anti raffica sta in un punto solo, non ripetuta tre volte.
    private func fire(_ kind: Kind, title: String, body: String) {
        if let last = lastNotified[kind],
           Date().timeIntervalSince(last) < quietPeriod { return }
        armed[kind] = false
        lastNotified[kind] = Date()

        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
    }
}
