import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Nessuna icona nel Dock e nessun menu applicazione: Watt vive solo
// nella barra dei menu.
application.setActivationPolicy(.accessory)
application.run()
