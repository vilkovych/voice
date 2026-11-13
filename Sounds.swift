// Звуки Voice. Свої, синтезовані тут же (жодних чужих файлів), крім набору «Системні macOS».
// У кожному наборі чотири звуки: старт — дві ноти вгору, стоп — дві вниз, помилка — дві низькі,
// скасування — один тихий. Спільне для всіх: м'яка атака, нота «відпускається» (не тягнеться),
// трохи простору (реверберація), стерео (канали ледь розходяться за висотою).
import AppKit
import AVFoundation

enum Cue: String, CaseIterable {
    case start, stop, error, cancel
    var title: String {
        switch self {
        case .start: return "Старт"
        case .stop: return "Стоп"
        case .error: return "Помилка"
        case .cancel: return "Скасування"
        }
    }
}

enum SoundSet: String, CaseIterable {
    case warm, glass, wood, kalimba, drops, harp, synth, ticks, system, off

    var title: String {
        switch self {
        case .warm: return "Теплі"
        case .glass: return "Кришталеві"
        case .wood: return "Дерево"
        case .kalimba: return "Калімба"
        case .drops: return "Краплі"
        case .harp: return "Струна"
        case .synth: return "Синтезатор"
        case .ticks: return "Тихі клацання"
        case .system: return "Системні macOS"
        case .off: return "Без звуків"
        }
    }

    var note: String {
        switch self {
        case .warm: return "Електропіаніно, м'яке й кругле."
        case .glass: return "Скляні дзвіночки, світлі й прозорі."
        case .wood: return "Маримба, дерев'яні молоточки."
        case .kalimba: return "Металеві язички, казковий «дзень»."
        case .drops: return "Краплі води, легкі й сучасні."
        case .harp: return "Щипок струни, як на арфі."
        case .synth: return "М'який аналоговий синтезатор."
        case .ticks: return "Ледь чутні, майже без звуку."
        case .system: return "Tink, Pop, Basso і Purr з macOS."
        case .off: return "Voice нічого не відтворює."
        }
    }
}

final class Sounds {
    private(set) var set: SoundSet = .warm
    var volume: Double = 0.8 { didSet { applyVolume() } }
    private var players: [Cue: AVAudioPlayer] = [:]
    private var system: [Cue: NSSound] = [:]
    private var auditionPlayer: AVAudioPlayer?
    private var auditionSound: NSSound?
    private var cache: [String: Data] = [:]
    private var previewWork: DispatchWorkItem?
    private static let systemNames: [Cue: String] = [.start: "Tink", .stop: "Pop", .error: "Basso", .cancel: "Purr"]

    init(set: SoundSet, volume: Double) {
        self.volume = volume
        use(set)
    }

    func use(_ s: SoundSet) {
        set = s
        players = [:]
        system = [:]
        switch s {
        case .off:
            break
        case .system:
            for (c, n) in Self.systemNames {
                if let snd = NSSound(named: NSSound.Name(n)) { system[c] = snd }
            }
        default:
            for c in Cue.allCases {
                guard let p = try? AVAudioPlayer(data: data(c, s), fileTypeHint: AVFileType.wav.rawValue) else { continue }
                p.prepareToPlay()
                players[c] = p
            }
        }
        applyVolume()
    }

    private func applyVolume() {
        players.values.forEach { $0.volume = Float(0.8 * volume) }
        system.values.forEach { $0.volume = Float(0.6 * volume) }
    }

    func play(_ c: Cue) {
        if let p = players[c] {
            p.stop()
            p.currentTime = 0
            p.play()
        } else if let snd = system[c] {
            snd.stop()
            snd.play()
        }
    }

    /// Почути будь-який звук будь-якого набору (для вікна «Звуки»). Повертає тривалість.
    @discardableResult
    func audition(_ s: SoundSet, _ c: Cue) -> Double {
        auditionPlayer?.stop()
        auditionSound?.stop()
        switch s {
        case .off:
            return 0
        case .system:
            guard let name = Self.systemNames[c], let snd = NSSound(named: NSSound.Name(name)) else { return 0 }
            snd.volume = Float(0.6 * volume)
            snd.play()
            auditionSound = snd
            return snd.duration
        default:
            guard let p = try? AVAudioPlayer(data: data(c, s), fileTypeHint: AVFileType.wav.rawValue) else { return 0 }
            p.volume = Float(0.8 * volume)
            p.play()
            auditionPlayer = p
            return p.duration
        }
    }

