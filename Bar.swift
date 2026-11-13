// Смужка Voice унизу екрана: тепла темна капсула, голос у ній світиться бурштином, як лампа в підсилювачі.
// Увесь кадр — функція від часу в одному Canvas: той самий код малює і на екрані, і в PNG.
// Гучність згладжена (вгору ≈70 мс, вниз ≈260 мс; сяйво — ще повільніше), тому нічого не блимає.
//   запис:      «Спектр» (стрічка спектра голосу, як у звуковому редакторі, зі світлою головкою запису),
//               «Стрічка» (пагорби голосу пливуть справа наліво) або «Хвиля» (три лінії); праворуч — час;
//   розпізнаю:  стовпчики біжать хвилею, по краю капсули пробігає світло;
//   вставлено:  галочка малюється сама, капсула стискається і зникає;
//   помилка:    червона, капсула кілька разів хитається «ні-ні».
import AppKit
import SwiftUI

// MARK: - Кольори

struct RGB {
    let r: Double, g: Double, b: Double
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    var color: Color { Color(red: r, green: g, blue: b) }
    func mix(_ o: RGB, _ t: Double) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
}

enum Palette {
    static let amber = RGB(1.000, 0.604, 0.235)     // #FF9A3C — головний акцент
    static let ember = RGB(0.910, 0.341, 0.165)     // #E8572A — жар, глибокий кінець
    static let filament = RGB(1.000, 0.851, 0.659)  // #FFD9A8 — нитка розжарення, найсвітліше
    static let paper = RGB(0.953, 0.914, 0.875)     // #F3E9DF — текст
    static let ash = RGB(0.612, 0.545, 0.494)       // #9C8B7E — другорядний текст
    static let dim = RGB(0.431, 0.384, 0.353)       // #6E625A — неактивне
    static let smoke = RGB(0.082, 0.063, 0.051)     // #15100D — тло
    static let smoke2 = RGB(0.110, 0.086, 0.071)    // #1C1612 — панель списку
    static let deck = RGB(0.149, 0.114, 0.090)      // #261D17 — пульт програвача
    static let signal = RGB(1.000, 0.365, 0.322)    // #FF5D52 — помилка
}

/// Світло лампи: жар → бурштин → нитка (u ∈ 0…1).
func glow(_ u: Double) -> RGB {
    let u = clamp01(u)
    return u < 0.55 ? Palette.ember.mix(Palette.amber, u / 0.55) : Palette.amber.mix(Palette.filament, (u - 0.55) / 0.45)
}

func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

/// М'яка пружина з невеликим перельотом (~6 %): 0 → 1.
func springEase(_ p: Double) -> Double {
    let p = clamp01(p)
    return p >= 1 ? 1 : 1 - exp(-7 * p) * cos(8 * p)
}

func easeOut(_ p: Double) -> Double { let q = 1 - clamp01(p); return 1 - q * q * q }

// MARK: - Стан

enum BarStyle: String, CaseIterable {
    case spectrum, tape, wave
    var title: String {
        switch self {
        case .spectrum: return "Спектр"
        case .tape: return "Стрічка"
        case .wave: return "Хвиля"
        }
    }
    var recordingWidth: CGFloat { 252 }
}

enum BarTint { case success, warning, neutral, accent }

enum BarState: Equatable {
    case recording
    case transcribing
    case done(String)                                                    // підпис: «23 слова»
    case message(icon: String, tint: BarTint, title: String, detail: String?)
}

/// Гучність під час запису, згладжена двічі: «швидка» (для стовпчиків і хвилі) і «повільна» (для сяйва).
final class LevelHistory {
    let slot = 0.07
    private(set) var start = 0.0
    private(set) var slots: [Float] = []
    private var ts: [Double] = []
    private var fastV: [Float] = []
    private var slowV: [Float] = []
    private var lastT: Double?
    private var f: Float = 0
    private var s: Float = 0

    func reset(at t: Double) {
        start = t
        slots.removeAll(keepingCapacity: true)
        ts.removeAll(keepingCapacity: true)
        fastV.removeAll(keepingCapacity: true)
        slowV.removeAll(keepingCapacity: true)
        lastT = nil
        f = 0
        s = 0
    }

