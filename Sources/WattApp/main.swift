import AppKit

// In modalita' da riga di comando non si avvia NSApplication: il processo
// parla con l'helper, stampa ed esce.
if CommandLineMode.run() { exit(0) }

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Nessuna icona nel Dock e nessun menu applicazione: Watt vive solo
// nella barra dei menu.
application.setActivationPolicy(.accessory)
application.run()
