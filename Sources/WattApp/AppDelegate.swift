import AppKit
import WattKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var helper: HelperConnection!
    private var controller: PowerController!
    private var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        helper = HelperConnection()
        controller = PowerController(helper: helper)

        switch helper.install() {
        case .installed:
            break
        case .needsApproval:
            // Non si apre subito Impostazioni di Sistema: un'app che al primo
            // avvio dirotta l'utente altrove e' invadente. Lo si segnala al
            // primo cambio di profilo, quando l'approvazione serve davvero.
            NSLog("[Watt] helper in attesa di approvazione")
        case .failed(let message):
            NSLog("[Watt] registrazione helper fallita: %@", message)
        }

        menuBar = MenuBarController(controller: controller, helper: helper)
        controller.reapplyAtLaunch()
    }

    /// L'assertion di sospensione e' legata al processo, ma App Nap no:
    /// va rimessa a posto esplicitamente, altrimenti resterebbe disattivato
    /// per l'intero sistema dopo la chiusura di Watt.
    func applicationWillTerminate(_ notification: Notification) {
        AppNapControl.setDisabled(false)
    }
}
