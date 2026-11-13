// Тиша і «вигадані» фрази. На тиші розпізнавачі інколи пишуть те, що найчастіше чули в навчальних відео:
// «Дякую за перегляд», «Спасибо за просмотр», «Thanks for watching»… Тут два захисти:
//  1) голосу в записі майже нема (не рахуючи звуку старту на початку) — запис не відправляємо зовсім;
//  2) у тексті є така фраза, а там, де вона нібито прозвучала, у звуці тиша — фразу викидаємо.
//     Справді сказане вголос лишається: там у звуці є голос.
import Foundation

/// Де в записі є голос: гучність кадрів по 20 мс і поріг відносно фонового шуму.
struct VoiceActivity {
    static let frame = 0.02
    private let rms: [Float]
    private let threshold: Float
    private let ignoreUntil: Double

    /// `ignoreFirst` — скільки секунд на початку не рахувати голосом (там грає звук старту).
    init(samples: [Int16], ignoreFirst: Double) {
        let w = Int(Double(wavRate) * VoiceActivity.frame)
        var r: [Float] = []
        r.reserveCapacity(samples.count / w + 1)
        var i = 0
        while i + w <= samples.count {
            var sum: Float = 0
            for j in i..<(i + w) {
                let v = Float(samples[j]) / 32768
                sum += v * v
            }
            r.append(sqrt(sum / Float(w)))
            i += w
        }
        rms = r
        let sorted = r.sorted()
        let floor = sorted.isEmpty ? 0 : sorted[sorted.count / 10]
        threshold = min(max(floor * 4, 0.005), 0.03)          // +12 дБ над шумом, але між −46 і −30 дБ
        ignoreUntil = ignoreFirst
    }

    init?(wavFile: String, ignoreFirst: Double) {
        guard let d = FileManager.default.contents(atPath: wavFile), d.count > 44 else { return nil }
        let n = (d.count - 44) / 2
        var s = [Int16](repeating: 0, count: n)
        d.withUnsafeBytes { raw in
            for i in 0..<n { s[i] = raw.loadUnaligned(fromByteOffset: 44 + 2 * i, as: Int16.self) }
        }
        self.init(samples: s, ignoreFirst: ignoreFirst)
    }

    var duration: Double { Double(rms.count) * VoiceActivity.frame }

    /// Скільки секунд голосу між t0 і t1.
    func voiced(_ t0: Double = 0, _ t1: Double = .infinity) -> Double {
        let a = max(0, Int((max(t0, ignoreUntil) / VoiceActivity.frame).rounded(.down)))
        let b = min(rms.count, Int((min(t1, duration) / VoiceActivity.frame).rounded(.up)))
        guard a < b else { return 0 }
        var n = 0
        for i in a..<b where rms[i] > threshold { n += 1 }
        return Double(n) * VoiceActivity.frame
    }

    /// Частка голосу в проміжку (0…1).
    func voicedShare(_ t0: Double, _ t1: Double) -> Double {
        voiced(t0, t1) / max(VoiceActivity.frame, t1 - t0)
    }
}

enum Hallucinations {
    /// Фрази, які розпізнавачі «чують» у тиші (з навчальних відео й субтитрів).
    static let phrases: [String] = [
        "дякую за перегляд", "дякуємо за перегляд", "дякую за увагу", "дякуємо за увагу",
        "дякую що дивилися", "дякую що подивилися", "дякую за те що дивилися",
        "підписуйтесь на канал", "підписуйтеся на канал", "ставте лайки", "до нових зустрічей", "до зустрічі",
        "продовження буде", "продовження далі", "субтитри створено спільнотою", "субтитри зроблені спільнотою amara org",
        "спасибо за просмотр", "спасибо за внимание", "подписывайтесь на канал", "продолжение следует",
        "до новых встреч", "субтитры сделал", "субтитры создавал", "редактор субтитров",
        "thank you for watching", "thanks for watching", "please subscribe", "subscribe to the channel",
        "subtitles by the amara org community",
    ]
    private static let tokenized: [[String]] = phrases.map { tokens($0) }.sorted { $0.count > $1.count }

    static func norm(_ w: String) -> String {
        String(w.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map { norm(String($0)) }.filter { !$0.isEmpty }
    }

    /// Прибирає вигадані фрази, що припали на тишу. Повертає текст і скільки слів прибрано.
    static func clean(_ text: String, words: [Word], vad: VoiceActivity?) -> (text: String, removed: Int) {
        guard let vad else { return (text, 0) }
        if words.isEmpty {                                    // без міток часу — лише весь текст цілком
            let whole = tokens(text)
            return tokenized.contains(whole) && vad.voiced() < 1.0 ? ("", whole.count) : (text, 0)
        }
        let n = words.map { norm($0.text) }
        var keep = [Bool](repeating: true, count: words.count)
        var removed = 0
        for p in tokenized {
            var i = 0
            while i + p.count <= n.count {
                if keep[i], Array(n[i..<(i + p.count)]) == p {
                    if vad.voicedShare(words[i].start, words[i + p.count - 1].end) < 0.3 {
                        for j in i..<(i + p.count) { keep[j] = false }
                        removed += p.count
                    }
                    i += p.count
                } else {
                    i += 1
                }
            }
        }
        guard removed > 0 else { return (text, 0) }
        let rest = zip(words, keep).filter { $0.1 }.map { $0.0.text }.joined(separator: " ")
        return (rest.trimmingCharacters(in: .whitespacesAndNewlines), removed)
    }
}
