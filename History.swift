// Історія диктовок. Кожна диктовка — запис у history.jsonl; при кожній зміні дописується новий рядок
// з тим самим id (чинний — останній). Звук кожної диктовки лежить в audio/<id>.wav.
// Старі рядки (до історії) читаються теж: у них немає id і status — їх виводимо з файлу і помилки.
import AppKit

enum EntryStatus: String {
    case recording      // іде запис (якщо програма впала — при старті стане failed)
    case transcribing   // розпізнається
    case pasted         // вставлено під курсор
    case copied         // лише в буфері (вставити не вийшло) або розпізнано повтором на прохання
    case ready          // розпізнано пізніше, само (після збою) — текст тільки в історії
    case failed         // не вдалося — звук збережено, можна повторити
    case empty          // розпізнано, але тиша
    case cancelled      // скасовано Esc — звук збережено
    case discarded      // коротше 0,3 с — не показуємо
}

struct Entry: Identifiable, Equatable {
    var id: String
    var ts: Date
    var status: EntryStatus
    var audioS: Double = 0
    var audioFile: String?
    var text: String?
    var error: String?
    var retryable = false
    var attempts = 0
    var appName: String?
    var appBundle: String?
    var totalMs: Int?
    var keyTail: String?
    var transcriptId: String?
    var updated = Date()

    init(id: String, ts: Date, status: EntryStatus) {
        self.id = id
        self.ts = ts
        self.status = status
    }

    var hasText: Bool { !(text ?? "").isEmpty }
    var words: Int { text.map(wordCount) ?? 0 }
    var hasAudio: Bool { audioFile.map { FileManager.default.fileExists(atPath: $0) } ?? false }
    var busy: Bool { status == .recording || status == .transcribing }

    func json() -> String {
        jobj([
            ("id", jstr(id)), ("ts", jstr(iso(ts))), ("status", jstr(status.rawValue)),
            ("audio_s", jnum(audioS, 2)), ("audio_file", jstr(audioFile)),
            ("text", jstr(text)), ("error", jstr(error)),
            ("retryable", jbool(retryable)), ("attempts", jint(attempts)),
            ("app_name", jstr(appName)), ("app_bundle", jstr(appBundle)),
            ("total_ms", jint(totalMs)), ("key_tail", jstr(keyTail)), ("transcript_id", jstr(transcriptId)),
            ("updated", jstr(iso(updated))),
        ])
    }

    init?(json o: [String: Any]) {
        guard let tsS = o["ts"] as? String, let ts = isoFormatter.date(from: tsS) else { return nil }
        let file = o["audio_file"] as? String
        let id = (o["id"] as? String)
            ?? file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
            ?? fileStamp.string(from: ts)
        let text = o["text"] as? String
        let err = o["error"] as? String
        let status: EntryStatus
        if let s = o["status"] as? String, let v = EntryStatus(rawValue: s) {
            status = v
        } else {                                                     // старий формат
            status = err != nil ? .failed : ((text ?? "").isEmpty ? .empty : .pasted)
        }
        self.init(id: id, ts: ts, status: status)
        audioS = (o["audio_s"] as? NSNumber)?.doubleValue ?? 0
        audioFile = file
        self.text = text
        error = err
        retryable = (o["retryable"] as? Bool) ?? false
        attempts = (o["attempts"] as? NSNumber)?.intValue ?? 0
        appBundle = (o["app_bundle"] as? String) ?? (o["front_app"] as? String)
        appName = (o["app_name"] as? String) ?? appBundle.flatMap(appDisplayName)
        totalMs = (o["total_ms"] as? NSNumber)?.intValue
        keyTail = o["key_tail"] as? String
        transcriptId = o["transcript_id"] as? String
        if let u = o["updated"] as? String, let d = isoFormatter.date(from: u) { updated = d } else { updated = ts }
    }
}

private var appNames: [String: String] = [:]

/// «com.apple.Terminal» → «Термінал» (як програма зветься у Finder).
func appDisplayName(_ bundle: String) -> String? {
    if let n = appNames[bundle] { return n }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
    var n = FileManager.default.displayName(atPath: url.path)
    if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
    appNames[bundle] = n
    return n
}

final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [Entry] = []      // нові зверху
    @Published private(set) var version = 0
    /// Для перевірки вигляду: нічого не пише на диск.
    var readOnly = false
    private var lineCount = 0

    func load() {
        guard let s = try? String(contentsOfFile: historyPath, encoding: .utf8) else { return }
        var byId: [String: Entry] = [:]
        var order: [String] = []
        var lines = 0
        for line in s.split(separator: "\n") {
            lines += 1
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let e = Entry(json: o) else { continue }
            if byId[e.id] == nil { order.append(e.id) }
            byId[e.id] = e
        }
        lineCount = lines
        entries = order.compactMap { byId[$0] }.sorted { $0.ts > $1.ts }
        version += 1
        if !readOnly && lineCount > entries.count * 2 + 50 { compact() }
    }

    /// Лише для --png: показати готовий набір без файлів.
    func preview(_ list: [Entry]) {
        readOnly = true
        entries = list.sorted { $0.ts > $1.ts }
        version += 1
    }

    func put(_ e: Entry) {
        var e = e
        e.updated = Date()
        if let i = entries.firstIndex(where: { $0.id == e.id }) {
            entries[i] = e
        } else {
            entries.insert(e, at: 0)
            entries.sort { $0.ts > $1.ts }
        }
        version += 1
        guard !readOnly else { return }
        appendLine(e.json(), to: historyPath)
        lineCount += 1
    }

    func update(_ id: String, _ change: (inout Entry) -> Void) {
        guard var e = entry(id) else { return }
        change(&e)
        put(e)
    }

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    var lastWithText: Entry? { entries.first { $0.hasText && $0.status != .discarded } }

    /// Переписує файл: по рядку на диктовку.
    private func compact() {
        let text = entries.reversed().map { $0.json() }.joined(separator: "\n") + "\n"
        let tmp = historyPath + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]),
              rename(tmp, historyPath) == 0 else { return }
        lineCount = entries.count
        log("історію ущільнено: \(entries.count) диктовок")
    }
}
