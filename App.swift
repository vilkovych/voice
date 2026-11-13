// Voice у смужці меню: клавіші, запис → AssemblyAI → вставка, історія, захист записів, звуки.
//
// Захист записів: звук пишеться на диск із першої секунди; кожна диктовка одразу потрапляє в історію.
// Не розпізналось — запис лишається з кнопкою «Спробувати ще», а коли повернеться інтернет, Voice
// повторить сам. Впала програма посеред запису — при наступному запуску запис полагодиться і чекатиме в історії.
import AppKit
import AVFoundation
import ApplicationServices
import Network
import SwiftUI

let maxRecordingSeconds: Double = 600
let minRecordingSeconds: Double = 0.3
let warmEverySeconds: Double = 25
let keepAudioDays: Double = 14        // звук вдалих диктовок старших за це видаляється (текст лишається)
let autoRetryLimit = 3

enum Phase: String { case idle, recording, transcribing }

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let noPrompts: Bool
    private let startedAt = Date()
    private var phase = Phase.idle
    private var axTrusted = false
    private var mic = "notDetermined"
    private var settings = Settings.load()
    private let keys = KeyWatcher()
    private let recorder = Recorder()
    private var sounds: Sounds!
    private let store = HistoryStore()
    private let historyUI = HistoryUI()
    private let playback = Playback()
    private var bar: BarController!
    private var history: HistoryWindowController!
    private var soundLab: SoundLab!
    private var soundsWindow: SoundsWindowController!
    private var item: NSStatusItem!
    private let menu = NSMenu()                      // старе системне меню — лише на правий клік, про запас
    private let menuModel = MenuModel()
    private let spectra = TakeSpectra()
    private var menuPanel: MenuPanelController!
    private var permTimer: Timer?
    private var recTimer: Timer?
    private var previewTimer: Timer?
    private var current: String?               // id диктовки, що записується або розпізнається
    private var recStartMono = 0.0
    private var lastWarm = 0.0
    private var lastGoodKey: String?
    private var lastStateKey = ""
    private var iconName = ""
    private var tapFailLogged = false
    private var pathMonitor: NWPathMonitor?
    private var online = true

    private var trigger: TriggerKey { TriggerKey.byId(settings.trigger) }

    init(noPrompts: Bool) {
        self.noPrompts = noPrompts
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        for d in [dataDir, audioDir, home + "/Library/Logs"] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        axTrusted = AXIsProcessTrusted()
        mic = micStatus()
        lastGoodKey = lastGoodKeyTail()
        log("старт: pid \(getpid())\(noPrompts ? " (--no-prompts)" : ""); універсальний доступ: \(axTrusted ? "так" : "ні"); мікрофон: \(mic); клавіша: \(trigger.title)")
        store.load()
        recoverInterrupted()
        pruneOldAudio()
        sounds = Sounds(set: SoundSet(rawValue: settings.soundSet) ?? .warm, volume: settings.soundVolume)
        soundLab = SoundLab(selected: sounds.set, volume: settings.soundVolume)
        soundLab.audition = { [weak self] s, c in self?.sounds.audition(s, c) ?? 0 }
        soundLab.onChoose = { [weak self] s in self?.applySoundSet(s) }
        soundLab.onVolume = { [weak self] v in self?.sounds.volume = v }
        soundLab.onVolumeEnd = { [weak self] in
            guard let self else { return }
            self.settings.soundVolume = self.sounds.volume
            self.settings.save()
            if self.sounds.set != .off { self.soundLab.play(self.sounds.set, .start) }
        }
        soundsWindow = SoundsWindowController(lab: soundLab)
        bar = BarController()
        bar.model.style = BarStyle(rawValue: settings.style) ?? .spectrum
        history = HistoryWindowController(store: store, ui: historyUI, actions: historyActions(),
                                          triggerTitle: { [weak self] in self?.trigger.title ?? "правий Shift" })
        history.onClose = { [weak self] in self?.stopPlayback() }
        playback.onEnd = { [weak self] in self?.historyUI.playingId = nil }
        buildMenu()
        if let e = MenuView.takes(store.entries, limit: 1).first { spectra.request(e) }
        keys.trigger = trigger
        keys.onAction = { [weak self] a in self?.handle(a) }
        recorder.onLevel = { [weak self] v, t, b in self?.gotLevel(v, t, b) }
        if !noPrompts {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                DispatchQueue.main.async { self?.checkPermissions() }
            }
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkPermissions() }
        RunLoop.main.add(t, forMode: .common)
        permTimer = t
        checkPermissions()
        startNetworkMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.retryPending() }
    }

    // MARK: - Дозволи і стан

    /// Раз на секунду. Перехоплювач клавіш ставимо лише з дозволом «Універсальний доступ».
    private func checkPermissions() {
        let ax = AXIsProcessTrusted(), m = micStatus()
        if ax != axTrusted { axTrusted = ax; log("універсальний доступ: \(ax ? "так" : "ні")") }
        if m != mic { mic = m; log("мікрофон: \(m)") }
        if ax && !keys.installed {
            if keys.install() {
                tapFailLogged = false
                log("клавіші увімкнено: двічі \(trigger.title) — почати, раз — зупинити, Esc — скасувати")
            } else if !tapFailLogged {
                tapFailLogged = true
                log("перехоплювач клавіш не встановився — чекаю дозволу")
            }
        } else if !ax && keys.installed {
            keys.remove()
            log("клавіші вимкнено — немає дозволу")
        }
        refresh()
    }

    private func refresh() {
        let name: String
        switch phase {
        case .idle: name = "mic"
        case .recording: name = "mic.fill"
        case .transcribing: name = "waveform"
        }
        if name != iconName {
            iconName = name
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "Voice")
            img?.isTemplate = true
            item.button?.image = img
        }
        writeState()
        syncMenuModel()
    }

    /// Панель у смужці меню бачить стан через свою модель (оновлюємо лише те, що змінилось).
    private func syncMenuModel() {
        let m = menuModel
        if m.phase != phase { m.phase = phase }
        if m.recStart != recStartMono { m.recStart = recStartMono }
        if m.axTrusted != axTrusted { m.axTrusted = axTrusted }
        let micOK = mic == "authorized"
        if m.micOK != micOK { m.micOK = micOK }
        if m.trigger != trigger { m.trigger = trigger }
        if m.style != bar.model.style { m.style = bar.model.style }
        if m.soundTitle != sounds.set.title { m.soundTitle = sounds.set.title }
    }

    private func writeState() {
        let fields: [(String, String)] = [
            ("pid", jint(Int(getpid()))),
            ("started_at", jstr(iso(startedAt))),
            ("ax_trusted", jbool(axTrusted)),
            ("mic", jstr(mic)),
            ("hotkey_installed", jbool(keys.installed)),
            ("trigger", jstr(trigger.id)),
            ("state", jstr(phase.rawValue)),
        ]
        let key = fields.map { $0.1 }.joined(separator: "|")
        guard key != lastStateKey else { return }
        lastStateKey = key
        let text = jobj(fields + [("updated_at", jstr(iso(Date())))], pretty: true)
        try? Data(text.utf8).write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    // MARK: - Клавіші

    private func handle(_ a: KeyAction) {
        switch a {
        case .start: if phase == .idle { startRecording() }
        case .stop: if phase == .recording { stopRecording() }
        case .cancel: cancelRecording()
        case .pasteLast: pasteLast()
        case .copyLast: copyLast()
        case .history: history.toggle()
        }
    }

    // MARK: - Запис

    private func startRecording() {
        menuPanel.close(animated: false)            // клавіатура — назад програмі, куди піде текст
        mic = micStatus()
        guard mic == "authorized" else {
            log("запис не почато: мікрофон \(mic)")
            sounds.play(.error)
            bar.show(.message(icon: "mic.slash.fill", tint: .warning, title: "Немає дозволу на мікрофон", detail: nil), hideAfter: 3)
            refresh()
            return
        }
        stopPreview()
        let started = Date()
        var id = fileStamp.string(from: started)
        if store.entry(id) != nil { id += "-\(Int.random(in: 100...999))" }
        let file = audioDir + "/" + id + ".wav"
        sounds.play(.start)
        do {
            try recorder.start(file: file)
        } catch {
            log("помилка мікрофона: \(error)")
            try? FileManager.default.removeItem(atPath: file)
            sounds.play(.error)
            bar.show(.message(icon: "mic.slash.fill", tint: .warning, title: "Мікрофон не запустився", detail: nil), hideAfter: 3)
            return
        }
        phase = .recording
        keys.setRecording(true)
        current = id
        recStartMono = monoNow()
        let front = NSWorkspace.shared.frontmostApplication
        var e = Entry(id: id, ts: started, status: .recording)
        e.audioFile = file
        e.appName = front?.localizedName
        e.appBundle = front?.bundleIdentifier
        store.put(e)
        log("стан: recording")
        bar.beginRecording()
        bar.show(.recording)
        warmConnection()
        lastWarm = monoNow()
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.recordingTick() }
        RunLoop.main.add(t, forMode: .common)
        recTimer = t
        refresh()
    }

    private func recordingTick() {
        guard phase == .recording else { return }
        if monoNow() - recStartMono >= maxRecordingSeconds {
            log("10 хвилин — зупиняю запис сам")
            stopRecording()
            return
        }
        if monoNow() - lastWarm >= warmEverySeconds {
            warmConnection()
            lastWarm = monoNow()
        }
    }

    private func gotLevel(_ rms: Float, _ t: Double, _ bands: [Float]) {
        guard phase == .recording else { return }
        bar.level(levelFromRMS(rms), at: t, bands: bands)
    }

    private func stopRecording() {
        guard phase == .recording, let id = current else { return }
        let t0 = monoNow()
        recTimer?.invalidate()
        recTimer = nil
        let samples = recorder.stop()
        keys.setRecording(false)
        let audioS = Double(samples.count) / Double(wavRate)
        guard audioS >= minRecordingSeconds else {
            phase = .idle
            current = nil
            discard(id)
            sounds.play(.cancel)
            bar.hide()
            log("стан: idle — запис коротший за 0,3 с, відкинуто")
            refresh()
            return
        }
        // тиша (звук старту на початку не рахується) — не відправляємо, нічого не вставляємо
        let vad = VoiceActivity(samples: samples, ignoreFirst: chimeGuard)
        guard vad.voiced() >= 0.25 else {
            phase = .idle
            current = nil
            store.update(id) { e in
                e.status = .empty
                e.audioS = audioS
                e.text = ""
                e.error = nil
            }
            sounds.play(.cancel)
            bar.show(.message(icon: "ear", tint: .neutral, title: "Нічого не почув", detail: nil), hideAfter: 1.6)
            log("стан: idle — тиша (\(ua1(audioS)) с запису, голосу \(ua1(vad.voiced())) с), не відправляю")
            refresh()
            return
        }
        sounds.play(.stop)
        phase = .transcribing
        store.update(id) { $0.status = .transcribing; $0.audioS = audioS }
        log("стан: transcribing (\(ua1(audioS)) с звуку)")
        bar.show(.transcribing)
        refresh()
        runTranscription(makeWAV(samples)) { [weak self] out in
            self?.finish(id: id, out: out, t0: t0, audioS: audioS, vad: vad)
        }
    }

    /// Скільки секунд на початку запису займає звук старту (його мікрофон теж чує) — там голос не шукаємо.
    private var chimeGuard: Double {
        switch sounds.set {
        case .off: return 0
        case .ticks: return 0.2
        default: return 0.45
        }
    }

    private func runTranscription(_ wav: Data, done: @escaping (Outcome) -> Void) {
        let keyList = loadKeys()
        let start = startIndex(keyList, lastGood: lastGoodKey)
        Task.detached {
            let out = await transcribe(wav, keys: keyList, startAt: start, note: { log($0) })
            DispatchQueue.main.async { done(out) }
        }
    }

    @objc private func cancelRecording() {
        guard phase == .recording, let id = current else { return }
        recTimer?.invalidate()
        recTimer = nil
        let samples = recorder.stop()
        keys.setRecording(false)
        phase = .idle
        current = nil
        let audioS = Double(samples.count) / Double(wavRate)
        let kept = audioS >= minRecordingSeconds
        if kept { store.update(id) { $0.status = .cancelled; $0.audioS = audioS } } else { discard(id) }
        sounds.play(.cancel)
        bar.show(.message(icon: "xmark", tint: .neutral, title: "Скасовано", detail: kept ? "запис в історії" : nil), hideAfter: 1.1)
        log("стан: idle — запис скасовано")
        refresh()
    }

    private func discard(_ id: String) {
        if let f = store.entry(id)?.audioFile { try? FileManager.default.removeItem(atPath: f) }
        store.update(id) { $0.status = .discarded; $0.audioFile = nil }
    }

    // MARK: - Результат

    private func finish(id: String, out: Outcome, t0: Double, audioS: Double, vad: VoiceActivity) {
        current = nil
        let total = ms(since: t0)
        guard let raw = out.text else {
            let f = out.failure ?? .failed("невідомо")
            phase = .idle
            sounds.play(.error)
            bar.show(.message(icon: "exclamationmark.triangle.fill", tint: .warning, title: f.reason, detail: "запис збережено"), hideAfter: 3.5)
            log("стан: idle — помилка: \(f.reason) (\(f.detail))")
            store.update(id) { e in
                e.status = .failed
                e.error = f.reason
                e.retryable = f.retryable
                e.totalMs = total
                e.keyTail = out.keyTail
                e.transcriptId = out.transcriptId
            }
            refresh()
            return
        }
        if let k = out.keyTail { lastGoodKey = k }
        let cleaned = Hallucinations.clean(raw, words: out.words, vad: vad)
        if cleaned.removed > 0 { log("прибрано вигадане на тиші: \(cleaned.removed) слів") }
        let text = cleaned.text
        if text.isEmpty {
            phase = .idle
            sounds.play(.cancel)
            bar.show(.message(icon: "ear", tint: .neutral, title: "Нічого не почув", detail: nil), hideAfter: 2)
            store.update(id) { e in
                e.status = .empty
                e.text = ""
                e.error = nil
                e.totalMs = total
                e.keyTail = out.keyTail
                e.transcriptId = out.transcriptId
            }
            log("стан: idle — порожній текст (\(ua1(audioS)) с звуку, \(total) мс)")
            refresh()
            return
        }
        deliver(text) { [weak self] pasted in
            guard let self else { return }
            self.phase = .idle
            let front = NSWorkspace.shared.frontmostApplication
            if pasted {
                self.bar.show(.done(wordsText(wordCount(text))), hideAfter: 1.3)
            } else {
                self.bar.show(.message(icon: "doc.on.clipboard", tint: .accent, title: "Текст у буфері", detail: "встав ⌘V"), hideAfter: 3)
            }
            self.store.update(id) { e in
                e.status = pasted ? .pasted : .copied
                e.text = text
                e.error = nil
                e.totalMs = total
                e.keyTail = out.keyTail
                e.transcriptId = out.transcriptId
                if pasted, let f = front {
                    e.appName = f.localizedName ?? e.appName
                    e.appBundle = f.bundleIdentifier ?? e.appBundle
                }
            }
            log("стан: idle — \(pasted ? "вставлено" : "лише в буфері") (\(ua1(audioS)) с звуку, \(total) мс, ключ …\(out.keyTail ?? "?"))")
            if let e = self.store.entry(id) { self.spectra.request(e) }     // відбиток для панелі — заздалегідь
            self.refresh()
        }
    }

    /// Текст + пробіл у буфер (там і лишається), далі — ⌘V, щойно відпущено всі модифікатори.
    private func deliver(_ text: String, done: @escaping (Bool) -> Void) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text + " ", forType: .string)
        guard AXIsProcessTrusted() else { done(false); return }
        // відкрита панель Voice тримає клавіатуру — закрити й дати фокусу повернутися до програми під нею
        if menuPanel.isOpen { menuPanel.close(animated: false) }
        let wait = max(0, 0.15 - (monoNow() - menuPanel.closedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            // попереду вікно самого Voice — вставляти нікуди, текст лишається в буфері
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { done(false); return }
            self.whenModifiersReleased { released in
                guard released else { done(false); return }         // пальці досі на ⌃⌥⇧⌘ — не ризикуємо
                // окремий стан клавіш: фізично затиснуті модифікатори не домішуються до ⌘V
                let src = CGEventSource(stateID: .privateState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
                let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
                down?.flags = .maskCommand
                up?.flags = .maskCommand
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
                done(true)
            }
        }
    }

    /// Чекає (до 2,5 с), поки відпущено ⌃⌥⇧⌘, щоб ⌘V не злився з пальцями на клавішах
    /// (з Control Terminal вставив би «екранований» текст — з \ перед кожним пробілом).
    private func whenModifiersReleased(waited: Double = 0, _ go: @escaping (Bool) -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        if held.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { go(true) }
            return
        }
        if waited >= 2.5 { go(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.whenModifiersReleased(waited: waited + 0.03, go)
        }
    }

    // MARK: - Останнє, копіювання

    private func pasteLast() {
        guard let text = store.lastWithText?.text else {
            if phase == .idle { bar.show(.message(icon: "tray", tint: .neutral, title: "Історія ще порожня", detail: nil), hideAfter: 1.5) }
            return
        }
        deliver(text) { [weak self] pasted in
            guard let self, !pasted, self.phase == .idle else { return }
            self.bar.show(.message(icon: "doc.on.clipboard", tint: .accent, title: "Текст у буфері", detail: "встав ⌘V"), hideAfter: 2.5)
        }
    }

    private func copyLast() {
        guard let e = store.lastWithText else {
            if phase == .idle { bar.show(.message(icon: "tray", tint: .neutral, title: "Історія ще порожня", detail: nil), hideAfter: 1.5) }
            return
        }
        copy(e)
        if phase == .idle {
            bar.show(.message(icon: "checkmark", tint: .accent, title: "Скопійовано", detail: snippet(e.text, 26)), hideAfter: 1.5)
        }
    }

    private func copy(_ e: Entry) {
        guard let t = e.text, !t.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t, forType: .string)
        historyUI.flash("Скопійовано")
    }

    // MARK: - Повтор невдалих

    private func retry(_ id: String, auto: Bool) {
        guard let e = store.entry(id), !e.busy, !historyUI.retrying.contains(id), let f = e.audioFile,
              let wav = FileManager.default.contents(atPath: f) else { return }
        historyUI.retrying.insert(id)
        store.update(id) { $0.attempts += 1 }
        log("повтор (\(auto ? "сам" : "вручну")): \(id)")
        let t0 = monoNow()
        let vad = VoiceActivity(wavFile: f, ignoreFirst: 0.45)
        runTranscription(wav) { [weak self] out in
            guard let self else { return }
            self.historyUI.retrying.remove(id)
            guard let raw = out.text else {
                let fl = out.failure ?? .failed("невідомо")
                self.store.update(id) { e in
                    if e.status != .pasted && e.status != .copied && e.status != .ready {
                        e.status = .failed
                        e.error = fl.reason
                        e.retryable = fl.retryable
                    }
                }
                log("повтор не вдався: \(fl.reason) (\(fl.detail))")
                if !auto { self.sounds.play(.error) }
                return
            }
            if let k = out.keyTail { self.lastGoodKey = k }
            let cleaned = Hallucinations.clean(raw, words: out.words, vad: vad)
            if cleaned.removed > 0 { log("прибрано вигадане на тиші: \(cleaned.removed) слів") }
            let text = cleaned.text
            self.store.update(id) { e in
                if text.isEmpty {
                    if e.status != .pasted { e.status = .empty }
                } else if e.status != .pasted {
                    e.status = auto ? .ready : .copied
                }
                e.text = text
                e.error = nil
                e.retryable = false
                e.totalMs = ms(since: t0)
                e.keyTail = out.keyTail
                e.transcriptId = out.transcriptId
            }
            log("повтор вдався: \(id) (\(text.isEmpty ? "тиша" : "\(wordCount(text)) слів"))")
            guard !text.isEmpty, let fresh = self.store.entry(id) else { return }
            self.spectra.request(fresh)
            if !auto {
                self.copy(fresh)
            } else if self.phase == .idle {
                self.bar.show(.message(icon: "arrow.clockwise", tint: .success, title: "Розпізнав збережений запис",
                                       detail: "він в історії"), hideAfter: 2.5)
            }
        }
    }

    /// Невдалі через зв'язок/сервер за останню добу — ще раз, сам (до 3 спроб).
    private func retryPending() {
        guard online else { return }
        let dayAgo = Date().addingTimeInterval(-86400)
        for e in store.entries where e.status == .failed && e.retryable && e.attempts < autoRetryLimit && e.ts > dayAgo {
            retry(e.id, auto: true)
        }
    }

    private func startNetworkMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] p in
            let ok = p.status == .satisfied
            DispatchQueue.main.async {
                guard let self else { return }
                let was = self.online
                self.online = ok
                guard ok && !was else { return }
                log("інтернет повернувся — пробую невдалі записи")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.retryPending() }
            }
        }
        m.start(queue: DispatchQueue(label: "voice.net"))
        pathMonitor = m
    }

    // MARK: - Старт: полагодити обірване, прибрати старий звук

    private func recoverInterrupted() {
        for e in store.entries where e.busy {
            var secs = e.audioS
            if let f = e.audioFile, FileManager.default.fileExists(atPath: f) {
                if e.status == .recording { secs = repairWAV(f) ?? 0 }
            } else {
                secs = 0
            }
            if secs < minRecordingSeconds {
                discard(e.id)
                continue
            }
            let what = e.status == .recording ? "запису" : "розпізнавання"
            store.update(e.id) { x in
                x.status = .failed
                x.audioS = secs
                x.error = "Перервано: Voice закрився посеред \(what)"
                x.retryable = true
            }
            log("відновлено обірвану диктовку \(e.id) (\(ua1(secs)) с звуку)")
        }
    }

    private func pruneOldAudio() {
        let cutoff = Date().addingTimeInterval(-keepAudioDays * 86400)
        let done: Set<EntryStatus> = [.pasted, .copied, .ready, .empty, .cancelled, .discarded]
        var n = 0
        for e in store.entries where done.contains(e.status) && e.ts < cutoff {
            guard let f = e.audioFile else { continue }
            try? FileManager.default.removeItem(atPath: f)
            store.update(e.id) { $0.audioFile = nil }
            n += 1
        }
        if n > 0 { log("прибрано звук \(n) старих диктовок (текст лишився)") }
    }

    // MARK: - Вікно історії

    private func historyActions() -> HistoryActions {
        var a = HistoryActions()
        a.copy = { [weak self] e in self?.copy(e) }
        a.retry = { [weak self] e in self?.retry(e.id, auto: false) }
        a.play = { [weak self] e in self?.togglePlay(e) }
        a.seek = { [weak self] e, f in self?.seek(e, f) }
        a.reveal = { e in
            if let f = e.audioFile { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) }
        }
        a.progress = { [weak self] in self?.playback.progress ?? 0 }
        a.position = { [weak self] in self?.playback.position ?? 0 }
        return a
    }

    private func togglePlay(_ e: Entry) {
        if historyUI.playingId == e.id { stopPlayback(); return }
        guard let f = e.audioFile, playback.play(f) else { return }
        historyUI.playingId = e.id
    }

    /// Клік по хвилі: якщо цей запис уже грає — перемотати, інакше почати з цього місця.
    private func seek(_ e: Entry, _ fraction: Double) {
        if historyUI.playingId == e.id {
            playback.seek(fraction)
            return
        }
        guard let f = e.audioFile, playback.play(f, from: fraction) else { return }
        historyUI.playingId = e.id
    }

    private func stopPlayback() {
        playback.stop()
        historyUI.playingId = nil
    }

    // MARK: - Показ смужки (коли обираєш вигляд у меню)

    private func previewBar() {
        guard phase == .idle else { return }
        stopPreview()
        bar.beginRecording()
        bar.show(.recording)
        let t0 = monoNow()
        let t = Timer(timeInterval: 1.0 / 47, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = monoNow(), s = now - t0
            if s < 2.6 {
                let f = SampleVoice.frame(at: s)
                self.bar.level(f.level, at: now, bands: f.bands)
            } else {
                self.stopPreview()
                self.bar.show(.transcribing)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard let self, self.phase == .idle else { return }
                    self.bar.show(.done(wordsText(12)), hideAfter: 1.2)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        previewTimer = t
    }

    private func stopPreview() {
        previewTimer?.invalidate()
        previewTimer = nil
    }

    // MARK: - Панель у смужці меню

    private func buildMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.autoenablesItems = false
        menu.delegate = self
        menuPanel = MenuPanelController(model: menuModel, store: store, ui: historyUI, spectra: spectra, actions: menuActions())
        menuPanel.anchor = { [weak self] in
            guard let b = self?.item.button, let w = b.window else { return nil }
            return w.convertToScreen(b.convert(b.bounds, to: nil))
        }
        menuPanel.onOpenChange = { [weak self] open in
            DispatchQueue.main.async { self?.item.button?.highlight(open) }
        }
        if let b = item.button {
            b.target = self
            b.action = #selector(statusClicked(_:))
            b.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        rebuildMenu()
    }

    /// Клік по значку — панель Voice; правий клік (або з Control) — старе системне меню.
    @objc private func statusClicked(_ sender: Any?) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseDown || ev?.modifierFlags.contains(.control) == true {
            menuPanel.close(animated: false)
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        menuPanel.toggle()
    }

    private func menuActions() -> MenuActions {
        var a = MenuActions()
        a.copy = { [weak self] e in
            guard let self else { return }
            self.copy(e)
            withAnimation(.easeOut(duration: 0.15)) { self.menuModel.copiedId = e.id }
            self.menuPanel.closeSoon(0.65)
        }
        a.paste = { [weak self] e in
            guard let self, let t = e.text, !t.isEmpty else { return }
            self.menuPanel.close(animated: false)
            self.deliver(t) { [weak self] pasted in
                guard let self, !pasted, self.phase == .idle else { return }
                self.bar.show(.message(icon: "doc.on.clipboard", tint: .accent, title: "Текст у буфері", detail: "встав ⌘V"), hideAfter: 2.5)
            }
        }
        a.retry = { [weak self] e in self?.retry(e.id, auto: false) }
        a.openHistory = { [weak self] e in
            guard let self else { return }
            self.menuPanel.close(animated: false)
            if let e {
                self.historyUI.query = ""
                self.historyUI.select(e.id)
            }
            self.history.show()
        }
        a.setTrigger = { [weak self] k in self?.applyTrigger(k.id) }
        a.setStyle = { [weak self] s in self?.applyStyle(s) }
        a.openSounds = { [weak self] in
            self?.menuPanel.close(animated: false)
            self?.soundsWindow.show()
        }
        a.openPermissions = { [weak self] in
            self?.menuPanel.close(animated: false)
            self?.openPermissions()
        }
        a.stop = { [weak self] in
            self?.menuPanel.close(animated: false)
            self?.stopRecording()
        }
        a.cancel = { [weak self] in
            self?.cancelRecording()
            self?.menuPanel.close()
        }
        a.quit = { [weak self] in self?.quit() }
        return a
    }

    func menuNeedsUpdate(_ m: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "Voice", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)])
        title.isEnabled = false
        menu.addItem(title)
        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !axTrusted || mic != "authorized" {
            menu.addItem(action("Відкрити налаштування дозволів", #selector(openPermissions)))
        }
        menu.addItem(.separator())

        menu.addItem(action("Історія диктовок…", #selector(openHistory), key: "h"))
        let last = store.lastWithText != nil
        menu.addItem(action("Вставити останнє", #selector(pasteLastMenu), key: "v", enabled: last))
        menu.addItem(action("Скопіювати останнє", #selector(copyLastMenu), key: "c", enabled: last))
        if phase == .recording { menu.addItem(action("Скасувати запис (Esc)", #selector(cancelRecording))) }

        let recent = store.entries.filter { $0.hasText && $0.status != .discarded }.prefix(5)
        if !recent.isEmpty {
            menu.addItem(.separator())
            let head = NSMenuItem(title: "Останні — клік копіює", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for e in recent {
                let i = action("\(Fmt.time.string(from: e.ts))   \(snippet(e.text, 46))", #selector(copyRecent(_:)))
                i.representedObject = e.id
                i.toolTip = e.text
                menu.addItem(i)
            }
        }
        menu.addItem(.separator())

        let keyMenu = NSMenu()
        for k in TriggerKey.all {
            let i = action(k.menuTitle, #selector(setTrigger(_:)))
            i.representedObject = k.id
            i.state = k.id == trigger.id ? .on : .off
            keyMenu.addItem(i)
        }
        let keyItem = NSMenuItem(title: "Клавіша: двічі \(trigger.title)", action: nil, keyEquivalent: "")
        keyItem.submenu = keyMenu
        menu.addItem(keyItem)

        let styleMenu = NSMenu()
        for s in BarStyle.allCases {
            let i = action(s.title, #selector(setStyle(_:)))
            i.representedObject = s.rawValue
            i.state = s == bar.model.style ? .on : .off
            styleMenu.addItem(i)
        }
        styleMenu.addItem(.separator())
        styleMenu.addItem(action("Показати", #selector(showStyle), enabled: phase == .idle))
        let styleItem = NSMenuItem(title: "Вигляд смужки: \(bar.model.style.title)", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        menu.addItem(action("Звуки: \(sounds.set.title)…", #selector(openSounds)))
        menu.addItem(.separator())
        menu.addItem(action("Вийти з Voice", #selector(quit)))
    }

    private func statusText() -> String {
        if !axTrusted { return "Потрібен дозвіл: Універсальний доступ" }
        if mic != "authorized" { return "Потрібен дозвіл: Мікрофон" }
        switch phase {
        case .recording: return "Запис… \(trigger.title) — зупинити, Esc — скасувати"
        case .transcribing: return "Розпізнаю…"
        case .idle: return "Готовий · двічі \(trigger.title) — диктувати"
        }
    }

    private func action(_ title: String, _ sel: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        if !key.isEmpty { i.keyEquivalentModifierMask = [.control, .option] }
        i.target = self
        i.isEnabled = enabled
        return i
    }

    @objc private func openPermissions() {
        let pane = axTrusted ? "Privacy_Microphone" : "Privacy_Accessibility"
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(u)
        }
    }

    @objc private func openHistory() { history.show() }
    @objc private func pasteLastMenu() { pasteLast() }
    @objc private func copyLastMenu() { copyLast() }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let e = store.entry(id) else { return }
        copy(e)
        if phase == .idle { bar.show(.message(icon: "checkmark", tint: .accent, title: "Скопійовано", detail: snippet(e.text, 26)), hideAfter: 1.5) }
    }

    @objc private func setTrigger(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        applyTrigger(id)
    }

    @objc private func setStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let s = BarStyle(rawValue: raw) else { return }
        applyStyle(s)
    }

    private func applyTrigger(_ id: String) {
        guard id != settings.trigger else { return }
        settings.trigger = id
        settings.save()
        keys.trigger = trigger
        log("клавіша: двічі \(trigger.title)")
        refresh()
    }

    /// Обрати вигляд смужки й одразу показати її (повторний вибір того самого — просто показати).
    private func applyStyle(_ s: BarStyle) {
        if s != bar.model.style {
            settings.style = s.rawValue
            settings.save()
            bar.model.style = s
            log("вигляд смужки: \(s.title)")
        }
        previewBar()
        refresh()
    }

    @objc private func showStyle() { previewBar() }

    /// Вікно «Звуки»: послухати всі набори й обрати.
    @objc private func openSounds() { soundsWindow.show() }

    private func applySoundSet(_ s: SoundSet) {
        guard s != sounds.set else { return }
        settings.soundSet = s.rawValue
        settings.save()
        sounds.use(s)
        log("звуки: \(s.title)")
        refresh()
    }

    /// Вихід (з меню або від kill): запис, що йде, закривається як слід і лишається в історії.
    func shutdown() {
        if phase == .recording, let id = current {
            recTimer?.invalidate()
            let samples = recorder.stop()
            let audioS = Double(samples.count) / Double(wavRate)
            if audioS >= minRecordingSeconds {
                store.update(id) { e in
                    e.status = .failed
                    e.audioS = audioS
                    e.error = "Перервано: Voice закрився посеред запису"
                    e.retryable = true
                }
            } else {
                discard(id)
            }
        }
        log("вихід")
    }

    @objc private func quit() {
        shutdown()
        NSApp.terminate(nil)
    }
}
