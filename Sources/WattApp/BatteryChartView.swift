import AppKit
import WattKit

/// Batteria: capacita' residua, capacita' a piena carica e curva del degrado,
/// in una sola voce di menu.
///
/// Il disegno risponde a tre domande in tre righe, nell'ordine in cui uno se
/// le pone: quanta carica ho adesso, quanto e' invecchiata la batteria, e da
/// che parte sta andando. Le prime due sono letture istantanee; la terza
/// esiste solo se lo storico su disco ha abbastanza punti, e finche' non ne
/// ha lo dice invece di disegnare una riga piatta che sembrerebbe una misura.
final class BatteryChartView: NSView {

    var snapshot: BatterySnapshot? { didSet { needsDisplay = true } }
    var trend: [BatteryHistory.Entry] = [] { didSet { needsDisplay = true } }
    /// Estrapolazione lineare fino all'80%, in mesi. Nil quando non c'e'
    /// pendenza misurata da cui estrapolare.
    var monthsToEighty: Double?
    /// `false` finche' lo storico non copre abbastanza tempo perche' una
    /// curva significhi qualcosa. Lo decide `BatteryHistory`, che sa da
    /// quanto sta raccogliendo; qui si sa solo disegnare.
    var trendIsMeaningful = false

    private let insets = NSEdgeInsets(top: 22, left: 16, bottom: 16, right: 16)

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 150) }

    override func draw(_ dirtyRect: NSRect) {
        drawHeader()
        guard let snapshot, let design = snapshot.designCapacityMAh, design > 0
        else {
            drawPlaceholder(L("No battery"))
            return
        }

        let width = bounds.width - insets.left - insets.right
        let barRect = NSRect(x: insets.left, y: bounds.height - 52,
                             width: width, height: 16)
        drawCapacityBar(in: barRect, snapshot: snapshot, design: design)
        drawCapacityLegend(below: barRect, snapshot: snapshot, design: design)

        // Le due righe di legenda stanno sotto la barra; il grafico comincia
        // sotto di esse. Con margini piu' stretti l'etichetta della scala
        // finiva sopra il testo, e due numeri sovrapposti non si leggono ne'
        // l'uno ne' l'altro.
        let plot = NSRect(x: insets.left + 16, y: insets.bottom + 2,
                          width: width - 16,
                          height: barRect.minY - 40 - insets.bottom)
        if plot.height > 14 { drawTrend(in: plot) }
    }

    // MARK: - Barra delle capacita'

    /// Tre grandezze annidate nella stessa barra.
    ///
    /// La traccia e' la capacita' di progetto, che non cambia mai; il primo
    /// riempimento e' quella a piena carica di oggi, cioe' la salute; il
    /// secondo e' la carica presente. Sovrapporle invece di affiancarle e'
    /// il punto: si vede a colpo d'occhio che il "100%" della batteria di
    /// oggi e' piu' corto del "100%" di quando era nuova, che e' esattamente
    /// cio' che una percentuale di carica da sola non dice mai.
    private func drawCapacityBar(in rect: NSRect, snapshot: BatterySnapshot,
                                 design: Int) {
        let radius = rect.height / 2

        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            .fill(with: NSColor.tertiaryLabelColor.withAlphaComponent(0.22))

        if let full = snapshot.fullChargeCapacityMAh {
            let fraction = min(1, Double(full) / Double(design))
            let health = NSRect(x: rect.minX, y: rect.minY,
                                width: rect.width * fraction, height: rect.height)
            NSBezierPath(roundedRect: health, xRadius: radius, yRadius: radius)
                .fill(with: NSColor.secondaryLabelColor.withAlphaComponent(0.32))
        }

        if let remaining = snapshot.remainingCapacityMAh {
            let fraction = min(1, Double(remaining) / Double(design))
            let charge = NSRect(x: rect.minX, y: rect.minY,
                                width: max(rect.width * fraction, rect.height),
                                height: rect.height)
            NSBezierPath(roundedRect: charge, xRadius: radius, yRadius: radius)
                .fill(with: chargeColor(snapshot))
        }
    }

    /// Verde quando carica, rosso sotto il 20%, altrimenti il colore
    /// d'accento del sistema: gli stessi tre stati che usa l'indicatore di
    /// macOS, cosi' non ci sono due semafori che dicono cose diverse.
    private func chargeColor(_ snapshot: BatterySnapshot) -> NSColor {
        if snapshot.isCharging == true { return .systemGreen }
        if let percent = snapshot.chargePercent, percent <= 20 { return .systemRed }
        return .controlAccentColor
    }

    private func drawCapacityLegend(below bar: NSRect, snapshot: BatterySnapshot,
                                    design: Int) {
        let y = bar.minY - 16
        var left = attributed(L("design %d mAh", design), size: 10,
                              color: .secondaryLabelColor)
        left.draw(at: NSPoint(x: bar.minX, y: y))

        if let full = snapshot.fullChargeCapacityMAh,
           let health = snapshot.healthPercent {
            let text = L("full charge %d mAh · %.1f%%", full, health)
            let right = attributed(text, size: 10, color: .secondaryLabelColor)
            right.draw(at: NSPoint(x: bar.maxX - right.size().width, y: y))
        }

        if let remaining = snapshot.remainingCapacityMAh,
           let percent = snapshot.chargePercent {
            left = attributed(L("now %d mAh · %d%%", remaining, percent),
                              size: 10, color: .secondaryLabelColor)
            left.draw(at: NSPoint(x: bar.minX, y: y - 13))
        }
    }

    // MARK: - Curva del degrado

    private func drawTrend(in plot: NSRect) {
        let points = trend.compactMap { entry -> (Date, Double)? in
            guard let health = entry.healthPercent else { return nil }
            return (entry.at, health)
        }
        let values = points.map(\.1)
        // Serve tempo, non solo punti. Con due letture a mezz'ora di
        // distanza la differenza fra i due valori e' la ristima del gas
        // gauge: disegnarla produce una curva ripida e convincente che non
        // descrive nessun invecchiamento.
        guard trendIsMeaningful,
              points.count >= 4, let low = values.min(), let high = values.max(),
              high - low > 0.05, let first = points.first?.0,
              let last = points.last?.0, last > first
        else {
            drawTrendPlaceholder(in: plot)
            return
        }

        // Scala verticale di almeno un punto percentuale: senza, mezzo mAh
        // di rumore del gas gauge diventa un crollo verticale.
        let span = max(high - low, 1.0)
        let center = (high + low) / 2
        let bottom = center - span / 2
        let seconds = last.timeIntervalSince(first)

        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineJoinStyle = .round
        for (index, point) in points.enumerated() {
            let x = plot.minX + plot.width
                * CGFloat(point.0.timeIntervalSince(first) / seconds)
            let y = plot.minY + plot.height
                * CGFloat((point.1 - bottom) / span)
            let target = NSPoint(x: x, y: min(max(y, plot.minY), plot.maxY))
            index == 0 ? path.move(to: target) : path.line(to: target)
        }
        NSColor.systemTeal.setStroke()
        path.stroke()

        attributed(String(format: "%.1f%%", high), size: 9,
                   color: .secondaryLabelColor)
            .draw(at: NSPoint(x: insets.left, y: plot.maxY - 5))
        attributed(String(format: "%.1f%%", bottom), size: 9,
                   color: .secondaryLabelColor)
            .draw(at: NSPoint(x: insets.left, y: plot.minY - 3))

        var footer = L("%.0f days of history", seconds / 86400)
        if let months = monthsToEighty {
            footer += L(" · 80%% in ~%.0f months", months)
        }
        attributed(footer, size: 9, color: .secondaryLabelColor)
            .draw(at: NSPoint(x: plot.minX, y: 2))
    }

    /// Cosa mostrare finche' il degrado non e' ancora successo.
    ///
    /// Un grafico piatto disegnato su due punti identici sembra una misura e
    /// non lo e'. Dire quanti giorni di storico ci sono e' un'informazione
    /// vera; disegnare una riga orizzontale sarebbe una finzione.
    private func drawTrendPlaceholder(in plot: NSRect) {
        let days = trend.count >= 2
            ? (trend.last!.at.timeIntervalSince(trend.first!.at) / 86400) : 0
        let text = days < 1
            ? L("Degradation history starts now")
            : L("%.0f days of history, too early to draw a curve", days)
        let drawn = attributed(text, size: 10, color: .secondaryLabelColor)
        drawn.draw(at: NSPoint(x: plot.midX - drawn.size().width / 2,
                               y: plot.midY - 6))
    }

    // MARK: - Cornice

    private func drawHeader() {
        attributed(L("Battery"), size: NSFont.smallSystemFontSize,
                   color: .secondaryLabelColor)
            .draw(at: NSPoint(x: insets.left, y: bounds.height - 18))

        guard let snapshot else { return }
        var parts: [String] = []
        if let cycles = snapshot.cycleCount { parts.append(L("%d cycles", cycles)) }
        if let watts = snapshot.batteryWatts, abs(watts) >= 0.05 {
            parts.append(String(format: "%+.1f W", watts))
        }
        if let time = snapshot.timeRemainingText { parts.append(time) }
        guard !parts.isEmpty else { return }

        let legend = attributed(parts.joined(separator: " · "), size: 11,
                                color: .labelColor)
        legend.draw(at: NSPoint(x: bounds.width - insets.right - legend.size().width,
                                y: bounds.height - 18))
    }

    private func drawPlaceholder(_ text: String) {
        let drawn = attributed(text, size: 11, color: .secondaryLabelColor)
        drawn.draw(at: NSPoint(x: bounds.midX - drawn.size().width / 2,
                               y: bounds.midY - 6))
    }

    private func attributed(_ string: String, size: CGFloat,
                            color: NSColor) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size,
                                     weight: size < 10 ? .regular : .medium),
            .foregroundColor: color,
        ])
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