    /// Показати набір: старт, за мить — стоп.
    func preview(_ s: SoundSet? = nil) {
        previewWork?.cancel()
        let target = s ?? set
        audition(target, .start)
        let w = DispatchWorkItem { [weak self] in self?.audition(target, .stop) }
        previewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: w)
    }

    private func data(_ c: Cue, _ s: SoundSet) -> Data {
        let key = s.rawValue + "." + c.rawValue
        if let d = cache[key] { return d }
        let d = Self.wav(c, s)
        cache[key] = d
        return d
    }

    // MARK: - Що саме звучить

    static func wav(_ c: Cue, _ s: SoundSet) -> Data {
        let A3 = 220.0, F3 = 174.61, Cs3 = 138.59, E3 = 164.81
        let D4 = 293.66, Ds4 = 311.13, E4 = 329.63, Cs4 = 277.18, F4 = 349.23, G4 = 392.0, As3 = 233.08
        let A4 = 440.0, C5 = 523.25, D5 = 587.33, E5 = 659.25, F5 = 698.46, G5 = 783.99, A5 = 880.0
        let C6 = 1046.5, E6 = 1318.51
        var x = Synth(1.3)
        switch (s, c) {
        // Кришталеві
        case (.glass, .start):
            x.glass(A5, at: 0, amp: 1, decay: 0.55, pan: -0.2); x.glass(E6, at: 0.075, amp: 0.8, decay: 0.6, pan: 0.2)
            return x.finish(wet: 0.32, room: 0.35, peak: 0.42)
        case (.glass, .stop):
            x.glass(E6, at: 0, amp: 0.8, decay: 0.5, pan: 0.2); x.glass(A5, at: 0.075, amp: 1, decay: 0.55, pan: -0.2)
            return x.finish(wet: 0.3, room: 0.35, peak: 0.38)
        case (.glass, .error):
            x.wood(Ds4, at: 0, amp: 1, decay: 0.18, pan: -0.1); x.wood(As3, at: 0.15, amp: 1, decay: 0.24, pan: 0.1)
            return x.finish(wet: 0.22, room: 0.25, peak: 0.48)
        case (.glass, .cancel):
            x.glass(A5, at: 0, amp: 0.6, decay: 0.12)
            return x.finish(wet: 0.2, room: 0.22, peak: 0.26)
        // Дерево
        case (.wood, .start):
            x.wood(C5, at: 0, amp: 1, decay: 0.25, pan: -0.2); x.wood(G5, at: 0.085, amp: 0.9, decay: 0.28, pan: 0.2)
            return x.finish(wet: 0.22, room: 0.25, peak: 0.48)
        case (.wood, .stop):
            x.wood(G5, at: 0, amp: 0.9, decay: 0.24, pan: 0.2); x.wood(C5, at: 0.085, amp: 1, decay: 0.27, pan: -0.2)
            return x.finish(wet: 0.22, room: 0.25, peak: 0.44)
        case (.wood, .error):
            x.wood(E4, at: 0, amp: 1, decay: 0.16, pan: -0.1); x.wood(Cs4, at: 0.14, amp: 1, decay: 0.2, pan: 0.1)
            return x.finish(wet: 0.2, room: 0.25, peak: 0.48)
        case (.wood, .cancel):
            x.wood(A5, at: 0, amp: 0.7, decay: 0.06)
            return x.finish(wet: 0.15, room: 0.22, peak: 0.28)
        // Калімба
        case (.kalimba, .start):
            x.kalimba(D5, at: 0, amp: 1, decay: 0.35, pan: -0.2); x.kalimba(A5, at: 0.08, amp: 0.85, decay: 0.4, pan: 0.2)
            return x.finish(wet: 0.3, room: 0.3, peak: 0.46)
        case (.kalimba, .stop):
            x.kalimba(A5, at: 0, amp: 0.85, decay: 0.3, pan: 0.2); x.kalimba(D5, at: 0.08, amp: 1, decay: 0.38, pan: -0.2)
            return x.finish(wet: 0.3, room: 0.3, peak: 0.42)
        case (.kalimba, .error):
            x.kalimba(F4, at: 0, amp: 1, decay: 0.22, pan: -0.1); x.kalimba(D4, at: 0.13, amp: 1, decay: 0.26, pan: 0.1)
            return x.finish(wet: 0.25, room: 0.25, peak: 0.48)
        case (.kalimba, .cancel):
            x.kalimba(E5, at: 0, amp: 0.6, decay: 0.1)
            return x.finish(wet: 0.2, room: 0.22, peak: 0.26)
        // Краплі
        case (.drops, .start):
            x.drop(A5, at: 0, amp: 1, decay: 0.07, pan: -0.2); x.drop(E6, at: 0.07, amp: 0.85, decay: 0.08, pan: 0.2)
            return x.finish(wet: 0.25, room: 0.3, peak: 0.45)
        case (.drops, .stop):
            x.drop(E6, at: 0, amp: 0.85, decay: 0.07, pan: 0.2); x.drop(A5, at: 0.07, amp: 1, decay: 0.08, pan: -0.2)
            return x.finish(wet: 0.25, room: 0.3, peak: 0.42)
        case (.drops, .error):
            x.drop(G4, at: 0, amp: 1, decay: 0.1, rise: -0.35, pan: -0.1)
            x.drop(Ds4, at: 0.12, amp: 1, decay: 0.12, rise: -0.35, pan: 0.1)
            return x.finish(wet: 0.22, room: 0.25, peak: 0.48)
        case (.drops, .cancel):
            x.drop(C6, at: 0, amp: 0.6, decay: 0.05)
            return x.finish(wet: 0.18, room: 0.22, peak: 0.26)
        // Струна
        case (.harp, .start):
            x.pluck(C5, at: 0, amp: 1, pan: -0.2); x.pluck(G5, at: 0.09, amp: 0.85, pan: 0.2)
            return x.finish(wet: 0.28, room: 0.3, peak: 0.48)
        case (.harp, .stop):
            x.pluck(G5, at: 0, amp: 0.85, pan: 0.2); x.pluck(C5, at: 0.09, amp: 1, pan: -0.2)
            return x.finish(wet: 0.28, room: 0.3, peak: 0.44)
        case (.harp, .error):
            x.pluck(E3, at: 0, amp: 1, damping: 0.993, bright: 0.3, pan: -0.1)
            x.pluck(Cs3, at: 0.14, amp: 1, damping: 0.993, bright: 0.3, pan: 0.1)
            return x.finish(wet: 0.22, room: 0.25, peak: 0.5)
        case (.harp, .cancel):
            x.pluck(A4, at: 0, amp: 0.6, damping: 0.985, bright: 0.3)
            return x.finish(wet: 0.18, room: 0.22, peak: 0.28)
        // Синтезатор
        case (.synth, .start):
            x.analog(F5, at: 0, amp: 1, decay: 0.18, pan: -0.15); x.analog(C6, at: 0.085, amp: 0.85, decay: 0.2, pan: 0.15)
            return x.finish(wet: 0.3, room: 0.3, peak: 0.42)
        case (.synth, .stop):
            x.analog(C6, at: 0, amp: 0.85, decay: 0.16, pan: 0.15); x.analog(F5, at: 0.085, amp: 1, decay: 0.2, pan: -0.15)
            return x.finish(wet: 0.3, room: 0.3, peak: 0.4)
        case (.synth, .error):
            x.analog(A3, at: 0, amp: 1, decay: 0.22, bend: 0.12); x.analog(F3, at: 0.15, amp: 1, decay: 0.26, bend: 0.12)
            return x.finish(wet: 0.25, room: 0.25, peak: 0.46)
        case (.synth, .cancel):
            x.analog(C5, at: 0, amp: 0.6, decay: 0.07)
            return x.finish(wet: 0.2, room: 0.22, peak: 0.24)
        // Тихі клацання
        case (.ticks, .start):
            x.tick(1400, at: 0, amp: 1, pan: -0.2); x.tick(2100, at: 0.06, amp: 0.8, pan: 0.2)
            return x.finish(wet: 0.08, room: 0.15, peak: 0.38)
        case (.ticks, .stop):
            x.tick(2100, at: 0, amp: 0.8, pan: 0.2); x.tick(1400, at: 0.06, amp: 1, pan: -0.2)
            return x.finish(wet: 0.08, room: 0.15, peak: 0.36)
        case (.ticks, .error):
            x.tick(500, at: 0, amp: 1); x.tick(500, at: 0.09, amp: 1)
            return x.finish(wet: 0.08, room: 0.15, peak: 0.42)
        case (.ticks, .cancel):
            x.tick(1000, at: 0, amp: 0.6)
            return x.finish(wet: 0.06, room: 0.15, peak: 0.22)
        // Теплі (типові); також запасний варіант для «Системних» і «Без звуків», якщо їх попросять у WAV
        case (_, .start):
            x.ep(C5, at: 0, amp: 1, decay: 0.3, pan: -0.2); x.ep(G5, at: 0.09, amp: 0.85, decay: 0.36, pan: 0.2)
            x.sine(C5 / 2, at: 0, amp: 0.12, decay: 0.15)
            return x.finish(wet: 0.28, room: 0.25, peak: 0.5)
        case (_, .stop):
            x.ep(G5, at: 0, amp: 0.85, decay: 0.26, pan: 0.2); x.ep(C5, at: 0.09, amp: 1, decay: 0.34, pan: -0.2)
            return x.finish(wet: 0.25, room: 0.25, peak: 0.44)
        case (_, .error):
            x.wood(E4, at: 0, amp: 1, decay: 0.16, pan: -0.1); x.wood(Cs4, at: 0.14, amp: 1, decay: 0.2, pan: 0.1)
            return x.finish(wet: 0.2, room: 0.25, peak: 0.48)
        case (_, .cancel):
            x.wood(A4, at: 0, amp: 0.8, decay: 0.07)
            return x.finish(wet: 0.15, room: 0.22, peak: 0.3)
        }
    }
}

