import AppKit
import WattKit

/// Grafico delle temperature disegnato dentro una voce di menu.
///
/// Una voce di menu con `view` personalizzata non viene attenuata come
/// quelle disabilitate, quindi il disegno resta a piena opacità: è anche il
/// motivo per cui le righe informative non possono essere semplici
/// `NSMenuItem` senza azione.
final class TemperatureChartView: NSView {

    var history = TemperatureHistory() { didSet { needsDisplay = true } }
    /// Soglia di allerta, tracciata come riferimento orizzontale.
    var warningCelsius: Double = 90 { didSet { needsDisplay = true } }

    /// Margini interni allineati al rientro del testo delle voci di menu,
    /// cosi' il grafico comincia e finisce dove cominciano e finiscono le
    /// scritte invece che ai bordi della finestra.
    private let insets = NSEdgeInsets(top: 22, left: 14, bottom: 18, right: 14)

    /// Larghezza minima; `stretchChartToMenuWidth()` la porta a quella del
    /// menu a ogni apertura.
    override var intrinsicContentSize: NSSize { NSSize(width: 260, height: 108) }

    // Larghezza fissa, deliberatamente.
    //
    // Adattarla a `menu.size.width` sembrava la cosa giusta ma innesca una
    // retroazione: la vista si allarga fino al menu, il menu si allarga per
    // contenere la vista, e al disegno successivo si ricomincia. Il menu
    // cresceva fino a occupare tutto lo schermo, con i valori delle righe
    // tagliati fuori.
    //
    // 300 punti stanno appena oltre il tab stop delle righe informative, che
    // e' cio' che stabilisce davvero la larghezza del menu: il grafico la
    // riempie senza mai deciderla.

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(
            x: insets.left,
            y: insets.bottom,
            width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.top - insets.bottom)

        drawHeader()
        guard history.points.count > 1, plot.width > 0, plot.height > 0 else {
            drawPlaceholder(in: plot)
            return
        }

        let (low, high) = history.range
        let span = max(high - low, 0.1)

        func position(_ celsius: Double, at index: Int) -> NSPoint {
            let x = plot.minX + plot.width
                * CGFloat(index) / CGFloat(history.points.count - 1)
            let y = plot.minY + plot.height * CGFloat((celsius - low) / span)
            return NSPoint(x: x, y: min(max(y, plot.minY), plot.maxY))
        }

        drawWarningLine(in: plot, low: low, span: span)

        // Area sotto la massima: dà il colpo d'occhio sull'andamento senza
        // bisogno di leggere i numeri.
        let area = NSBezierPath()
        area.move(to: NSPoint(x: plot.minX, y: plot.minY))
        for (index, point) in history.points.enumerated() {
            area.line(to: position(point.maximum, at: index))
        }
        area.line(to: NSPoint(x: plot.maxX, y: plot.minY))
        area.close()
        NSColor.systemOrange.withAlphaComponent(0.18).setFill()
        area.fill()

        stroke(values: history.points.map(\.maximum),
               color: .systemOrange, width: 1.8, position: position)
        stroke(values: history.points.map(\.average),
               color: .systemTeal, width: 1.2, position: position)

        drawScale(low: low, high: high, in: plot)
    }

    private func stroke(values: [Double], color: NSColor, width: CGFloat,
                        position: (Double, Int) -> NSPoint) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineJoinStyle = .round
        for (index, value) in values.enumerated() {
            let point = position(value, index)
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        color.setStroke()
        path.stroke()
    }

    private func drawWarningLine(in plot: NSRect, low: Double, span: Double) {
        let y = plot.minY + plot.height * CGFloat((warningCelsius - low) / span)
        guard y > plot.minY, y < plot.maxY else { return }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: plot.minX, y: y))
        path.line(to: NSPoint(x: plot.maxX, y: y))
        path.lineWidth = 1
        path.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.systemRed.withAlphaComponent(0.5).setStroke()
        path.stroke()
    }

    private func drawHeader() {
        let latest = history.latest
        let title = attributed(L("Temperature"), size: NSFont.smallSystemFontSize,
                               color: .secondaryLabelColor)
        title.draw(at: NSPoint(x: insets.left, y: bounds.height - 18))

        guard let latest else { return }
        let legend = NSMutableAttributedString()
        legend.append(attributed("● ", size: 11, color: .systemOrange))
        legend.append(attributed(L("peak %.0f°  ", latest.maximum),
                                 size: 11, color: .labelColor))
        legend.append(attributed("● ", size: 11, color: .systemTeal))
        legend.append(attributed(L("avg %.0f°", latest.average),
                                 size: 11, color: .labelColor))
        legend.draw(at: NSPoint(x: bounds.width - insets.right - legend.size().width,
                                y: bounds.height - 18))
    }

    private func drawScale(low: Double, high: Double, in plot: NSRect) {
        attributed(String(format: "%.0f°", high), size: 9,
                   color: .tertiaryLabelColor)
            .draw(at: NSPoint(x: 2, y: plot.maxY - 6))
        attributed(String(format: "%.0f°", low), size: 9,
                   color: .tertiaryLabelColor)
            .draw(at: NSPoint(x: 2, y: plot.minY - 4))

        let minutes = history.span / 60
        attributed(L("last %.0f min", max(minutes, 1)),
                   size: 9, color: .tertiaryLabelColor)
            .draw(at: NSPoint(x: plot.minX, y: 3))
    }

    private func drawPlaceholder(in plot: NSRect) {
        let text = attributed(L("Collecting data…"), size: 11,
                              color: .tertiaryLabelColor)
        text.draw(at: NSPoint(x: plot.midX - text.size().width / 2,
                              y: plot.midY - 6))
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