    func add(_ v: Float, at t: Double) {
        let dt = lastT.map { min(0.2, max(0.001, t - $0)) } ?? 0.021
        lastT = t
        f += (v - f) * Float(1 - exp(-dt / (v > f ? 0.07 : 0.26)))
        s += (v - s) * Float(1 - exp(-dt / (v > s ? 0.25 : 0.7)))
        ts.append(t)
        fastV.append(f)
        slowV.append(s)
        if ts.count > 400, let first = ts.first, t - first > 3 {
            ts.removeFirst(100)
            fastV.removeFirst(100)
            slowV.removeFirst(100)
        }
        let k = Int((t - start) / slot)
        if k >= 0 {
            if k >= slots.count { slots.append(contentsOf: repeatElement(0, count: k - slots.count + 1)) }
            slots[k] = max(slots[k], f)
        }
    }

    func slotLevel(_ k: Int) -> Float { k >= 0 && k < slots.count ? slots[k] : 0 }

    /// Плавна гучність у момент t (на 30 мс позаду, щоб завжди було між якими відліками тягнути лінію).
    func fast(at t: Double) -> Float { value(fastV, at: t - 0.03) }
    func slow(at t: Double) -> Float { value(slowV, at: t - 0.03) }

    private func value(_ arr: [Float], at t: Double) -> Float {
        guard let lastT = ts.last, let lastV = arr.last else { return 0 }
        if t >= lastT {
            let gap = t - lastT                       // нових відліків нема — плавно гасимо
            return gap < 0.12 ? lastV : lastV * Float(exp(-(gap - 0.12) / 0.3))
        }
        if t <= ts[0] { return arr[0] }
        var lo = 0, hi = ts.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if ts[mid] <= t { lo = mid } else { hi = mid }
        }
        let k = Float((t - ts[lo]) / max(1e-6, ts[hi] - ts[lo]))
        return arr[lo] + (arr[hi] - arr[lo]) * k
    }

    /// Початки гучних складів (для кіл «Пульсу»): не частіше ніж раз на 0,45 с.
    func onsets(at t: Double, threshold: Float = 0.5, gap: Double = 0.45, life: Double = 1.4) -> [Double] {
        var out: [Double] = []
        var last = -Double.infinity
        var prev: Float = 0
        for i in ts.indices {
            let ti = ts[i]
            if ti > t { break }
            let v = fastV[i]
            if v >= threshold && prev < threshold && ti - last >= gap {
                if t - ti <= life { out.append(ti) }
                last = ti
            }
            prev = v
        }
        return out
    }
}

final class BarModel: ObservableObject {
    /// Анімація йде, лише поки смужку видно.
    @Published var running = false
    var style: BarStyle = .tape
    private(set) var state: BarState = .recording
    private(set) var stateAt = 0.0
    private(set) var shownAt = -10.0
    private(set) var hideAt: Double?
    private var wFrom: CGFloat = 200, wTo: CGFloat = 200, wAt = 0.0
    var recStart = 0.0
    let levels = LevelHistory()
    let spectrum = SpectrumTape()

    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let detailFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    func set(_ s: BarState, at t: Double, appearing: Bool) {
        let target = Self.width(for: s, style: style)
        if appearing {
            shownAt = t
            hideAt = nil
            wFrom = target * 0.5
        } else {
            wFrom = width(at: t)
        }
        wTo = target
        wAt = t
        state = s
        stateAt = t
    }

    func startHide(at t: Double) { if hideAt == nil { hideAt = t } }
    var hiding: Bool { hideAt != nil }

    func width(at t: Double) -> CGFloat { wFrom + (wTo - wFrom) * CGFloat(springEase((t - wAt) / 0.5)) }

    static func textWidth(_ s: String, _ f: NSFont) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    static func width(for s: BarState, style: BarStyle) -> CGFloat {
        switch s {
        case .recording: return style.recordingWidth
        case .transcribing: return 168
        case .done(let d):
            let w = 44 + textWidth("Вставлено", titleFont) + (d.isEmpty ? 0 : 5 + textWidth("· " + d, detailFont)) + 18
            return min(420, max(150, w))
        case .message(_, _, let title, let detail):
            let w = 42 + textWidth(title, titleFont) + (detail.map { 5 + textWidth("· " + $0, detailFont) } ?? 0) + 18
            return min(420, max(130, w))
        }
    }

