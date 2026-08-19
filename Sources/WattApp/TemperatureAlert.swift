import Foundation
import UserNotifications
import WattKit

/// Avvisa quando il SoC supera una soglia.
///
/// Su un Mac senza ventola la temperatura alta non è un guasto: è il normale
/// prezzo di un carico prolungato. L'avviso serve a sapere *quando* smetti di
/// avere le prestazioni per cui credi di stare aspettando, non a spaventare.
@MainActor
final class TemperatureAlert {

    /// Soglie proposte. Un M2 Air in throttling sostenuto sta stabilmente
    /// sopra i 90 °C, quindi soglie più basse produrrebbero solo rumore.
    static let thresholds: [Double] = [80, 85, 90, 95]

    private var authorized = false
    private var lastNotified: Date?
    /// Sopra soglia si resta a lungo: senza una pausa, l'avviso arriverebbe a
    /// ogni campione finché la build non finisce.
    private let quietPeriod: TimeInterval = 10 * 60
    /// Isteresi: si riarma solo dopo essere scesi di qualche grado, altrimenti
    /// oscillare attorno alla soglia genererebbe una raffica di avvisi.
    private let rearmMargin: Double = 4
    private var armed = true

    func requestAuthorizationIfNeeded() {
        guard Preferences.alertsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func evaluate(socCelsius: Double?, throttling: Bool) {
        guard Preferences.alertsEnabled, let socCelsius else { return }
        let threshold = Preferences.alertThreshold

        if socCelsius < threshold - rearmMargin { armed = true }
        guard armed, socCelsius >= threshold else { return }

        if let lastNotified, Date().timeIntervalSince(lastNotified) < quietPeriod {
            return
        }
        armed = false
        lastNotified = Date()
        deliver(socCelsius: socCelsius, throttling: throttling)
    }

    private func deliver(socCelsius: Double, throttling: Bool) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = L("SoC at %.0f °C", socCelsius)
        content.body = throttling
            ? L("The system is limiting performance because of heat. On a "
              + "fanless Mac there is no way around it: you can only reduce "
              + "the load or give it a break.")
            : L("Temperature is above your threshold, but performance is not "
              + "being limited yet.")
        content.sound = .default

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
    }
}
