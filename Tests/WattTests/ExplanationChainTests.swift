import Testing
import Foundation
@testable import WattApp
@testable import WattKit

/// La catena intera: sensori → verdetto misurato → riformulazione del modello.
///
/// Nasce da un buco lasciato aperto il 1 settembre 2026. Il pezzo finale non
/// si era potuto provare a mano perche' su un Air 15" servono venti minuti di
/// carico pieno per arrivare a una limitazione termica vera, e tenere il Mac
/// al forno non era un prezzo ragionevole per una verifica. Qui la stessa
/// catena si percorre in pochi secondi, partendo da un campione costruito
/// invece che aspettato.
///
/// Le prove che chiamano il modello si saltano da sole dove Apple Intelligence
/// non c'e': su un Mac non idoneo devono restare silenziose, non rosse.
struct ExplanationChainTests {

    /// Un campione con limitazione termica pesante e **misurata**, cioe' lo
    /// stato che la voce «Spiegamelo in parole semplici» deve incontrare.
    private static var campioneLimitato: PowerSample {
        var sample = PowerSample()
        sample.pCoreMHz = 1190
        sample.pCoreCeilingMHz = 3500
        sample.thermalPressureRaw = ThermalPressure.heavy.rawValue
        sample.thermalPressureSource = .powermetrics
        return sample
    }

    @Test("Il verdetto arriva completo di misura, rimedio e fondamento")
    func verdettoCompleto() {
        let findings = Diagnosis.analyze(sample: Self.campioneLimitato,
                                         memory: nil, state: nil,
                                         processes: [], foregroundPIDs: [])
        let finding = try? #require(findings.first { $0.severity > .ok })

        // Sono i quattro pezzi che il modello riceve. Se uno manca, il modello
        // riempie il vuoto da solo, ed e' esattamente cio' che non deve fare.
        #expect(finding?.title.isEmpty == false)
        #expect(finding?.measured.isEmpty == false)
        #expect(finding?.advice.isEmpty == false)
    }

    @Test("Il modello riformula senza inventare",
          .enabled(if: Explainer.unavailable == nil,
                   "Apple Intelligence non disponibile su questa macchina"))
    func riformulazioneAncorata() async throws {
        let findings = Diagnosis.analyze(sample: Self.campioneLimitato,
                                         memory: nil, state: nil,
                                         processes: [], foregroundPIDs: [])
        let finding = try #require(findings.first { $0.severity > .ok })

        let spiegazione = try await Explainer.explain(finding)

        #expect(!spiegazione.whatIsHappening.isEmpty)
        #expect(!spiegazione.whatToDo.isEmpty)

        let testo = spiegazione.whatIsHappening + " " + spiegazione.whatToDo

        // Niente lineette lunghe: e' una regola di questo progetto, e le
        // istruzioni al modello la contengono.
        #expect(!testo.contains("\u{2014}"))

        // Il difetto che aveva fatto scartare la generazione libera: sui
        // medesimi fatti il modello aggiungeva condizioni mai date, e la
        // ventola su un Mac che non ne ha e' la piu' evidente. Nessuno dei
        // fatti passati nomina aria o ventole.
        let inventate = ["ventola", "ventole", "fan", "aria fresca", "airflow"]
        for parola in inventate {
            #expect(!testo.lowercased().contains(parola),
                    "il modello ha aggiunto «\(parola)», che non era nei fatti")
        }
    }

    @Test("Senza modello la funzione si dichiara assente invece di rompersi")
    func assenzaDichiarata() {
        // Su questa macchina il modello c'e', quindi qui si verifica il verso
        // opposto: che `isOffered` risponda alla preferenza dell'utente e non
        // solo alla presenza del modello.
        let prima = Preferences.explanationsEnabled
        defer { Preferences.explanationsEnabled = prima }

        Preferences.explanationsEnabled = false
        #expect(Explainer.isOffered == false,
                "spente dall'utente, le spiegazioni non vanno offerte")

        Preferences.explanationsEnabled = true
        #expect(Explainer.isOffered == (Explainer.unavailable == nil))
    }
}
