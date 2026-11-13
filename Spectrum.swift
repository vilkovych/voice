// Спектр голосу для смужки «Спектр»: 28 смуг від 100 Гц до 7 кГц (фільтри-«резонатори», логарифмічний крок)
// і стрічка-картинка, де кожен шматок звуку — стовпчик пікселів, яскравість — сила звуку на цій висоті.
// Як спектральний вигляд у звукових редакторах: видно інтонацію, гармоніки голосних, шиплячі вгорі.
import CoreGraphics
import Foundation

struct SpectrumAnalyzer {
    static let bands = 28
    static let centers: [Double] = (0..<bands).map { 100 * pow(70, Double($0) / Double(bands - 1)) }
    /// дБ → 0…1 (підібрано на записах юзера; див. Voice --spectrum-calibrate)
    static var floorDB: Float = -55
    static var rangeDB: Float = 36

    private var b0: [Float] = [], a1: [Float] = [], a2: [Float] = []
    private var x1: [Float], x2: [Float], y1: [Float], y2: [Float]
    private let tilt: [Float]

    init(rate: Double = Double(wavRate), q: Double = 5.5) {
        for fc in Self.centers {
            let w0 = 2 * Double.pi * fc / rate, alpha = sin(w0) / (2 * q), a0 = 1 + alpha
            b0.append(Float(alpha / a0))
            a1.append(Float(-2 * cos(w0) / a0))
            a2.append(Float((1 - alpha) / a0))
        }
        x1 = [Float](repeating: 0, count: Self.bands)
        x2 = x1; y1 = x1; y2 = x1
        // мова тихішає з висотою — трохи піднімаємо верх, щоб шиплячі було видно
        tilt = Self.centers.map { Float(4 * log2($0 / 250)) }
    }

    /// Енергія кожної смуги за шматок звуку, дБ (з нахилом).
    mutating func energies(_ p: UnsafeBufferPointer<Int16>) -> [Float] {
        var out = [Float](repeating: 0, count: Self.bands)
        guard p.count > 0 else { return out }
        for b in 0..<Self.bands {
            let k0 = b0[b], k1 = a1[b], k2 = a2[b]
            var sx1 = x1[b], sx2 = x2[b], sy1 = y1[b], sy2 = y2[b], sum: Float = 0
            for s in p {
                let x = Float(s) / 32768
                let y = k0 * (x - sx2) - k1 * sy1 - k2 * sy2
                sx2 = sx1; sx1 = x; sy2 = sy1; sy1 = y
                sum += y * y
            }
            x1[b] = sx1; x2[b] = sx2; y1[b] = sy1; y2[b] = sy2
            out[b] = 10 * log10(sum / Float(p.count) + 1e-12) + tilt[b]
        }
        return out
    }

    /// Те саме, але вже 0…1 для малювання.
    mutating func levels(_ p: UnsafeBufferPointer<Int16>) -> [Float] {
        energies(p).map { min(1, max(0, ($0 - Self.floorDB) / Self.rangeDB)) }
    }
}

/// Стрічка спектра: картинка 120 стовпчиків × 28 рядків; новий стовпчик дописується праворуч, решта зсувається.
final class SpectrumTape {
    static let columns = 120
    private let rows = SpectrumAnalyzer.bands
    private var px: [UInt8]
    private var prev: [Float]
    private(set) var lastT = 0.0
    private(set) var period = 0.0213              // середній проміжок між стовпчиками
    private(set) var image: CGImage?

    init() {
        px = [UInt8](repeating: 0, count: Self.columns * SpectrumAnalyzer.bands * 4)
        prev = [Float](repeating: 0, count: SpectrumAnalyzer.bands)
    }

    func reset() {
        for i in px.indices { px[i] = 0 }
        for i in prev.indices { prev[i] = 0 }
        lastT = 0
        image = nil
    }

    func add(_ levels: [Float], at t: Double) {
        if lastT > 0 { period += (min(0.05, max(0.005, t - lastT)) - period) * 0.1 }
        lastT = t
        let w = Self.columns, stride = w * 4
        px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for r in 0..<rows {
                let row = base.advanced(by: r * stride)
                memmove(row, row.advanced(by: 4), stride - 4)
            }
        }
        for r in 0..<rows {
            let band = rows - 1 - r                                   // угорі — високі частоти
            let v = 0.65 * levels[band] + 0.35 * prev[band]           // легке згладження в часі
            prev[band] = levels[band]
            let (cr, cg, cb, ca) = Self.heat(Double(v))
            let i = r * stride + (w - 1) * 4
            px[i] = UInt8(cr * ca * 255); px[i + 1] = UInt8(cg * ca * 255); px[i + 2] = UInt8(cb * ca * 255); px[i + 3] = UInt8(ca * 255)
        }
        image = makeImage()
    }

    /// Тиша — прозоро; далі жар → бурштин → нитка → майже біле.
    static func heat(_ v: Double) -> (Double, Double, Double, Double) {
        let a = smooth(0.1, 0.45, v)
        let c: RGB
        if v < 0.5 {
            c = Palette.ember
        } else if v < 0.78 {
            c = Palette.ember.mix(Palette.amber, (v - 0.5) / 0.28)
        } else if v < 0.93 {
            c = Palette.amber.mix(Palette.filament, (v - 0.78) / 0.15)
        } else {
            c = Palette.filament.mix(RGB(1, 0.97, 0.92), (v - 0.93) / 0.07)
        }
        return (c.r, c.g, c.b, a)
    }

    private static func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }

    private func makeImage() -> CGImage? {
        let w = Self.columns
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: rows, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }
}