// MARK: - Синтезатор

private struct Synth {
    static let sr = 48000.0
    var L: [Float]
    var R: [Float]
    var n: Int { L.count }

    init(_ seconds: Double) {
        L = [Float](repeating: 0, count: Int(seconds * Synth.sr))
        R = L
    }

    /// Канали ледь розходяться за висотою (±2 цента) — звук стає об'ємним.
    private static let detune = 0.0012

    private static func gains(_ pan: Double, _ amp: Double) -> (Double, Double) {
        (cos((pan + 1) * .pi / 4) * amp, sin((pan + 1) * .pi / 4) * amp)
    }

    /// `hold` — скільки нота звучить вільно; далі швидко гасне, як відпущена клавіша (звук не тягнеться).
    private mutating func render(at t0: Double, amp: Double, pan: Double, until: Double, hold: Double,
                                 _ voice: (Double, Double) -> Double) {
        let s0 = Int(t0 * Synth.sr)
        let (gl, gr) = Synth.gains(pan, amp)
        let fl = 1 - Synth.detune, fr = 1 + Synth.detune
        let end = min(n, s0 + Int(until * Synth.sr))
        guard s0 < end else { return }
        for i in s0..<end {
            let t = Double(i - s0) / Synth.sr
            let release = t < hold ? 1 : exp(-(t - hold) / 0.09)
            L[i] += Float(voice(t, fl) * gl * release)
            R[i] += Float(voice(t, fr) * gr * release)
        }
    }

