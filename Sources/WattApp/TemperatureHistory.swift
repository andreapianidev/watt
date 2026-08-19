import Foundation

/// Storico delle temperature, per i grafici in menu.
///
/// Buffer circolare a dimensione fissa: la finestra è quello che serve
/// vedere, e conservare oltre significherebbe far crescere la memoria di
/// un'app che sta in barra dei menu per giorni.
struct TemperatureHistory {

    struct Point {
        var maximum: Double
        var average: Double
    }

    /// A un campione ogni 5 secondi, 240 punti coprono venti minuti: la
    /// scala su cui si vede salire il calore durante una build.
    private(set) var points: [Point] = []
    let capacity = 240

    mutating func append(maximum: Double, average: Double) {
        points.append(Point(maximum: maximum, average: average))
        if points.count > capacity {
            points.removeFirst(points.count - capacity)
        }
    }

    var latest: Point? { points.last }

    var isEmpty: Bool { points.isEmpty }

    /// Estremi della serie, allargati di un grado per non far combaciare la
    /// curva con il bordo del grafico.
    var range: (low: Double, high: Double) {
        let values = points.flatMap { [$0.maximum, $0.average] }
        guard let minimum = values.min(), let maximum = values.max() else {
            return (30, 100)
        }
        // Una scala che si adatta troppo stretta trasforma mezzo grado di
        // rumore in un picco drammatico: si impone un'ampiezza minima.
        let span = max(maximum - minimum, 12)
        let center = (maximum + minimum) / 2
        return (center - span / 2 - 1, center + span / 2 + 1)
    }

    var peak: Double? { points.map(\.maximum).max() }

    var meanOfAverages: Double? {
        guard !points.isEmpty else { return nil }
        return points.map(\.average).reduce(0, +) / Double(points.count)
    }
}
