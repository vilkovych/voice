// Перевірка вигляду без мікрофона й без рук:
//   Voice --png <тека>   — смужка в усіх станах (на світлому й темному тлі) і вікно історії → PNG;
//   Voice --demo <тека>  — те саме наживо: смужка проходить усі стани внизу екрана, вікно історії
//                          з'являється без перехоплення фокусу; кадри знімає screencapture.
import AppKit
import SwiftUI

/// ≈4 с справжнього голосу з диктовки (60 відліків на секунду) — щоб смужка рухалась, як від живої мови.
let sampleVoice: [Float] = [
    0.34, 0.35, 0.56, 0.77, 0.84, 0.73, 0.66, 0.76, 0.8, 0.75, 0.62, 0.58, 0.5, 0.54, 0.7, 0.78, 0.82, 0.81, 0.82, 0.74,
    0.79, 0.73, 0.71, 0.67, 0.74, 0.71, 0.59, 0.48, 0.44, 0.32, 0.3, 0.23, 0.28, 0.71, 0.69, 0.62, 0.56, 0.43, 0.37, 0.36,
    0.3, 0.24, 0.7, 0.73, 0.79, 0.76, 0.74, 0.72, 0.49, 0.46, 0.41, 0.4, 0.33, 0.74, 0.82, 0.81, 0.71, 0.55, 0.55, 0.53,
    0.58, 0.64, 0.68, 0.72, 0.71, 0.7, 0.72, 0.79, 0.82, 0.8, 0.81, 0.82, 0.74, 0.57, 0.53, 0.41, 0.34, 0.33, 0.28, 0.26,
    0.48, 0.28, 0.41, 0.34, 0.33, 0.37, 0.28, 0.72, 0.84, 0.86, 0.83, 0.63, 0.54, 0.45, 0.36, 0.32, 0.38, 0.42, 0.35, 0.5,
    0.68, 0.73, 0.73, 0.66, 0.7, 0.69, 0.65, 0.65, 0.51, 0.36, 0.4, 0.17, 0.18, 0.12, 0.12, 0.4, 0.45, 0.44, 0.68, 0.81,
    0.87, 0.87, 0.82, 0.8, 0.74, 0.63, 0.52, 0.45, 0.41, 0.38, 0.36, 0.24, 0.17, 0.2, 0.37, 0.36, 0.6, 0.76, 0.85, 0.85,
    0.84, 0.7, 0.57, 0.55, 0.59, 0.75, 0.77, 0.6, 0.53, 0.41, 0.32, 0.34, 0.53, 0.74, 0.76, 0.75, 0.78, 0.71, 0.73, 0.72,
    0.72, 0.63, 0.59, 0.61, 0.58, 0.65, 0.7, 0.71, 0.77, 0.75, 0.81, 0.79, 0.8, 0.77, 0.73, 0.73, 0.71, 0.72, 0.74, 0.74,
    0.69, 0.54, 0.42, 0.34, 0.29, 0.24, 0.47, 0.72, 0.65, 0.5, 0.67, 0.63, 0.57, 0.61, 0.58, 0.66, 0.68, 0.66, 0.63, 0.64,
    0.62, 0.76, 0.78, 0.77, 0.75, 0.75, 0.77, 0.74, 0.59, 0.49, 0.69, 0.74, 0.71, 0.48, 0.32, 0.4, 0.27, 0.37, 0.28, 0.4,
    0.64, 0.53, 0.53, 0.55, 0.59, 0.65, 0.52, 0.61, 0.72, 0.64, 0.47, 0.48, 0.43, 0.27, 0.23, 0.23, 0.69, 0.72, 0.67, 0.73,
]

func sampleLevel(at t: Double) -> Float { sampleVoice[Int(max(0, t) * 60) % sampleVoice.count] }