    private static func holdFor(_ decay: Double) -> Double { min(0.45, decay * 1.1) }

    /// Електропіаніно: тіло (FM 1:1, яскравість гасне — звук тепліє) + короткий «дзвіночок» на 4-й гармоніці.
    mutating func ep(_ f: Double, at t0: Double, amp: Double, decay: Double, pan: Double = 0) {
        let hold = Synth.holdFor(decay)
        render(at: t0, amp: amp, pan: pan, until: hold + 0.6, hold: hold) { t, k in
            let env = (1 - exp(-t / 0.0025)) * exp(-t / decay)
            let w = 2 * Double.pi * f * k * t
            let body = 0.8 * sin(w + (1.5 * exp(-t / 0.09) + 0.22) * sin(w))
            let tine = 0.2 * exp(-t / 0.022) * sin(4 * w + 1.3 * sin(14 * w))
            return (body + tine) * env
        }
    }

    /// Скляний дзвіночок: обертони 1 : 2,76 : 5,40 : 8,93, вищі гаснуть швидше.
    mutating func glass(_ f: Double, at t0: Double, amp: Double, decay: Double, pan: Double = 0) {
        let partials: [(Double, Double, Double)] = [(1, 1, 1), (2.756, 0.42, 0.55), (5.404, 0.16, 0.3), (8.933, 0.06, 0.18)]
        let hold = Synth.holdFor(decay)
        render(at: t0, amp: amp, pan: pan, until: hold + 0.6, hold: hold) { t, k in
            var v = 0.0
            for (ratio, a, d) in partials { v += a * exp(-t / (decay * d)) * sin(2 * Double.pi * f * ratio * k * t) }
            return v * (1 - exp(-t / 0.0015)) / 1.4
        }
    }

