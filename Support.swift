// Спільне: шляхи, журнал, JSON, ключі, WAV, налаштування, дрібні формати.
import Foundation

let home = NSHomeDirectory()
let dataDir = home + "/Library/Application Support/Voice"
let keysPath = dataDir + "/keys.txt"
let historyPath = dataDir + "/history.jsonl"
let statePath = dataDir + "/state.json"
let settingsPath = dataDir + "/settings.json"
let audioDir = dataDir + "/audio"
let logPath = home + "/Library/Logs/Voice.log"

let wavRate = 16000                      // 16 кГц моно 16 біт

// MARK: - Час

func monoNow() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
func ms(since t: Double) -> Int { Int(((monoNow() - t) * 1000).rounded()) }

private func posixFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
}
let logStamp = posixFormatter("yyyy-MM-dd HH:mm:ss")
let fileStamp = posixFormatter("yyyyMMdd-HHmmss")
let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f
}()
func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

// MARK: - Дрібні формати

/// 19.94 → «19,9»
func ua1(_ v: Double) -> String { String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") }

/// 83.4 → «1:23»
func clock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// 1245 → «1 245» (з нерозривним пробілом)
func groupDigits(_ n: Int) -> String {
    let s = String(n)
    var out = ""
    for (i, ch) in s.enumerated() {
        if i > 0 && (s.count - i) % 3 == 0 { out.append("\u{00A0}") }
        out.append(ch)
    }
    return out
}

/// 1 слово, 2 слова, 5 слів, 11 слів, 21 слово.
func uaPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let m10 = n % 10, m100 = n % 100
    if m10 == 1 && m100 != 11 { return one }
    if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
    return many
}

func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }
func wordsText(_ n: Int) -> String { "\(groupDigits(n)) \(uaPlural(n, "слово", "слова", "слів"))" }

/// Перші n символів одним рядком, з «…», якщо обрізано.
func snippet(_ s: String?, _ n: Int) -> String {
    let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
    return t.count <= n ? t : String(t.prefix(n)).trimmingCharacters(in: .whitespaces) + "…"
}

// MARK: - Журнал (лише зміни стану й помилки; ні ключів, ні тексту)

private let logQueue = DispatchQueue(label: "voice.log")

func log(_ s: String) {
    logQueue.sync {
        let line = Data("\(logStamp.string(from: Date())) \(s)\n".utf8)
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: logPath))?[.size] as? NSNumber, size.intValue > 1_000_000 {
            try? fm.removeItem(atPath: logPath)
        }
        if let h = FileHandle(forWritingAtPath: logPath) {
            h.seekToEndOfFile()
            h.write(line)
            h.closeFile()
        } else {
            fm.createFile(atPath: logPath, contents: line)
        }
    }
}

// MARK: - JSON із заданим порядком полів

func jstr(_ s: String?) -> String {
    guard let s = s,
          let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
          let a = String(data: d, encoding: .utf8) else { return "null" }
    return String(a.dropFirst().dropLast())
}
func jint(_ v: Int?) -> String { v.map { String($0) } ?? "null" }
func jnum(_ v: Double?, _ digits: Int) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "null" }
func jbool(_ v: Bool) -> String { v ? "true" : "false" }
func jobj(_ pairs: [(String, String)], pretty: Bool = false) -> String {
    let items = pairs.map { "\(jstr($0.0)): \($0.1)" }
    return pretty ? "{\n  " + items.joined(separator: ",\n  ") + "\n}\n" : "{" + items.joined(separator: ", ") + "}"
}