    /// Поява (пружина знизу), зникнення (стискання вниз), «ні-ні» для помилки.
    func look(at t: Double) -> (scale: CGFloat, alpha: Double, dx: CGFloat, dy: CGFloat) {
        let a = t - shownAt
        var scale = 0.62 + 0.38 * CGFloat(springEase(a / 0.5))
        var alpha = clamp01(a / 0.14)
        var dy = 12 * CGFloat(1 - easeOut(a / 0.4))
        if let h = hideAt {
            let q = clamp01((t - h) / 0.22)
            scale *= 1 - 0.14 * CGFloat(q)
            alpha *= 1 - q
            dy += 10 * CGFloat(q)
        }
        var dx: CGFloat = 0
        if case .message(_, .warning, _, _) = state {
            let s = t - stateAt
            dx = CGFloat(sin(s * 46) * 6.5 * max(0, 1 - s / 0.5))
        }
        return (scale, alpha, dx, dy)
    }
}

// MARK: - Малювання

let barPanelSize = CGSize(width: 460, height: 96)
private let capsuleH: CGFloat = 40
private let capsuleBottom: CGFloat = 24        // від низу панелі до низу капсули

struct BarFrame: View {
    let model: BarModel
    let t: Double

    var body: some View {
        let look = model.look(at: t)
        Canvas { ctx, size in
            BarPainter(m: model, t: t, size: size).paint(&ctx)
        }
        .frame(width: barPanelSize.width, height: barPanelSize.height)
        .scaleEffect(look.scale, anchor: UnitPoint(x: 0.5, y: (barPanelSize.height - capsuleBottom - capsuleH / 2) / barPanelSize.height))
        .offset(x: look.dx, y: look.dy)
        .opacity(look.alpha)
    }
}

struct BarView: View {
    @ObservedObject var model: BarModel

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !model.running)) { _ in
            BarFrame(model: model, t: monoNow())
        }
        .frame(width: barPanelSize.width, height: barPanelSize.height)
    }
}

private struct BarPainter {
    let m: BarModel
    let t: Double
    let size: CGSize

