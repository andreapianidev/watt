import Foundation
import WattKit

/// Legge un campione da `powermetrics`.
///
/// `powermetrics` richiede root ed e' l'unica fonte di frequenza reale dei
/// core, tetto DVFM e potenza del package: nessuna API pubblica li espone.
/// Chiavi e unita' sono state verificate sull'output reale di Mac14,15 /
/// macOS 27; resta un fallback testuale perche' il formato non e'
/// documentato e cambia fra versioni di macOS.
enum PowerMetricsSampler {

    /// Intervallo minimo: `powermetrics` misura per differenza, con finestre
    /// piu' corte le frequenze diventano rumorose.
    private static let sampleIntervalMs = 500

    static func sample() -> PowerSample {
        let plistRun = CommandRunner.run(
            Tool.powermetrics,
            ["--samplers", "cpu_power,thermal",
             "-n", "1", "-i", String(sampleIntervalMs), "--format", "plist"],
            timeout: 15)

        if plistRun.succeeded,
           let parsed = parsePlist(plistRun.stdoutData) {
            return parsed
        }
        NSLog("[Watt] powermetrics plist fallito: stato=%d stderr=%@ bytes=%d",
              plistRun.status,
              plistRun.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
              plistRun.stdoutData.count)

        let textRun = CommandRunner.run(
            Tool.powermetrics,
            ["--samplers", "cpu_power,thermal",
             "-n", "1", "-i", String(sampleIntervalMs)],
            timeout: 15)
        if !textRun.succeeded {
            NSLog("[Watt] powermetrics testo fallito: stato=%d stderr=%@",
                  textRun.status,
                  textRun.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parseText(textRun.stdout)
    }

    // MARK: - Plist

    /// `powermetrics` separa i campioni con un byte NUL e ne lascia uno in
    /// coda anche con `-n 1`. Passare il buffer grezzo a
    /// `PropertyListSerialization` fallisce: va isolato il singolo documento.
    static func parsePlist(_ data: Data) -> PowerSample? {
        let documents = data
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { Data($0) }
        guard let document = documents.first(where: { $0.count > 32 }),
              let root = try? PropertyListSerialization.propertyList(
                  from: document, options: [], format: nil) as? [String: Any]
        else { return nil }

        var sample = PowerSample()
        sample.thermalPressureRaw = root["thermal_pressure"] as? String
        sample.thermalPressureSource =
            sample.thermalPressureRaw == nil ? .unknown : .powermetrics

        guard let processor = root["processor"] as? [String: Any] else {
            return sample.thermalPressureRaw == nil ? nil : sample
        }

        // Potenze gia' in milliwatt nell'output nativo.
        sample.cpuMilliwatts = numeric(processor["cpu_power"])
        sample.gpuMilliwatts = numeric(processor["gpu_power"])
        sample.aneMilliwatts = numeric(processor["ane_power"])
        sample.packageMilliwatts = numeric(processor["combined_power"])
            ?? [sample.cpuMilliwatts, sample.gpuMilliwatts, sample.aneMilliwatts]
                .compactMap { $0 }
                .reduce(0, +)

        for cluster in processor["clusters"] as? [[String: Any]] ?? [] {
            let name = (cluster["name"] as? String ?? "").uppercased()
            let mhz = numeric(cluster["freq_hz"]).map { $0 / 1_000_000 }
            let ceiling = ceilingMHz(in: cluster)

            if name.hasPrefix("P") {
                sample.pCoreMHz = mhz
                sample.pCoreCeilingMHz = ceiling
                sample.pCoreIdleRatio = numeric(cluster["idle_ratio"])
            } else if name.hasPrefix("E") {
                sample.eCoreMHz = mhz
                sample.eCoreCeilingMHz = ceiling
            }
        }

        return sample
    }

    /// Il tetto del cluster e' il massimo stato DVFM esposto: 3504 MHz per i
    /// P-core dell'M2, 2424 per gli E-core. Leggerlo invece di inchiodarlo in
    /// una costante fa funzionare l'app su qualunque Apple Silicon.
    private static func ceilingMHz(in cluster: [String: Any]) -> Double? {
        guard let states = cluster["dvfm_states"] as? [[String: Any]] else {
            return nil
        }
        let frequencies = states.compactMap { numeric($0["freq"]) }
        return frequencies.max()
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Testo

    static func parseText(_ text: String) -> PowerSample {
        var sample = PowerSample()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()

            if lower.contains("cluster") && lower.contains("active frequency") {
                guard let mhz = trailingNumber(in: line) else { continue }
                if lower.hasPrefix("p") { sample.pCoreMHz = mhz }
                if lower.hasPrefix("e") { sample.eCoreMHz = mhz }
            } else if lower.hasPrefix("cpu power") {
                sample.cpuMilliwatts = trailingNumber(in: line)
            } else if lower.hasPrefix("gpu power") {
                sample.gpuMilliwatts = trailingNumber(in: line)
            } else if lower.hasPrefix("combined power") {
                sample.packageMilliwatts = trailingNumber(in: line)
            } else if lower.contains("pressure level") {
                sample.thermalPressureRaw = line
                    .split(separator: ":").last?
                    .trimmingCharacters(in: .whitespaces)
                sample.thermalPressureSource =
                    sample.thermalPressureRaw == nil ? .unknown : .powermetrics
            }
        }
        if sample.packageMilliwatts == nil {
            let parts = [sample.cpuMilliwatts, sample.gpuMilliwatts].compactMap { $0 }
            if !parts.isEmpty { sample.packageMilliwatts = parts.reduce(0, +) }
        }
        return sample
    }

    /// Il valore sta sempre dopo i due punti: "E-Cluster HW active frequency:
    /// 1734 MHz". Cercare la prima cifra della riga prenderebbe la "2" di un
    /// eventuale "E-Cluster2".
    private static func trailingNumber(in line: String) -> Double? {
        guard let tail = line.split(separator: ":").last else { return nil }
        var digits = ""
        for character in tail {
            if character.isNumber || character == "." {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Double(digits)
    }
}