/// Справжній голос для показу смужки: гучність і спектр кожні ~21 мс — з design/voice_sample.wav
/// (якщо файла нема — штучні, з обвідної вище).
enum SampleVoice {
    static let step = 341.0 / Double(wavRate)
    static let frames: [(level: Float, bands: [Float])] = {
        let path = home + "/Desktop/Work/voice/design/voice_sample.wav"
        if let d = FileManager.default.contents(atPath: path), d.count > 44 + 32000 {
            let n = (d.count - 44) / 2
            let s: [Int16] = d.withUnsafeBytes { raw in (0..<n).map { raw.loadUnaligned(fromByteOffset: 44 + 2 * $0, as: Int16.self) } }
            var an = SpectrumAnalyzer()
            var out: [(level: Float, bands: [Float])] = []
            var i = Int(0.8 * Double(wavRate))                    // на початку файла тиша
            while i + 341 <= s.count {
                let chunk = Array(s[i..<(i + 341)])
                var sum = 0.0
                for v in chunk { sum += Double(v) * Double(v) }
                let rms = Float(sqrt(sum / 341) / 32768)
                let bands = chunk.withUnsafeBufferPointer { an.levels($0) }
                out.append((levelFromRMS(rms), bands))
                i += 341
            }
            if !out.isEmpty { return out }
        }
        return sampleVoice.indices.map { k in
            let v = sampleVoice[k]
            let bands = (0..<SpectrumAnalyzer.bands).map { b -> Float in
                let f1 = 4 + 2 * sin(Double(k) * 0.07), f2 = 11 + 3 * sin(Double(k) * 0.05 + 1)
                let shape = exp(-pow((Double(b) - f1) / 2.2, 2)) + 0.7 * exp(-pow((Double(b) - f2) / 2.8, 2))
                return Float(min(1, Double(v) * (0.35 + 0.75 * shape)))
            }
            return (v, bands)
        }
    }()

    static func frame(at t: Double) -> (level: Float, bands: [Float]) {
        frames[Int(max(0, t) / step) % frames.count]
    }
}

/// Заповнює гучність і спектр так, наче від початку запису минуло `t` секунд.
private func feedSample(_ m: BarModel, upTo t: Double) {
    m.recStart = 0
    m.levels.reset(at: 0)
    m.spectrum.reset()
    var x = 0.0
    while x <= t {
        let f = SampleVoice.frame(at: x)
        m.levels.add(f.level, at: x)
        m.spectrum.add(f.bands, at: x)
        x += SampleVoice.step
    }
}

@MainActor
private func writePNG<V: View>(_ view: V, _ path: String) throws {
    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let img = r.cgImage,
          let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
        throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "не намалював \(path)"])
    }
    try png.write(to: URL(fileURLWithPath: path))
}