func appendLine(_ line: String, to path: String) {
    let data = Data((line + "\n").utf8)
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(data)
        h.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

// MARK: - Ключі (у журналах і виводі — лише останні 6 символів)

func loadKeys() -> [String] {
    guard let s = try? String(contentsOfFile: keysPath, encoding: .utf8) else { return [] }
    return s.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

func keyTail(_ key: String) -> String { String(key.suffix(6)) }

/// Ключ останньої вдалої диктовки — з history.jsonl, щоб пам'ятати його і після перезапуску.
func lastGoodKeyTail() -> String? {
    guard let s = try? String(contentsOfFile: historyPath, encoding: .utf8) else { return nil }
    for line in s.split(separator: "\n").reversed() {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        if o["error"] is NSNull, let t = o["key_tail"] as? String, !t.isEmpty { return t }
    }
    return nil
}

func startIndex(_ keys: [String], lastGood: String?) -> Int {
    guard let t = lastGood else { return 0 }
    return keys.firstIndex { keyTail($0) == t } ?? 0
}

// MARK: - WAV

func le32(_ v: Int) -> Data { var x = UInt32(truncatingIfNeeded: v).littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }
func le16(_ v: Int) -> Data { var x = UInt16(truncatingIfNeeded: v).littleEndian; return withUnsafeBytes(of: &x) { Data($0) } }

/// Заголовок WAV PCM 16 біт моно (44 байти). Поки запис іде, розміри нульові — їх дописують у кінці.
func wavHeader(dataBytes: Int, rate: Int = wavRate) -> Data {
    var d = Data(capacity: 44)
    d.append(contentsOf: Array("RIFF".utf8)); d.append(le32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
    d.append(contentsOf: Array("fmt ".utf8)); d.append(le32(16)); d.append(le16(1)); d.append(le16(1))
    d.append(le32(rate)); d.append(le32(rate * 2)); d.append(le16(2)); d.append(le16(16))
    d.append(contentsOf: Array("data".utf8)); d.append(le32(dataBytes))
    return d
}

func makeWAV(_ samples: [Int16]) -> Data {
    var d = wavHeader(dataBytes: samples.count * 2)
    samples.withUnsafeBytes { d.append(contentsOf: $0) }
    return d
}

/// Файл, обірваний посеред запису (програма впала чи її вбили): розміри в заголовку беремо з довжини файлу.
/// Повертає секунди звуку.
@discardableResult
func repairWAV(_ path: String) -> Double? {
    guard let h = FileHandle(forUpdatingAtPath: path) else { return nil }
    defer { try? h.close() }
    guard let end = try? h.seekToEnd(), end >= 44 else { return nil }
    let dataBytes = (Int(end) - 44) & ~1
    do {
        try h.seek(toOffset: 4); try h.write(contentsOf: le32(36 + dataBytes))
        try h.seek(toOffset: 40); try h.write(contentsOf: le32(dataBytes))
    } catch { return nil }
    return Double(dataBytes) / Double(wavRate * 2)
}

/// Тривалість WAV за заголовком (fmt → byteRate, data → розмір).
func wavSeconds(_ d: Data) -> Double? {
    let b = [UInt8](d.prefix(1 << 16))
    func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
    guard b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return nil }
    var o = 12, byteRate = 0
    while o + 8 <= b.count {
        let id = String(decoding: b[o..<o + 4], as: UTF8.self)
        let size = u32(o + 4)
        if id == "fmt ", o + 20 <= b.count { byteRate = u32(o + 16) }
        if id == "data" {
            guard byteRate > 0 else { return nil }
            return Double(min(size, d.count - o - 8)) / Double(byteRate)
        }
        o += 8 + size + (size & 1)
    }
    return nil
}

// MARK: - Налаштування (settings.json)

/// RMS шматка → 0…1 для смужки: −52 дБ → 0, −12 дБ → 1.
func levelFromRMS(_ rms: Float) -> Float {
    let db = 20 * log10(max(Double(rms), 1e-6))
    return Float(min(1, max(0, (db + 52) / 40)))
}

struct Settings {
    var trigger = "rshift"     // див. TriggerKey
    var style = "spectrum"     // див. BarStyle
    var soundSet = "warm"      // див. SoundSet
    var soundVolume = 0.8      // 0…1

    static func load() -> Settings {
        var s = Settings()
        guard let d = FileManager.default.contents(atPath: settingsPath),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return s }
        if let v = o["trigger"] as? String { s.trigger = v }
        if let v = o["style"] as? String { s.style = v }
        if let v = o["sound_set"] as? String { s.soundSet = v } else if o["sounds"] as? Bool == false { s.soundSet = "off" }
        if let v = (o["sound_volume"] as? NSNumber)?.doubleValue { s.soundVolume = min(1, max(0, v)) }
        return s
    }

    func save() {
        let text = jobj([("trigger", jstr(trigger)), ("style", jstr(style)), ("sound_set", jstr(soundSet)),
                         ("sound_volume", jnum(soundVolume, 2))], pretty: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
    }
}
