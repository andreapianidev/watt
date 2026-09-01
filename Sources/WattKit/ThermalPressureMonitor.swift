import Foundation
import notify

/// Legge la pressione termica dalla **stessa sorgente di `powermetrics`**,
/// senza lanciare processi e senza privilegi.
///
/// `powermetrics` non misura la pressione termica: la legge. Fra le stringhe
/// del binario c'e' "thermal pressure notifications", e la notifica in
/// questione e' `kOSThermalNotificationPressureLevelName` di
/// `<libkern/OSThermalNotification.h>`, cioe' la chiave notify(3)
/// `com.apple.system.thermalpressurelevel`. Il kernel ci pubblica un intero
/// che su macOS vale 0…4 e che corrisponde uno a uno ai nomi che
/// `powermetrics` stampa nel campo `thermal_pressure` — gli stessi che
/// asitop riduce a `throttle: yes/no`.
///
/// Il che cambia tre cose:
///
/// - la pressione **misurata** e' disponibile di continuo, non solo mentre
///   il menu e' aperto: prima serviva un `powermetrics` da mezzo secondo per
///   ogni lettura, e a menu chiuso l'app ripiegava sulla stima di
///   `ProcessInfo`, che sbaglia di un livello intero;
/// - costa un `notify_get_state`, cioe' una lettura di memoria condivisa:
///   sotto il microsecondo, contro i ~500 ms di un campione di powermetrics;
/// - funziona **senza helper installato**, come IOReport e i sensori HID.
///
/// La verifica appaiata sta in `Watt --verify-pressure`: confronta questo
/// valore con quello che `powermetrics` riporta nello stesso istante.
public final class ThermalPressureMonitor: @unchecked Sendable {

    /// `kOSThermalNotificationPressureLevelName`. La costante e' esportata
    /// come `const char *` da libSystem e non arriva a Swift: il valore e'
    /// verificato stampandolo da C sullo stesso SDK ed e' stabile da OS X
    /// 10.10.
    public static let notificationName = "com.apple.system.thermalpressurelevel"

    /// `NOTIFY_STATUS_OK`. La macro non attraversa l'importazione, e
    /// confrontare con lo zero nudo renderebbe illeggibile il controllo.
    private static let statusOK: UInt32 = 0

    private let lock = NSLock()
    private var token: Int32 = -1
    private let registered: Bool

    /// Token della registrazione con callback, tenuto separato: notify(3)
    /// non permette di usare lo stesso token sia in `check` sia in
    /// `dispatch`, e mescolarli fa perdere gli eventi.
    private var watchToken: Int32 = -1
    private var watching = false

    public init() {
        var value: Int32 = -1
        registered = notify_register_check(Self.notificationName, &value)
            == Self.statusOK
        token = value
    }

    deinit {
        if registered { notify_cancel(token) }
        if watching { notify_cancel(watchToken) }
    }

    /// Livello corrente, o `nil` se la registrazione non e' riuscita.
    ///
    /// `nil` non e' "nominale": e' "non lo so". Confonderli farebbe dire
    /// all'app che va tutto bene proprio quando ha perso la fonte.
    public var level: ThermalPressure? {
        guard registered else { return nil }
        lock.lock()
        defer { lock.unlock() }
        var state: UInt64 = 0
        guard notify_get_state(token, &state) == Self.statusOK else { return nil }
        return ThermalPressure(kernelLevel: state)
    }

    /// Chiama `handler` a ogni cambio di livello.
    ///
    /// Serve a far cambiare l'icona nell'istante in cui il sistema dichiara
    /// la limitazione, invece che al prossimo giro del timer: a menu chiuso
    /// la cadenza puo' essere di dieci secondi, e dieci secondi di icona
    /// sbagliata su un evento che dura un minuto sono un sesto della verita'
    /// persa per niente.
    public func observe(on queue: DispatchQueue = .main,
                        handler: @escaping @Sendable (ThermalPressure) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !watching else { return }
        var value: Int32 = -1
        let status = notify_register_dispatch(
            Self.notificationName, &value, queue
        ) { [weak self] _ in
            guard let level = self?.level else { return }
            handler(level)
        }
        guard status == Self.statusOK else { return }
        watchToken = value
        watching = true
    }
}