@MainActor
func renderPreviews(to dir: String) throws -> [String] {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var out: [String] = []

    func bar(_ name: String, _ setup: (BarModel) -> Double) throws {
        let m = BarModel()
        let t = setup(m)
        let view = VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Color(white: 0.97), Color(white: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
                BarFrame(model: m, t: t)
            }
            ZStack {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
                BarFrame(model: m, t: t)
            }
        }
        .frame(width: barPanelSize.width, height: barPanelSize.height * 2)
        let p = (dir as NSString).appendingPathComponent("bar_\(name).png")
        try writePNG(view, p)
        out.append(p)
    }

    try bar("0_appear") { m in feedSample(m, upTo: 0.12); m.set(.recording, at: 0, appearing: true); return 0.12 }
    for (i, style) in BarStyle.allCases.enumerated() {
        try bar("1\(i)_rec_\(style.rawValue)") { m in
            m.style = style
            feedSample(m, upTo: 3.4)
            m.set(.recording, at: 0, appearing: true)
            return 3.4
        }
    }
    try bar("2_transcribing") { m in
        m.set(.recording, at: 0, appearing: true)
        m.set(.transcribing, at: 3, appearing: false)
        return 3.75
    }
    try bar("3_done") { m in
        m.set(.transcribing, at: 0, appearing: true)
        m.set(.done(wordsText(23)), at: 1, appearing: false)
        return 1.6
    }
    try bar("4_error") { m in
        m.set(.message(icon: "exclamationmark.triangle.fill", tint: .warning, title: "Немає зв'язку", detail: "запис збережено"),
              at: 0, appearing: true)
        return 0.8
    }
    try bar("5_cancel") { m in
        m.set(.message(icon: "xmark", tint: .neutral, title: "Скасовано", detail: "запис в історії"), at: 0, appearing: true)
        return 0.8
    }
    try bar("6_clipboard") { m in
        m.set(.message(icon: "doc.on.clipboard", tint: .accent, title: "Текст у буфері", detail: "встав ⌘V"), at: 0, appearing: true)
        return 0.8
    }
    try bar("7_hiding") { m in
        m.set(.done(wordsText(5)), at: 0, appearing: true)
        m.startHide(at: 1)
        return 1.1
    }

    // Вікно історії: справжні диктовки + кілька станів, щоб побачити всі види карток.
    let real = HistoryStore()
    real.readOnly = true
    real.load()
    var list = Array(real.entries.filter { $0.status != .discarded }.prefix(5))
    let now = Date()
    let someAudio = list.first(where: { $0.hasAudio })?.audioFile
    var failed = Entry(id: "demo-failed", ts: now.addingTimeInterval(-90), status: .failed)
    failed.audioS = 14.2
    failed.error = "Немає зв'язку"
    failed.appName = "Firefox"
    failed.appBundle = "org.mozilla.firefox"
    failed.audioFile = someAudio
    var trans = Entry(id: "demo-trans", ts: now, status: .transcribing)
    trans.audioS = 6.4
    trans.appName = "Термінал"
    trans.appBundle = "com.apple.Terminal"
    var cancelled = Entry(id: "demo-cancel", ts: now.addingTimeInterval(-400), status: .cancelled)
    cancelled.audioS = 3.1
    cancelled.appName = "Термінал"
    cancelled.appBundle = "com.apple.Terminal"
    cancelled.audioFile = someAudio
    list += [failed, trans, cancelled]
    let shown = HistoryStore()
    shown.preview(list)
    let waves = Waveforms()
    waves.preload(list)

    func history(_ name: String, select: String?, toast: String? = nil) throws {
        let ui = HistoryUI()
        ui.select(select)
        ui.toast = toast
        let v = HistoryView(store: shown, ui: ui, waves: waves, actions: HistoryActions(), triggerTitle: "правий Shift", snapshot: true)
            .frame(width: 940, height: 640)
        let p = (dir as NSString).appendingPathComponent(name)
        try writePNG(v, p)
        out.append(p)
    }
    try history("history.png", select: shown.entries.first(where: { $0.hasText })?.id, toast: "Скопійовано")
    try history("history_failed.png", select: "demo-failed")

    // Вікно «Звуки»: обрано «Теплі», у «Кришталевих» світиться пад «Старт» (без справжнього звуку)
    let lab = SoundLab(selected: .warm, volume: 0.8)
    lab.audition = { _, _ in 1 }
    lab.play(.glass, .start)
    let sv = SoundsView(lab: lab, snapshot: true).frame(width: 860, height: 760)
    let sp = (dir as NSString).appendingPathComponent("sounds.png")
    try writePNG(sv, sp)
    out.append(sp)

    let empty = HistoryStore()
    empty.preview([])
    let ev = HistoryView(store: empty, ui: HistoryUI(), waves: Waveforms(), actions: HistoryActions(),
                         triggerTitle: "правий Shift", snapshot: true)
        .frame(width: 940, height: 560)
    let ep = (dir as NSString).appendingPathComponent("history_empty.png")
    try writePNG(ev, ep)
    out.append(ep)

    // Панель під значком у смужці меню: справжні диктовки; окремо — налаштування, запис, збій, порожньо.
    let takes = HistoryStore()
    takes.preview(Array(real.entries.prefix(40)))
    let spectra = TakeSpectra()
    for e in MenuView.takes(takes.entries, limit: 1) + MenuView.takes(shown.entries, limit: 1) { spectra.preload(e) }
    func menu(_ name: String, _ store: HistoryStore, _ setup: (MenuModel) -> Void = { _ in }) throws {
        let m = MenuModel()
        m.soundTitle = SoundSet.ticks.title
        setup(m)
        let v = MenuView(model: m, store: store, ui: HistoryUI(), spectra: spectra, actions: MenuActions(), snapshot: true)
            .fixedSize(horizontal: false, vertical: true)
            .padding(24)
            .background(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
        let p = (dir as NSString).appendingPathComponent(name)
        try writePNG(v, p)
        out.append(p)
    }
    try menu("menu.png", takes)
    try menu("menu_settings.png", takes) { $0.page = .settings }
    try menu("menu_recording.png", takes) { $0.phase = .recording }
    try menu("menu_failed.png", shown)
    try menu("menu_empty.png", empty) { $0.axTrusted = false }
    return out
}

