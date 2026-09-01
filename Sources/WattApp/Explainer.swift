import Foundation
import WattKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Mette in parole semplici una diagnosi già misurata, con il modello di
/// Apple Intelligence che gira sul dispositivo.
///
/// **Il modello non diagnostica.** La causa, la misura e il rimedio arrivano
/// già decisi da `Diagnosis`, che li ricava dai sensori: qui si riscrivono
/// soltanto. È una distinzione che vale la pena tenere ferma, perché provando
/// il contrario il modello di sistema si è inventato cause che non c'erano
/// ("la pressione sul pacchetto di 3,5 watt") e ha proposto rimedi che non
/// vogliono dire niente. Vincolato a riformulare, non sbanda.
///
/// La generazione è guidata (`@Generable`) e non libera per la stessa ragione:
/// a testo libero, sugli stessi fatti, aggiungeva condizioni mai date ("se non
/// c'è aria fresca"). Due campi corti da riempire non gliene lasciano lo
/// spazio.
///
/// Niente rete, niente chiavi, niente account: il modello è quello di sistema
/// e l'app resta senza dipendenze.
///
/// **Non è isolato sul main actor, e non deve diventarlo.** Da riga di comando
/// il thread principale aspetta il risultato bloccandosi: se la generazione
/// dovesse tornare sul main actor per finire, non finirebbe mai, e `--explain`
/// resterebbe appeso per sempre. Verificato riproducendo il blocco.
enum Explainer {

    /// Perché la spiegazione non si può avere. `nil` quando si può.
    enum Unavailable {
        /// Sistema più vecchio di quello che porta il modello.
        case tooOld
        /// Modello presente ma non utilizzabile ora: hardware non idoneo,
        /// Apple Intelligence spenta, modello non ancora scaricato.
        case modelUnavailable(String)

        var message: String {
            switch self {
            case .tooOld:
                return L("Plain-language explanations need a newer macOS.")
            case .modelUnavailable(let reason):
                return L("Apple Intelligence is not available on this Mac: %@",
                         reason)
            }
        }
    }

    /// `nil` se il modello si può usare adesso.
    static var unavailable: Unavailable? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .tooOld }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return .modelUnavailable(Self.describe(reason))
        @unknown default:
            return .modelUnavailable(L("unknown reason"))
        }
        #else
        return .tooOld
        #endif
    }

    /// Vero quando la voce di menu ha senso di esistere: modello utilizzabile
    /// e spiegazioni non disattivate dall'utente.
    static var isOffered: Bool {
        Preferences.explanationsEnabled && unavailable == nil
    }

    /// Le due frasi che il modello deve produrre.
    struct Explanation {
        var whatIsHappening: String
        var whatToDo: String
    }

    /// Riformula il verdetto. Lancia se il modello non è disponibile o se la
    /// generazione fallisce: il chiamante mostra l'errore invece di inventare
    /// un testo di ripiego, che sarebbe indistinguibile da una risposta vera.
    static func explain(_ finding: Diagnosis.Finding) async throws -> Explanation {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw Failure.unsupported }
        let session = LanguageModelSession(instructions: Self.instructions)
        let answer = try await session.respond(to: Self.prompt(for: finding),
                                               generating: Draft.self)
        return Explanation(whatIsHappening: answer.content.whatIsHappening,
                           whatToDo: answer.content.whatToDo)
        #else
        throw Failure.unsupported
        #endif
    }

    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? {
            L("This Mac cannot run the on-device model.")
        }
    }

    // MARK: - Come viene chiesto

    /// Le istruzioni sono in inglese perché il modello le segue meglio, ma la
    /// lingua della risposta segue quella dell'interfaccia: chi legge Watt in
    /// italiano non vuole una spiegazione in inglese.
    private static var instructions: String {
        """
        You rewrite an already-completed technical diagnosis so that someone \
        who knows nothing about hardware can understand it.

        Diagnosing is not your job. The cause, the measurement and the remedy \
        are given to you. Do not add causes, conditions, numbers or remedies \
        that are not in the text you receive. Do not mention fans, airflow or \
        room temperature: they are not in the measurements.

        Write in \(Localization.modelLanguageName). Keep each field to one \
        short sentence. Never use an em dash.
        """
    }

    private static func prompt(for finding: Diagnosis.Finding) -> String {
        var lines = ["Established cause: \(finding.title)",
                     "Measurement: \(finding.measured)",
                     "Established remedy: \(finding.advice)"]
        if let basis = finding.basis {
            lines.append("What that rests on: \(basis)")
        }
        return lines.joined(separator: "\n")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return L("this hardware does not support it")
        case .appleIntelligenceNotEnabled:
            return L("Apple Intelligence is switched off in System Settings")
        case .modelNotReady:
            return L("the model is still downloading")
        @unknown default:
            return L("unknown reason")
        }
    }

    /// La forma che il modello deve riempire.
    ///
    /// I due campi separati non sono cosmetici: costringono a distinguere la
    /// constatazione dal rimedio, che a testo libero tendevano a fondersi in
    /// una frase sola che non diceva né l'una né l'altro.
    @available(macOS 26.0, *)
    @Generable
    fileprivate struct Draft {
        @Guide(description: "What is happening to the machine. One sentence, no numbers.")
        var whatIsHappening: String
        @Guide(description: "What the reader should do. One sentence. Only the remedy you were given.")
        var whatToDo: String
    }
    #endif
}
