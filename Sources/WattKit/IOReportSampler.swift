import Foundation
import IOKit

/// Legge frequenza e tetto dei cluster CPU direttamente da **IOReport**.
///
/// `powermetrics` non e' altro che un client di questa stessa API. Chiamarla
/// direttamente evita di lanciare un processo a ogni campione, il che oltre
/// a costare meno elimina una classe intera di problemi: i `fork`/`exec`
/// concorrenti si portano dietro una gara sui descrittori dei pipe, e il
/// lettore di un figlio puo' restare bloccato in attesa di un EOF che non
/// arriva mai.
///
/// Non richiede privilegi: i canali "CPU Stats" e la tabella DVFS nel
/// registro IO sono leggibili da un processo utente qualunque. E' il motivo
/// per cui la barra dei menu mostra dati veri anche senza helper installato.
///
/// I simboli vivono in `/usr/lib/libIOReport.dylib` e non sono dichiarati in
/// alcun header pubblico, quindi si risolvono a runtime. Se un
/// aggiornamento di macOS li spostasse, `isAvailable` diventa `false` e
/// l'app continua a funzionare senza queste letture invece di crollare.
public final class IOReportSampler {

    public struct Reading: Sendable {
        public var pCoreMHz: Double?
        public var eCoreMHz: Double?
        public var pCoreCeilingMHz: Double?
        public var eCoreCeilingMHz: Double?
    }

    // MARK: - Simboli