/// Звуки наборів «Теплі» й «Кришталеві» — у WAV, щоб виміряти й послухати.
func exportSounds(to dir: String) throws -> [String] {
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var out: [String] = []
    for s in SoundSet.allCases where s != .system && s != .off {
        for c in Cue.allCases {
            let p = (dir as NSString).appendingPathComponent("\(s.rawValue)_\(c.rawValue).wav")
            try Sounds.wav(c, s).write(to: URL(fileURLWithPath: p))
            out.append(p)
        }
    }
    return out
}

// MARK: - Наживо на екрані

final class DemoRunner {
    private let dir: String
    private let bar = BarController()
    private let store = HistoryStore()
    private let ui = HistoryUI()
    private let window: HistoryWindowController
    private let soundsWindow = SoundsWindowController(lab: SoundLab(selected: .warm, volume: 0.8))
    private lazy var menuPanel: MenuPanelController = {
        let m = MenuModel()
        m.soundTitle = SoundSet.ticks.title
        return MenuPanelController(model: m, store: store, ui: ui, spectra: TakeSpectra(), actions: MenuActions())
    }()
    private var feeder: Timer?

    init(dir: String) {
        self.dir = dir
        store.readOnly = true
        store.load()
        window = HistoryWindowController(store: store, ui: ui, actions: HistoryActions(), triggerTitle: { "правий Shift" })
        ui.select(store.entries.first(where: { $0.hasText })?.id)
    }

    func run() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let steps: [(Double, () -> Void)] = [
            (0.3, { self.record(.spectrum) }),
            (2.6, { self.snapBar("live_1_spectrum") }),
            (2.9, { self.stopFeeding(); self.bar.hide(); self.window.show(activate: false) }),
            (4.4, { self.snapWindow("live_2_history") }),
            (5.0, { self.window.close(); self.soundsWindow.show(activate: false) }),
            (6.4, { if let n = self.soundsWindow.windowNumber { self.capture(["-x", "-o", "-l\(n)", self.dir + "/live_3_sounds.png"]) } }),
            (7.0, { self.soundsWindow.close(); self.menuPanel.open(makeKey: false) }),
            (7.12, { self.capture(["-x", "-l\(self.menuPanel.windowNumber)", self.dir + "/live_4_menu_burn.png"]) }),
            (8.2, { self.capture(["-x", "-l\(self.menuPanel.windowNumber)", self.dir + "/live_5_menu.png"]) }),
            (8.5, { self.menuPanel.model.page = .settings }),
            (9.1, { self.capture(["-x", "-l\(self.menuPanel.windowNumber)", self.dir + "/live_6_menu_settings.png"]) }),
            (9.6, { self.menuPanel.close(animated: false); exit(0) }),
        ]
        for (t, f) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f) }
    }

    private func record(_ style: BarStyle) {
        bar.model.style = style
        bar.beginRecording()
        bar.show(.recording)
        let t0 = monoNow()
        stopFeeding()
        let t = Timer(timeInterval: SampleVoice.step, repeats: true) { [weak self] _ in
            let now = monoNow()
            let f = SampleVoice.frame(at: now - t0)
            self?.bar.level(f.level, at: now, bands: f.bands)
        }
        RunLoop.main.add(t, forMode: .common)
        feeder = t
    }

    private func stopFeeding() {
        feeder?.invalidate()
        feeder = nil
    }

    /// Знімок області смужки (у screencapture y рахується від верху головного екрана).
    private func snapBar(_ name: String) {
        let f = bar.frame
        let h = NSScreen.screens.first?.frame.height ?? 0
        capture(["-x", "-R\(Int(f.minX)),\(Int(h - f.maxY)),\(Int(f.width)),\(Int(f.height))", dir + "/" + name + ".png"])
    }

    private func snapWindow(_ name: String) {
        guard let n = window.windowNumber else { return }
        capture(["-x", "-o", "-l\(n)", dir + "/" + name + ".png"])
    }

    private func capture(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        try? p.run()
    }
}