    func paint(_ ctx: inout GraphicsContext) {
        let w = m.width(at: t), H = capsuleH
        ctx.translateBy(x: size.width / 2, y: size.height - capsuleBottom - H / 2)
        let r = CGRect(x: -w / 2, y: -H / 2, width: w, height: H)
        let shape = Path(roundedRect: r, cornerRadius: H / 2)

        var sh = ctx
        sh.addFilter(.shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 7))
        sh.fill(shape, with: .color(Palette.smoke.color))
        ctx.fill(shape, with: .linearGradient(Gradient(colors: [Palette.smoke.color, Palette.deck.color]),
                                              startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
        var inner = ctx
        inner.clip(to: shape)
        backGlow(&inner, r)
        inner.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: H * 0.5)),
                   with: .linearGradient(Gradient(colors: [Palette.paper.color.opacity(0.08), Palette.paper.color.opacity(0)]),
                                         startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: 0)))
        let border = Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: H / 2 - 0.5)
        ctx.stroke(border, with: .color(Palette.paper.color.opacity(0.11)), lineWidth: 1)
        if case .transcribing = m.state { sweep(&ctx, border, r) }

        var c = ctx
        let k = clamp01((t - m.stateAt) / 0.22)
        c.opacity = k
        c.translateBy(x: 0, y: CGFloat(1 - k) * 3)
        content(&c, r, clip: shape)
    }

    // тепле сяйво всередині капсули — від повільної гучності, тож воно «дихає», а не блимає
    private func backGlow(_ c: inout GraphicsContext, _ r: CGRect) {
        var g = c
        g.addFilter(.blur(radius: 13))
        switch m.state {
        case .recording:
            g.opacity = 0.12 + 0.5 * Double(m.levels.slow(at: t))
            g.fill(Path(ellipseIn: CGRect(x: r.minX + r.width * 0.06, y: r.maxY - 12, width: r.width * 0.88, height: 26)),
                   with: .linearGradient(Gradient(colors: [Palette.ember.color, Palette.amber.color, Palette.filament.color]),
                                         startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
        case .transcribing:
            let cx = r.midX + CGFloat(sin(t * 2.2)) * r.width * 0.33
            g.opacity = 0.42
            g.fill(Path(ellipseIn: CGRect(x: cx - 40, y: -18, width: 80, height: 36)), with: .color(Palette.amber.color))
        case .done:
            g.opacity = 0.22 + 0.5 * exp(-(t - m.stateAt) / 0.5)
            g.fill(Path(ellipseIn: CGRect(x: r.minX - 10, y: -22, width: 90, height: 44)), with: .color(Palette.amber.color))
        case .message(_, let tint, _, _):
            guard tint == .warning || tint == .success else { return }
            g.opacity = 0.4
            g.fill(Path(ellipseIn: CGRect(x: r.minX - 10, y: -22, width: 90, height: 44)),
                   with: .color((tint == .warning ? Palette.signal : Palette.amber).color))
        }
    }

    // світло біжить по краю капсули, поки розпізнаємо
    private func sweep(_ c: inout GraphicsContext, _ border: Path, _ r: CGRect) {
        let u = (t * 0.75).truncatingRemainder(dividingBy: 1)
        let cx = r.minX - 60 + CGFloat(u) * (r.width + 120)
        let g = Gradient(stops: [.init(color: .clear, location: 0),
                                 .init(color: Palette.filament.color.opacity(0.95), location: 0.5),
                                 .init(color: .clear, location: 1)])
        c.stroke(border, with: .linearGradient(g, startPoint: CGPoint(x: cx - 55, y: 0), endPoint: CGPoint(x: cx + 55, y: 0)),
                 lineWidth: 1.6)
    }

    private func content(_ c: inout GraphicsContext, _ r: CGRect, clip: Path) {
        switch m.state {
        case .recording:
            switch m.style {
            case .spectrum:
                var sp = c
                sp.clip(to: clip)
                spectrumTape(&sp, x0: r.minX, x1: r.maxX - 52)
            case .tape:
                tape(&c, x0: r.minX + 18, x1: r.maxX - 52)
            case .wave:
                wave(&c, x0: r.minX + 20, x1: r.maxX - 54)
            }
            timer(&c, CGPoint(x: r.maxX - 16, y: 0), anchor: .trailing)
        case .transcribing:
            loader(&c, x0: r.minX + 19)
            let dots = String(repeating: ".", count: Int(t * 2.6) % 4)
            c.draw(Text("Розпізнаю" + dots).font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.paper.color),
                   at: CGPoint(x: r.minX + 52, y: 0), anchor: .leading)
        case .done(let detail):
            check(&c, CGPoint(x: r.minX + 25, y: 0))
            titleDetail(&c, "Вставлено", detail.isEmpty ? nil : detail, x: r.minX + 44)
        case .message(let icon, let tint, let title, let detail):
            c.draw(Text(Image(systemName: icon)).font(.system(size: 13, weight: .bold)).foregroundColor(tintColor(tint)),
                   at: CGPoint(x: r.minX + 24, y: 0), anchor: .center)
            titleDetail(&c, title, detail, x: r.minX + 42)
        }
    }

    private func tintColor(_ t: BarTint) -> Color {
        switch t {
        case .success: return Palette.amber.color
        case .warning: return Palette.signal.color
        case .neutral: return Palette.ash.color
        case .accent: return Palette.filament.color
        }
    }

    private func titleDetail(_ c: inout GraphicsContext, _ title: String, _ detail: String?, x: CGFloat) {
        let tt = c.resolve(Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.paper.color))
        c.draw(tt, at: CGPoint(x: x, y: 0), anchor: .leading)
        guard let d = detail else { return }
        let w = tt.measure(in: CGSize(width: 1000, height: 100)).width
        c.draw(Text("· " + d).font(.system(size: 13)).foregroundColor(Palette.ash.color),
               at: CGPoint(x: x + w + 5, y: 0), anchor: .leading)
    }

    private func timer(_ c: inout GraphicsContext, _ p: CGPoint, anchor: UnitPoint) {
        c.draw(Text(clock(t - m.recStart)).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                .foregroundColor(Palette.ash.color), at: p, anchor: anchor)
    }

    // «Спектр»: стрічка спектра голосу, як у звуковому редакторі (угорі високі частоти, яскравіше — гучніше).
    // Праворуч світиться «головка запису», де звук входить у стрічку; ліворуч стрічка м'яко гасне.
    private func spectrumTape(_ c: inout GraphicsContext, x0: CGFloat, x1: CGFloat) {
        let tape = m.spectrum
        let h = capsuleH - 10
        let colW: CGFloat = 1.8
        let width = CGFloat(SpectrumTape.columns) * colW
        if let img = tape.image {
            // новий стовпчик в'їжджає плавно, а не стрибком
            let lag = tape.lastT > 0 ? CGFloat(clamp01((t - tape.lastT) / tape.period)) : 1
            let right = x1 + colW - lag * colW
            let rect = CGRect(x: right - width, y: -h / 2, width: width, height: h)
            c.drawLayer { l in
                l.draw(Image(decorative: img, scale: 1).interpolation(.high), in: rect)
                l.blendMode = .destinationOut
                l.fill(Path(CGRect(x: x0, y: -h / 2 - 1, width: 64, height: h + 2)),
                       with: .linearGradient(Gradient(colors: [.black, .clear]),
                                             startPoint: CGPoint(x: x0 + 8, y: 0), endPoint: CGPoint(x: x0 + 64, y: 0)))
                l.fill(Path(CGRect(x: x1, y: -h / 2 - 1, width: 40, height: h + 2)), with: .color(.black))
            }
        }
        // головка запису
        let e = Double(m.levels.fast(at: t))
        var g = c
        g.addFilter(.blur(radius: 3))
        g.fill(Path(roundedRect: CGRect(x: x1 - 1.5, y: -h / 2 + 2, width: 3, height: h - 4), cornerRadius: 1.5),
               with: .color(Palette.amber.color.opacity(0.3 + 0.55 * e)))
        c.fill(Path(roundedRect: CGRect(x: x1 - 0.75, y: -h / 2 + 4, width: 1.5, height: h - 8), cornerRadius: 0.75),
               with: .color(Palette.filament.color.opacity(0.5 + 0.5 * e)))
    }

    // «Стрічка»: пагорби голосу (плавна гучність за кожні 70 мс), найсвіжіше праворуч, пливе рівно
    private func tape(_ c: inout GraphicsContext, x0: CGFloat, x1: CGFloat) {
        let lv = m.levels
        let step: CGFloat = 5.5, bw: CGFloat = 3, maxH = capsuleH - 14, minH: CGFloat = 3
        let pos = max(0, (t - 0.03 - m.recStart) / lv.slot)
        let kNow = Int(pos.rounded(.down)), frac = CGFloat(pos - pos.rounded(.down))
        let n = Int((x1 - x0) / step) + 2
        for i in 0..<n {
            let x = x1 - bw - (CGFloat(i) + frac) * step
            if x < x0 - bw { break }
            let raw = Double(i == 0 ? lv.fast(at: t) : lv.slotLevel(kNow - i))
            let v = clamp01((raw - 0.18) / 0.72)                  // більше контрасту: тихе — низько, голос — пагорби
            let h = minH + (maxH - minH) * CGFloat(pow(v, 1.1))
            let u = Double((x - x0) / (x1 - x0))
            let a = (0.34 + 0.66 * u) * clamp01(Double((x - x0) / 26))
            let col = glow(0.12 + 0.88 * v).color
            let rect = CGRect(x: x, y: -h / 2, width: bw, height: h)
            c.fill(Path(roundedRect: rect, cornerRadius: bw / 2),
                   with: .linearGradient(Gradient(colors: [col.opacity(a * 0.45), col.opacity(a), col.opacity(a * 0.45)]),
                                         startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
        }
    }

    // «Хвиля»: три лінії, амплітуда від плавної гучності, кінці притиснуті
    private func wave(_ c: inout GraphicsContext, x0: CGFloat, x1: CGFloat) {
        let e = CGFloat(0.5 * m.levels.fast(at: t) + 0.5 * m.levels.slow(at: t))
        let amp = (0.12 + 0.88 * e) * capsuleH * 0.3
        let lines: [(RGB, CGFloat, Double, Double)] = [(Palette.ember, 0.95, 1.6, 2.6), (Palette.amber, 0.75, 2.3, -2.0),
                                                       (Palette.filament, 0.6, 1.1, 3.4)]
        for (col, a, f, sp) in lines {
            var p = Path()
            var x = x0
            while x <= x1 {
                let u = Double((x - x0) / (x1 - x0))
                let y = CGFloat(sin(u * .pi * 2 * f + t * sp) * sin(.pi * u)) * amp * a
                if x == x0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                x += 1.5
            }
            var g = c
            g.addFilter(.blur(radius: 2.5))
            g.stroke(p, with: .color(col.color.opacity(0.5)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            c.stroke(p, with: .color(col.color.opacity(0.95)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
        }
    }

    // розпізнаю: п'ять стовпчиків біжать хвилею
    private func loader(_ c: inout GraphicsContext, x0: CGFloat) {
        for i in 0..<5 {
            let h = 4 + 12 * CGFloat(0.5 + 0.5 * sin(t * 6.5 - Double(i) * 0.75))
            let x = x0 + CGFloat(i) * 5.5
            c.fill(Path(roundedRect: CGRect(x: x, y: -h / 2, width: 2.8, height: h), cornerRadius: 1.4),
                   with: .color(glow(0.2 + 0.2 * Double(i)).color.opacity(0.95)))
        }
    }

    // галочка малюється сама за 0,32 с
    private func check(_ c: inout GraphicsContext, _ p: CGPoint) {
        c.fill(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)), with: .color(Palette.amber.color.opacity(0.2)))
        var path = Path()
        path.move(to: CGPoint(x: p.x - 4.6, y: p.y + 0.4))
        path.addLine(to: CGPoint(x: p.x - 1.3, y: p.y + 3.7))
        path.addLine(to: CGPoint(x: p.x + 4.8, y: p.y - 3.5))
        let q = easeOut((t - m.stateAt) / 0.32)
        c.stroke(path.trimmedPath(from: 0, to: q), with: .color(Palette.filament.color),
                 style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Панель на екрані

/// Панель, яка ніколи не стає ключовою і не забирає курсор.
private final class PassivePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BarController {
    let model = BarModel()
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?
    private var outWork: DispatchWorkItem?

    init() {
        panel = PassivePanel(contentRect: NSRect(origin: .zero, size: barPanelSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: BarView(model: model))
        host.frame = NSRect(origin: .zero, size: barPanelSize)
        panel.contentView = host
    }

    var windowNumber: Int { panel.windowNumber }
    var frame: NSRect { panel.frame }

    func beginRecording() {
        model.recStart = monoNow()
        model.levels.reset(at: model.recStart)
        model.spectrum.reset()
    }

    func level(_ v: Float, at t: Double, bands: [Float]? = nil) {
        model.levels.add(v, at: t)
        if let b = bands { model.spectrum.add(b, at: t) }
    }

    func show(_ s: BarState, hideAfter: Double? = nil) {
        hideWork?.cancel(); hideWork = nil
        outWork?.cancel(); outWork = nil
        let now = monoNow()
        let appearing = !panel.isVisible || model.hiding
        if appearing && !panel.isVisible { position() }
        model.set(s, at: now, appearing: appearing)
        model.running = true
        panel.orderFrontRegardless()
        if let t = hideAfter {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
        }
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        guard panel.isVisible, !model.hiding else { return }
        model.startHide(at: monoNow())
        let w = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.model.running = false
        }
        outWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: w)
    }

    private func position() {
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        panel.setFrame(NSRect(x: (vf.midX - barPanelSize.width / 2).rounded(), y: vf.minY,
                              width: barPanelSize.width, height: barPanelSize.height), display: false)
    }
}