    /// Дерев'яний стук (маримба): FM 1:4 з дуже швидким згасанням яскравості + коротка 4-та гармоніка.
    mutating func wood(_ f: Double, at t0: Double, amp: Double, decay: Double, pan: Double = 0) {
        let hold = Synth.holdFor(decay)
        render(at: t0, amp: amp, pan: pan, until: hold + 0.6, hold: hold) { t, k in
            let env = (1 - exp(-t / 0.0012)) * exp(-t / decay)
            let w = 2 * Double.pi * f * k * t
            let v = 0.85 * sin(w + (2.6 * exp(-t / 0.006) + 0.25) * sin(3.98 * w)) + 0.22 * exp(-t / 0.035) * sin(4 * w)
            return v * env
        }
    }

    /// Калімба: чисте тіло + короткий неґармонійний «дзень» (≈6,2×) і тихий обертон ≈3×.
    mutating func kalimba(_ f: Double, at t0: Double, amp: Double, decay: Double, pan: Double = 0) {
        let hold = Synth.holdFor(decay)
        render(at: t0, amp: amp, pan: pan, until: hold + 0.6, hold: hold) { t, k in
            let w = 2 * Double.pi * f * k * t
            let env = (1 - exp(-t / 0.0015)) * exp(-t / decay)
            return (sin(w) + 0.32 * exp(-t / 0.018) * sin(6.2 * w) + 0.1 * exp(-t / 0.06) * sin(2.98 * w)) * env / 1.2
        }
    }

    /// Крапля: висота за ~20 мс підскакує (rise > 0) чи падає (rise < 0), як у бульбашки; коротке згасання.
    mutating func drop(_ f: Double, at t0: Double, amp: Double, decay: Double, rise: Double = 0.45, pan: Double = 0) {
        let tau = 0.02
        render(at: t0, amp: amp, pan: pan, until: decay * 6 + 0.1, hold: decay * 4) { t, k in
            let phase = 2 * Double.pi * f * k * (t - rise * tau * (1 - exp(-t / tau)))
            return sin(phase) * (1 - exp(-t / 0.001)) * exp(-t / decay)
        }
    }

