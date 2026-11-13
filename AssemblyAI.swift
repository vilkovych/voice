// AssemblyAI: upload → transcript → опитування. Одна спільна URLSession — з'єднання не відкривається щоразу.
import Foundation

let apiBase = "https://api.assemblyai.com/v2"
let pollInterval: Double = 0.2
let pollGiveUp: Double = 120

let api: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 30
    c.waitsForConnectivity = false
    return URLSession(configuration: c)
}()

enum Failure {
    case noKeys, keysRejected, network(String), server(String), failed(String), timeout

    /// Коротко — для плашки.
    var reason: String {
        switch self {
        case .noKeys: return "Немає ключів"
        case .keysRejected: return "Ключі не працюють"
        case .network: return "Немає зв'язку"
        case .server: return "Помилка сервера"
        case .failed: return "Не вдалося розпізнати"
        case .timeout: return "Сервер не встиг"
        }
    }
    /// Чи є сенс повторити пізніше самому (зв'язок, сервер), чи потрібна людина (ключі, сам звук).
    var retryable: Bool {
        switch self {
        case .network, .server, .timeout: return true
        case .noKeys, .keysRejected, .failed: return false
        }
    }
    /// Подробиці — для журналу.
    var detail: String {
        switch self {
        case .noKeys: return "keys.txt порожній або його немає"
        case .keysRejected: return "усі ключі відхилено"
        case .network(let s), .server(let s), .failed(let s): return s
        case .timeout: return "немає результату за \(Int(pollGiveUp)) с"
        }
    }
}

/// Слово з мітками часу (секунди від початку запису).
struct Word {
    let text: String
    let start: Double
    let end: Double
}

struct Outcome {
    var text: String?            // є лише при успіху ("" — нічого не почуто)
    var failure: Failure?
    var uploadMs: Int?
    var createMs: Int?
    var waitMs: Int?
    var keyTail: String?
    var transcriptId: String?
    var words: [Word] = []
}

private enum StepError: Error {
    case keyRejected(String)                // 401/402/403 або «balance» → наступний ключ
    case transient(String, network: Bool)   // збій зв'язку або 5xx → увесь ланцюжок ще раз (один раз)
    case fatal(Failure)
}

/// Розпізнає WAV. Ключі — у порядку файлу, починаючи з `startAt` (останній, що спрацював).
func transcribe(_ wav: Data, keys: [String], startAt: Int, note: @escaping (String) -> Void) async -> Outcome {
    guard !keys.isEmpty else { return Outcome(failure: .noKeys) }
    var retried = false
    var tried = 0
    while tried < keys.count {
        let key = keys[(startAt + tried) % keys.count]
        var out = Outcome(keyTail: keyTail(key))
        do {
            try await pipeline(wav, key: key, out: &out)
            return out
        } catch StepError.keyRejected(let why) {
            note("ключ …\(keyTail(key)) не прийнято (\(why)) — беру наступний")
            tried += 1
        } catch StepError.transient(let why, let network) {
            if retried {
                out.failure = network ? .network(why) : .server(why)
                return out
            }
            retried = true
            note("збій (\(why)) — повторюю ще раз")
        } catch StepError.fatal(let f) {
            out.failure = f
            return out
        } catch {
            out.failure = .failed(error.localizedDescription)
            return out
        }
    }
    return Outcome(failure: .keysRejected)
}

private func pipeline(_ wav: Data, key: String, out: inout Outcome) async throws {
    var t = monoNow()
    var up = URLRequest(url: URL(string: apiBase + "/upload")!, timeoutInterval: 60)
    up.httpMethod = "POST"
    up.setValue(key, forHTTPHeaderField: "authorization")
    up.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
    let u = try await send(up, body: wav, key: key)
    out.uploadMs = ms(since: t)
    guard let audioURL = u["upload_url"] as? String else { throw StepError.fatal(.server("немає upload_url у відповіді")) }

    t = monoNow()
    var cr = URLRequest(url: URL(string: apiBase + "/transcript")!, timeoutInterval: 30)
    cr.httpMethod = "POST"
    cr.setValue(key, forHTTPHeaderField: "authorization")
    cr.setValue("application/json", forHTTPHeaderField: "content-type")
    let job: [String: Any] = ["audio_url": audioURL, "speech_models": ["universal-2"], "language_code": "uk"]
    let jobData = try JSONSerialization.data(withJSONObject: job)
    let c = try await send(cr, body: jobData, key: key)
    out.createMs = ms(since: t)
    guard let id = c["id"] as? String else { throw StepError.fatal(.server("немає id у відповіді")) }
    out.transcriptId = id

    t = monoNow()
    var pr = URLRequest(url: URL(string: apiBase + "/transcript/" + id)!, timeoutInterval: 30)
    pr.setValue(key, forHTTPHeaderField: "authorization")
    while true {
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1e9))
        let r = try await send(pr, body: nil, key: key)
        switch r["status"] as? String {
        case "completed":
            out.waitMs = ms(since: t)
            out.text = ((r["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            out.words = ((r["words"] as? [[String: Any]]) ?? []).compactMap { w in
                guard let text = w["text"] as? String,
                      let s = (w["start"] as? NSNumber)?.doubleValue,
                      let e = (w["end"] as? NSNumber)?.doubleValue else { return nil }
                return Word(text: text, start: s / 1000, end: e / 1000)
            }
            return
        case "error":
            out.waitMs = ms(since: t)
            let msg = (r["error"] as? String) ?? "невідома помилка"
            if msg.lowercased().contains("balance") { throw StepError.keyRejected(msg) }
            throw StepError.fatal(.failed(msg))
        default:
            if monoNow() - t > pollGiveUp {
                out.waitMs = ms(since: t)
                throw StepError.fatal(.timeout)
            }
        }
    }
}

private func send(_ req: URLRequest, body: Data?, key: String) async throws -> [String: Any] {
    let pair: (Data, URLResponse)
    do {
        if let body = body { pair = try await api.upload(for: req, from: body) }
        else { pair = try await api.data(for: req) }
    } catch {
        let n = error as NSError
        throw StepError.transient("\(n.domain) \(n.code): \(n.localizedDescription)", network: true)
    }
    let (data, resp) = pair
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200...299).contains(code) else {
        // ключ у тексті помилки не лишаємо — лише хвіст
        let text = String(decoding: data.prefix(600), as: UTF8.self)
            .replacingOccurrences(of: key, with: "…" + keyTail(key))
        if [401, 402, 403].contains(code) || text.lowercased().contains("balance") { throw StepError.keyRejected("HTTP \(code)") }
        if code >= 500 { throw StepError.transient("HTTP \(code)", network: false) }
        throw StepError.fatal(.server("HTTP \(code): \(text)"))
    }
    guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        throw StepError.fatal(.server("незрозуміла відповідь (HTTP \(code))"))
    }
    return o
}

// MARK: - Прогрів з'єднання

/// Запит без ключа: сервер відповість 401, але TLS-з'єднання лишається в спільній сесії для справжніх запитів.
private var warmRequest: URLRequest {
    URLRequest(url: URL(string: apiBase + "/transcript?limit=1")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
}

func warmConnection() { api.dataTask(with: warmRequest) { _, _, _ in }.resume() }

func warmConnectionAndWait() async { _ = try? await api.data(for: warmRequest) }