/// Відбиток усієї диктовки для панелі в смужці меню: спектр голосу від першого до останнього слова
/// (тишу на початку й наприкінці відрізано), стиснутий у `columns` стовпчиків, тими самими кольорами жару.
/// Яскравість підігнана під кожен запис (найгучніші 5 % клітинок — майже нитка), тихий шум не підсилюється;
/// легке згладження — щоб було м'яко, як у смужці, а не штрихкодом.
enum TakeSpectrum {
    static let columns = 168

    static func image(_ path: String) -> CGImage? {
        guard let d = FileManager.default.contents(atPath: path), d.count > 44 + 6400 else { return nil }
        let total = (d.count - 44) / 2
        let skip = total > wavRate * 3 / 2 ? wavRate / 4 : 0          // перші 0,25 с — звук старту, не голос
        let hop = wavRate / 100                                        // кадр 10 мс
        let frames = (total - skip) / hop
        guard frames >= 30 else { return nil }
        var samples = [Int16](repeating: 0, count: frames * hop)
        let from = 44 + skip * 2
        samples.withUnsafeMutableBufferPointer { d.copyBytes(to: $0, from: from..<(from + frames * hop * 2)) }
        var an = SpectrumAnalyzer()
        var fine: [[Float]] = []
        fine.reserveCapacity(frames)
        samples.withUnsafeBufferPointer { p in
            for f in 0..<frames {
                fine.append(an.energies(UnsafeBufferPointer(rebasing: p[(f * hop)..<((f + 1) * hop)])))
            }
        }
        let range = SpectrumAnalyzer.rangeDB
        func floorFor(_ cells: [Float]) -> Float {
            let s = cells.sorted()
            return max(SpectrumAnalyzer.floorDB - 8, s[Int(Double(s.count - 1) * 0.95)] - 0.8 * range)
        }
        // де голос: кадри, у яких хоч одна смуга помітно світиться
        let f0 = floorFor(fine.flatMap { $0 })
        let voiced = fine.map { ($0.max() ?? -200) - f0 >= 0.35 * range }
        var first = voiced.firstIndex(of: true) ?? 0
        var last = voiced.lastIndex(of: true) ?? frames - 1
        first = max(0, first - 15)
        last = min(frames - 1, last + 15)
        // стиснути (або розтягнути) голосну частину до `columns` стовпчиків
        let cols = columns, rows = SpectrumAnalyzer.bands
        let span = Double(last - first + 1)
        var db = [[Float]](repeating: [Float](repeating: -200, count: rows), count: cols)
        for c in 0..<cols {
            let a = Double(first) + Double(c) * span / Double(cols)
            let b = Double(first) + Double(c + 1) * span / Double(cols)
            if b - a >= 1 {
                let i0 = Int(a), i1 = max(i0 + 1, min(last + 1, Int(b.rounded(.up))))
                for band in 0..<rows {
                    var pw: Float = 0
                    for i in i0..<i1 { pw += pow(10, fine[i][band] / 10) }
                    db[c][band] = 10 * log10(pw / Float(i1 - i0) + 1e-12)
                }
            } else {
                let m = (a + b) / 2 - 0.5
                let i0 = max(first, min(last, Int(m.rounded(.down)))), i1 = min(last, i0 + 1)
                let t = Float(max(0, min(1, m - Double(i0))))
                for band in 0..<rows { db[c][band] = fine[i0][band] * (1 - t) + fine[i1][band] * t }
            }
        }
        let fl = floorFor(db.flatMap { $0 })
        var v = db.map { col in col.map { min(1, max(0, ($0 - fl) / range)) } }
        // згладити: у часі [¼ ½ ¼], по висоті [⅕ ⅗ ⅕]
        var s = v
        for c in 0..<cols {
            for r in 0..<rows {
                let l = v[max(0, c - 1)][r], m = v[c][r], rr = v[min(cols - 1, c + 1)][r]
                s[c][r] = 0.25 * l + 0.5 * m + 0.25 * rr
            }
        }
        for c in 0..<cols {
            for r in 0..<rows {
                v[c][r] = 0.2 * s[c][max(0, r - 1)] + 0.6 * s[c][r] + 0.2 * s[c][min(rows - 1, r + 1)]
            }
        }
        var px = [UInt8](repeating: 0, count: cols * rows * 4)
        for c in 0..<cols {
            for r in 0..<rows {
                let (cr, cg, cb, ca) = SpectrumTape.heat(Double(v[c][rows - 1 - r]))  // угорі — високі частоти
                let i = (r * cols + c) * 4
                px[i] = UInt8(cr * ca * 255); px[i + 1] = UInt8(cg * ca * 255); px[i + 2] = UInt8(cb * ca * 255); px[i + 3] = UInt8(ca * 255)
            }
        }
        return px.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
    }
}