    /// М'який аналоговий звук: дві розстроєні «пилки» → фільтр, що закривається (3,2 кГц → 0,7 кГц).
    /// `bend` > 0 — нота починається вище і сповзає вниз (для помилки).
    mutating func analog(_ f: Double, at t0: Double, amp: Double, decay: Double, pan: Double = 0, bend: Double = 0) {
        let s0 = Int(t0 * Synth.sr)
        let hold = Synth.holdFor(decay)
        let end = min(n, s0 + Int((hold + 0.6) * Synth.sr))
        guard s0 < end else { return }
        let (gl, gr) = Synth.gains(pan, amp)
        var p1 = 0.0, p2 = 0.0
        var lowL = 0.0, bandL = 0.0, lowR = 0.0, bandR = 0.0
        func saw(_ p: Double) -> Double {
            var s = 0.0
            for h in 1...10 { s += sin(Double(h) * p) / Double(h) }
            return s * 0.55
        }
        for i in s0..<end {
            let t = Double(i - s0) / Synth.sr
            let fb = f * (1 + bend * exp(-t / 0.05))
            p1 += 2 * Double.pi * fb * 0.996 / Synth.sr
            p2 += 2 * Double.pi * fb * 1.004 / Synth.sr
            let a = saw(p1), b = saw(p2)
            let cutoff = 700 + 2500 * exp(-t / 0.08)
            let fc = 2 * sin(Double.pi * cutoff / Synth.sr)
            let xl = 0.65 * a + 0.35 * b, xr = 0.35 * a + 0.65 * b
            lowL += fc * bandL; bandL += fc * (xl - lowL - 0.7 * bandL)
            lowR += fc * bandR; bandR += fc * (xr - lowR - 0.7 * bandR)
            let release = t < hold ? 1 : exp(-(t - hold) / 0.09)
            let env = (1 - exp(-t / 0.004)) * exp(-t / decay) * release
            L[i] += Float(lowL * env * gl)
            R[i] += Float(lowR * env * gr)
        }
    }

    /// Щипок струни (Karplus–Strong): згладжений шум у петлі затримки; `bright` — наскільки дзвінкий удар.
    mutating func pluck(_ f: Double, at t0: Double, amp: Double, damping: Double = 0.996, bright: Double = 0.3, pan: Double = 0) {
        let s0 = Int(t0 * Synth.sr)
        guard s0 < n else { return }
        let size = max(2, Int(Synth.sr / f - 0.5))
        var buf = [Double](repeating: 0, count: size)
        var seed = UInt32(truncatingIfNeeded: Int(f * 1000)) | 1
        var prev = 0.0
        for i in 0..<size {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let r = Double(seed) / Double(UInt32.max) * 2 - 1
            prev += (0.25 + 0.75 * bright) * (r - prev)
            buf[i] = prev
        }
        let mean = buf.reduce(0, +) / Double(size)
        for i in 0..<size { buf[i] -= mean }
        let (gl, gr) = Synth.gains(pan, amp)
        var idx = 0
        for j in 0..<min(n - s0, Int(1.2 * Synth.sr)) {
            let a = buf[idx], b = buf[(idx + 1) % size]
            buf[idx] = damping * 0.5 * (a + b)
            idx = (idx + 1) % size
            let t = Double(j) / Synth.sr
            let release = t < 0.4 ? 1 : exp(-(t - 0.4) / 0.09)
            let attack = 1 - exp(-t / 0.001)
            L[s0 + j] += Float(a * gl * release * attack)
            R[s0 + j] += Float(a * gr * release * attack)
        }
    }

    /// Тихе клацання: коротенький тон + м'який низький поштовх.
    mutating func tick(_ f: Double, at t0: Double, amp: Double, pan: Double = 0) {
        render(at: t0, amp: amp, pan: pan, until: 0.09, hold: 0.06) { t, k in
            let w = 2 * Double.pi * f * k * t
            return 0.7 * sin(w) * exp(-t / 0.0035) + 0.5 * sin(w / 8) * exp(-t / 0.012) * (1 - exp(-t / 0.001))
        }
    }

    mutating func sine(_ f: Double, at t0: Double, amp: Double, decay: Double) {
        render(at: t0, amp: amp, pan: 0, until: decay * 1.2 + 0.6, hold: decay * 1.2) { t, k in
            sin(2 * Double.pi * f * k * t) * (1 - exp(-t / 0.004)) * exp(-t / decay)
        }
    }

