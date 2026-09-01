import Testing
import Foundation
@testable import WattApp
@testable import WattKit

/// Prove sui tre difetti trovati il 1 settembre 2026.
///
/// Non sono prove di copertura: ognuna riproduce un difetto che era arrivato
/// fino all'utente. Una prova scritta dopo il guasto vale piu' di dieci
/// scritte per abitudine, perche' quella descrive un errore che questo
/// programma ha davvero commesso.
struct RegressionTests {

    // MARK: - Lo swap occupato non e' swap in uso

    /// Il difetto: l'avviso «la RAM non basta» restava acceso sempre.
    ///
    /// Guardava quanto swap risultava occupato. macOS non lo restituisce
    /// finche' non gli serve la stanza, quindi dopo una compilazione pesante
    /// restano gigabyte allocati per giorni, a pressione verde e senza che una
    /// pagina si muova. Misurato sulla macchina il giorno del guasto: 1424 MB
    /// occupati, pressione 1, zero pagine scritte in cinque secondi, avviso
    /// acceso.
    @Test("Swap occupato ma fermo non e' swapping")
    func swapOccupatoMaFermo() {
        let snapshot = MemoryReader.Snapshot(
            freeBytes: 2_000_000_000,
            inactiveBytes: 2_000_000_000,
            compressedBytes: 1_000_000_000,
            totalBytes: 16_000_000_000,
            swapUsedBytes: 1_493_172_224,   // i 1424 MB veri di quel giorno
            swapTotalBytes: 2_147_483_648,
            pressureLevel: 1,               // verde, come in Monitoraggio Attivita'
            swapOutRate: 0)                 // nessuna pagina si muove

        #expect(snapshot.isSwapping == false,
                "swap occupato ma immobile non deve far scattare l'avviso")
    }

    /// L'altra meta': quando le pagine si muovono davvero, deve scattare.
    /// Una correzione che spegne l'avviso e basta non e' una correzione.
    @Test("Swap in movimento e' swapping")
    func swapInMovimento() {
        var snapshot = Self.riposo
        snapshot.swapOutRate = 12 * 1_048_576   // 12 MB/s su disco

        #expect(snapshot.isSwapping == true)
        #expect(snapshot.swapRateText == "12 MB/s")
    }

    /// Il respiro normale del compressore non e' una notizia.
    @Test("Sotto un mebibyte al secondo non e' una notizia")
    func swapFisiologico() {
        var snapshot = Self.riposo
        snapshot.swapOutRate = 500_000        // mezzo MB/s
        #expect(snapshot.isSwapping == false)
    }

    /// Al primo campione non c'e' un intervallo su cui misurare una velocita'.
    /// Li' si ripiega sul kernel, e con pressione normale non si dice niente.
    @Test("Primo campione: si ripiega sulla pressione del kernel")
    func primoCampioneSenzaVelocita() {
        var verde = Self.riposo
        verde.swapOutRate = nil
        verde.swapUsedBytes = 4_000_000_000
        verde.pressureLevel = 1
        #expect(verde.isSwapping == false,
                "pressione verde: swap occupato da solo non basta")

        var gialla = verde
        gialla.pressureLevel = 2
        #expect(gialla.isSwapping == true,
                "pressione gialla con swap occupato: la notizia c'e'")
    }

    // MARK: - La diagnosi termica

    /// La catena che il 1 settembre non si era potuta provocare a mano: su un
    /// Air 15" sotto carico pieno la temperatura si e' fermata a 65 gradi, e
    /// per arrivare alla limitazione sarebbero serviti venti minuti di forno.
    /// Qui la stessa catena si percorre in un millisecondo.
    @Test("Pressione termica pesante e misurata produce un verdetto")
    func verdettoTermico() {
        var sample = PowerSample()
        sample.pCoreMHz = 1190
        sample.pCoreCeilingMHz = 3500
        sample.thermalPressureRaw = ThermalPressure.heavy.rawValue
        // `.powermetrics` e' la fonte misurata: senza, l'app non si fida, ed
        // e' proprio il campo che l'helper del 19 agosto non compilava.
        sample.thermalPressureSource = .powermetrics

        let findings = Diagnosis.analyze(sample: sample, memory: nil, state: nil,
                                         processes: [], foregroundPIDs: [])
        let termico = findings.first { $0.severity > .ok }

        #expect(termico != nil, "pressione pesante misurata deve produrre un verdetto")
        #expect(sample.thermalSeverity == .alarm)
        #expect(sample.pCoreCeilingFraction != nil)
    }

    /// Una frequenza bassa **da sola** non e' throttling: a riposo i P-core
    /// stanno a ~900 MHz perche' non c'e' lavoro. Confonderli e' l'errore che
    /// rende inutile mezza categoria di monitor termici.
    @Test("Frequenza bassa a riposo non e' una limitazione")
    func frequenzaBassaNonEThrottling() {
        var sample = PowerSample()
        sample.pCoreMHz = 900
        sample.pCoreCeilingMHz = 3500
        sample.thermalPressureRaw = ThermalPressure.nominal.rawValue
        sample.thermalPressureSource = .powermetrics

        #expect(sample.thermalPressure.isThrottling == false)
        #expect(sample.thermalSeverity == .none)
    }

    /// Pressione pesante ma **stimata** da ProcessInfo invece che misurata:
    /// non deve valere come limitazione accertata. E' la distinzione per cui
    /// esiste `thermalPressureSource`.
    @Test("Pressione stimata non vale come misurata")
    func pressioneStimataNonEMisurata() {
        var sample = PowerSample()
        sample.thermalPressureRaw = ThermalPressure.heavy.rawValue
        sample.thermalPressureSource = .unknown

        #expect(sample.thermalPressureMeasured == false)
    }

    // MARK: - Apparecchio

    /// Una macchina a riposo, senza niente da segnalare.
    private static var riposo: MemoryReader.Snapshot {
        MemoryReader.Snapshot(
            freeBytes: 4_000_000_000,
            inactiveBytes: 4_000_000_000,
            compressedBytes: 500_000_000,
            totalBytes: 16_000_000_000,
            swapUsedBytes: 0,
            swapTotalBytes: 2_147_483_648,
            pressureLevel: 1,
            swapOutRate: 0)
    }
}
