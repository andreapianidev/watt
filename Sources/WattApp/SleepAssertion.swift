import Foundation
import IOKit.pwr_mgt

/// Impedisce la sospensione per inattivita' finche' resta viva.
///
/// Preferita a `pmset -a disablesleep 1` perche' il kernel la rilascia
/// automaticamente quando il processo termina, anche per crash o kill -9.
/// L'impostazione di pmset invece persisterebbe, lasciando un Mac che non
/// dorme piu' e nessun indizio sul perche'.
final class SleepAssertion {

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var isHeld = false

    var isActive: Bool { isHeld }

    /// Lo schermo puo' comunque spegnersi: si inibisce la sospensione del
    /// *sistema*, non il risparmio del display. Un profilo prestazionale non
    /// e' una buona ragione per tenere acceso un pannello che nessuno guarda.
    func acquire(reason: String) {
        guard !isHeld else { return }
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID)
        isHeld = (status == kIOReturnSuccess)
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        isHeld = false
    }

    deinit { release() }
}