    /// Простір (спрощений Freeverb: 4 гребінчасті + 2 всепропускні фільтри на канал), м'який зріз верхів,
    /// легке «тепле» насичення, обрізка тиші в кінці, згасання без клацання, гучність до `peak`.
    func finish(wet: Double, room: Double, peak: Float) -> Data {
        var l = L, r = R
        let mono = (0..<n).map { (L[$0] + R[$0]) * 0.5 }
        let scale = Synth.sr / 44100
        let combs = [1116, 1188, 1277, 1356].map { Int(Double($0) * scale) }
        let alls = [556, 441].map { Int(Double($0) * scale) }
        let spread = Int(23 * scale)
        let fb = Float(0.70 + 0.28 * room), damp: Float = 0.35
        func tail(_ shift: Int) -> [Float] {
            var y = [Float](repeating: 0, count: n)
            for d0 in combs {
                let d = d0 + shift
                var buf = [Float](repeating: 0, count: d), idx = 0, store: Float = 0
                for i in 0..<n {
                    let out = buf[idx]
                    store = out * (1 - damp) + store * damp
                    buf[idx] = mono[i] + store * fb
                    idx = (idx + 1) % d
                    y[i] += out
                }
            }
            for d0 in alls {
                let d = d0 + shift
                var buf = [Float](repeating: 0, count: d), idx = 0
                for i in 0..<n {
                    let bo = buf[idx]
                    buf[idx] = y[i] + bo * 0.5
                    y[i] = bo - y[i]
                    idx = (idx + 1) % d
                }
            }
            return y
        }
        func rms(_ a: [Float]) -> Float { sqrt(a.reduce(0) { $0 + $1 * $1 } / Float(max(1, a.count))) }
        let dryRMS = max(rms(l), rms(r))
        let tl = tail(0), tr = tail(spread)
        let g = dryRMS / max(1e-9, max(rms(tl), rms(tr))) * Float(wet)
        for i in 0..<n {
            l[i] += tl[i] * g
            r[i] += tr[i] * g
        }
        // м'який зріз вище ~9 кГц
        let a = Float(1 - exp(-2 * Double.pi * 9000 / Synth.sr))
        var yl: Float = 0, yr: Float = 0
        for i in 0..<n {
            yl += a * (l[i] - yl); l[i] = yl
            yr += a * (r[i] - yr); r[i] = yr
        }
        // тепле насичення, далі гучність до peak
        var mx: Float = 1e-9
        for i in 0..<n { mx = max(mx, abs(l[i]), abs(r[i])) }
        let drive: Float = 1.15, norm = tanh(drive)
        var mx2: Float = 1e-9
        for i in 0..<n {
            l[i] = tanh(drive * l[i] / mx) / norm
            r[i] = tanh(drive * r[i] / mx) / norm
            mx2 = max(mx2, abs(l[i]), abs(r[i]))
        }
        let k = peak / mx2
        // обрізати тишу в кінці (нижче −56 дБ) і загасити останні 120 мс
        var last = n - 1
        while last > 0 && abs(l[last]) * k < 0.0016 && abs(r[last]) * k < 0.0016 { last -= 1 }
        let len = min(n, last + Int(0.01 * Synth.sr))
        let fade = min(len, Int(0.12 * Synth.sr))
        var pcm = [Int16](repeating: 0, count: len * 2)
        for i in 0..<len {
            let f: Float = i >= len - fade ? Float(len - i) / Float(fade) : 1
            pcm[2 * i] = Int16(max(-1, min(1, l[i] * k * f)) * 32767)
            pcm[2 * i + 1] = Int16(max(-1, min(1, r[i] * k * f)) * 32767)
        }
        let bytes = pcm.count * 2, rate = Int(Synth.sr)
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(le32(36 + bytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(le32(16)); d.append(le16(1)); d.append(le16(2))
        d.append(le32(rate)); d.append(le32(rate * 4)); d.append(le16(4)); d.append(le16(16))
        d.append(contentsOf: Array("data".utf8)); d.append(le32(bytes))
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