    private typealias FnCopyGroup = @convention(c)
        (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias FnMerge = @convention(c)
        (CFMutableDictionary?, CFMutableDictionary?, CFTypeRef?) -> Void
    private typealias FnSubscribe = @convention(c)
        (UnsafeMutableRawPointer?, CFMutableDictionary?,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias FnSamples = @convention(c)
        (AnyObject?, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias FnDelta = @convention(c)
        (CFDictionary?, CFDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias FnIterate = @convention(c)
        (CFDictionary?, @convention(block) (CFDictionary) -> Int32) -> Int32
    private typealias FnString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias FnStateCount = @convention(c) (CFDictionary) -> Int32
    private typealias FnStateResidency = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias FnStateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private let copyGroup: FnCopyGroup
    private let merge: FnMerge
    private let createSamples: FnSamples
    private let createDelta: FnDelta
    private let iterate: FnIterate
    private let channelName: FnString
    private let channelGroup: FnString
    private let stateCount: FnStateCount
    private let stateResidency: FnStateResidency
    private let stateName: FnStateName

    private let subscription: AnyObject
    private let subscribedChannels: CFMutableDictionary?

    /// Frequenze dichiarate dal silicio, in MHz, per i due cluster.
    private let eStates: [Double]
    private let pStates: [Double]

    /// Ultimo campione grezzo: il delta si calcola fra due letture
    /// successive, quindi ne va conservata sempre una.
    private var previous: CFDictionary?


    // MARK: - Costruzione

    public init?() {
        guard let library = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY) else {
            return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(library, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard
            let copyGroup = symbol("IOReportCopyChannelsInGroup", FnCopyGroup.self),
            let merge = symbol("IOReportMergeChannels", FnMerge.self),
            let subscribe = symbol("IOReportCreateSubscription", FnSubscribe.self),
            let createSamples = symbol("IOReportCreateSamples", FnSamples.self),
            let createDelta = symbol("IOReportCreateSamplesDelta", FnDelta.self),
            let iterate = symbol("IOReportIterate", FnIterate.self),
            let channelName = symbol("IOReportChannelGetChannelName", FnString.self),
            let channelGroup = symbol("IOReportChannelGetGroup", FnString.self),
            let stateCount = symbol("IOReportStateGetCount", FnStateCount.self),
            let stateResidency = symbol("IOReportStateGetResidency", FnStateResidency.self),
            let stateName = symbol("IOReportStateGetNameForIndex", FnStateName.self)
        else { return nil }

        self.copyGroup = copyGroup
        self.merge = merge
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.iterate = iterate
        self.channelName = channelName
        self.channelGroup = channelGroup
        self.stateCount = stateCount
        self.stateResidency = stateResidency
        self.stateName = stateName

        let states = Self.voltageStates()
        guard !states.efficiency.isEmpty, !states.performance.isEmpty else {
            return nil
        }
        self.eStates = states.efficiency
        self.pStates = states.performance

        // Solo le residenze per stato dei due complessi: e' quanto basta a
        // ricavare la frequenza media, e sottoscrivere meno canali rende il
        // campione piu' rapido.
        guard let raw = copyGroup("CPU Stats" as CFString,
                                  "CPU Complex Performance States" as CFString,
                                  0, 0, 0) else { return nil }
        let channels = raw.takeRetainedValue()

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscriptionRaw = subscribe(nil, channels, &subscribed, 0, nil) else {
            return nil
        }
        self.subscription = subscriptionRaw.takeRetainedValue()
        self.subscribedChannels = subscribed?.takeRetainedValue()

        // Prima lettura subito, cosi' il campione successivo ha gia' un
        // riferimento con cui calcolare il delta.
        self.previous = createSamples(subscription, subscribedChannels, nil)?
            .takeRetainedValue()
    }

    // MARK: - Campionamento

    /// Frequenze medie **mentre i core erano attivi**, sull'intervallo
    /// trascorso dalla chiamata precedente.
    public func sample() -> Reading {
        var reading = Reading(pCoreCeilingMHz: pStates.max(),
                              eCoreCeilingMHz: eStates.max())

        guard let current = createSamples(subscription, subscribedChannels, nil)?
                .takeRetainedValue() else { return reading }
        defer { previous = current }

        guard let earlier = previous,
              let delta = createDelta(earlier, current, nil)?.takeRetainedValue()
        else { return reading }

        var pMHz: Double?
        var eMHz: Double?

        _ = iterate(delta) { [self] channel in
            let group = channelGroup(channel)?.takeUnretainedValue() as String? ?? ""
            guard group == "CPU Stats" else { return 0 }
            let name = channelName(channel)?.takeUnretainedValue() as String? ?? ""

            let isPerformance = name.uppercased().hasPrefix("P")
            let states = isPerformance ? pStates : eStates
            guard let mhz = averageFrequency(channel: channel, states: states)
            else { return 0 }

            if isPerformance { pMHz = mhz } else { eMHz = mhz }
            return 0
        }

        reading.pCoreMHz = pMHz
        reading.eCoreMHz = eMHz
        return reading
    }

    /// Media delle frequenze pesata sulla residenza in ciascuno stato DVFS.
    ///
    /// Gli stati di riposo sono esclusi: la domanda a cui la barra dei menu
    /// risponde e' "a che velocita' gira quando lavora", non "quanto ha
    /// lavorato". Includerli farebbe crollare il numero ogni volta che il
    /// Mac e' fermo, che e' il momento in cui interessa meno.
    private func averageFrequency(channel: CFDictionary, states: [Double]) -> Double? {
        var weighted = 0.0
        var total = 0.0
        var frequencyIndex = 0

        for index in 0..<stateCount(channel) {
            let label = (stateName(channel, index)?.takeUnretainedValue() as String? ?? "")
                .uppercased()
            let isIdle = label.contains("IDLE") || label.contains("OFF")
                      || label.contains("DOWN")
            if isIdle { continue }

            defer { frequencyIndex += 1 }
            guard frequencyIndex < states.count else { continue }
            let residency = Double(stateResidency(channel, index))
            weighted += states[frequencyIndex] * residency
            total += residency
        }
        guard total > 0 else { return nil }
        return weighted / total
    }

    // MARK: - Tabella DVFS

    /// Frequenze supportate dai due cluster, lette dal nodo `pmgr` del
    /// registro IO. Leggerle invece di inchiodarle in una costante fa
    /// funzionare l'app su qualunque Apple Silicon, non solo sull'M2.
    private static func voltageStates() -> (efficiency: [Double], performance: [Double]) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator
        ) == KERN_SUCCESS else { return ([], []) }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(service, &name)
            guard String(cString: name) == "pmgr" else { continue }

            func frequencies(_ key: String) -> [Double] {
                guard let data = IORegistryEntryCreateCFProperty(
                    service, key as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? Data else { return [] }

                // Coppie (frequenza in hertz, tensione), 4 byte ciascuna.
                var result: [Double] = []
                data.withUnsafeBytes { buffer in
                    let values = buffer.bindMemory(to: UInt32.self)
                    for index in stride(from: 0, to: values.count, by: 2) {
                        let hertz = Double(values[index])
                        if hertz > 0 { result.append(hertz / 1_000_000) }
                    }
                }
                return result
            }

            var efficiency = frequencies("voltage-states1-sram")
            var performance = frequencies("voltage-states5-sram")
            if efficiency.isEmpty { efficiency = frequencies("voltage-states1") }
            if performance.isEmpty { performance = frequencies("voltage-states5") }
            return (efficiency, performance)
        }
        return ([], [])
    }
}
