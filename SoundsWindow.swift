// Вікно «Звуки»: кожен набір — рядок, як пресет у студійному синтезаторі. Чотири «пади» в рядку
// (старт, стоп, помилка, скасування) — натиснув і почув; пад світиться, поки звучить.
// Клік по рядку — обрати набір (і одразу почути старт і стоп). Угорі — гучність.
// Клавіші: ↑↓ — попередній/наступний набір (одразу звучить), пробіл — послухати ще раз, Esc — закрити.
import AppKit
import SwiftUI

final class SoundLab: ObservableObject {
    @Published private(set) var selected: SoundSet
    @Published var volume: Double
    @Published private(set) var playing: String?          // «warm.start»
    var audition: (SoundSet, Cue) -> Double = { _, _ in 0 }
    var onChoose: (SoundSet) -> Void = { _ in }
    var onVolume: (Double) -> Void = { _ in }
    var onVolumeEnd: () -> Void = {}
    private var clearWork: DispatchWorkItem?
    private var stopWork: DispatchWorkItem?

    init(selected: SoundSet, volume: Double) {
        self.selected = selected
        self.volume = volume
    }

    static func key(_ s: SoundSet, _ c: Cue) -> String { s.rawValue + "." + c.rawValue }

    func play(_ s: SoundSet, _ c: Cue) {
        let d = audition(s, c)
        let k = Self.key(s, c)
        clearWork?.cancel()
        playing = d > 0 ? k : nil
        let w = DispatchWorkItem { [weak self] in
            if self?.playing == k { self?.playing = nil }
        }
        clearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.3, min(d, 1.1)), execute: w)
    }

    /// Обрати набір і одразу почути: старт, за мить стоп.
    func choose(_ s: SoundSet) {
        stopWork?.cancel()
        selected = s
        onChoose(s)
        guard s != .off else { return }
        play(s, .start)
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.selected == s else { return }
            self.play(s, .stop)
        }
        stopWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: w)
    }

    func step(_ d: Int) {
        let all = SoundSet.allCases
        let i = all.firstIndex(of: selected) ?? 0
        choose(all[min(all.count - 1, max(0, i + d))])
    }
}

struct SoundsView: View {
    @ObservedObject var lab: SoundLab
    var snapshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 30)
                .padding(.top, 46)
                .padding(.bottom, 18)
            if snapshot {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { list }
                    .clipped()
            } else {
                ScrollView { list.padding(.bottom, 12) }
            }
            keys
        }
        .frame(minWidth: 780, minHeight: 560)
        .background(StudioBackdrop(solid: snapshot))
        .ignoresSafeArea(edges: .top)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    LogoMark().frame(width: 22, height: 22)
                    Text("Voice").font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.ash.color)
                }
                Text("Звуки")
                    .font(.system(size: 30, weight: .semibold, design: .serif))
                    .foregroundColor(Palette.paper.color)
                    .padding(.top, 4)
                Text("Натисни на звук, щоб почути його. Обраний набір звучить на початку й наприкінці диктовки, а також при помилці.")
                    .font(.system(size: 12.5))
                    .foregroundColor(Palette.ash.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440, alignment: .leading)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 8) {
                Text("Гучність").font(.system(size: 12, weight: .semibold)).foregroundColor(Palette.ash.color)
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").font(.system(size: 11)).foregroundColor(Palette.ash.color)
                    WarmSlider(value: Binding(get: { lab.volume }, set: { v in lab.volume = v; lab.onVolume(v) }),
                               onEnd: { lab.onVolumeEnd() })
                        .frame(width: 150)
                    Text("\(Int((lab.volume * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundColor(Palette.paper.color.opacity(0.85))
                        .frame(width: 38, alignment: .trailing)
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var list: some View {
        VStack(spacing: 4) {
            ForEach(SoundSet.allCases, id: \.self) { s in
                SetRow(set: s, lab: lab)
            }
        }
        .padding(.horizontal, 18)
    }

    private var keys: some View {
        HStack(spacing: 16) {
            HStack(spacing: 7) { KeyCap(text: "↑↓"); Text("інший набір") }
            HStack(spacing: 7) { KeyCap(text: "пробіл"); Text("послухати ще раз") }
            HStack(spacing: 7) { KeyCap(text: "Esc"); Text("закрити") }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundColor(Palette.ash.color)
        .padding(.horizontal, 30)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Palette.paper.color.opacity(0.06)).frame(height: 1) }
    }
}

private struct SetRow: View {
    let set: SoundSet
    @ObservedObject var lab: SoundLab
    @State private var hover = false

    private var selected: Bool { lab.selected == set }

    var body: some View {
        HStack(spacing: 14) {
            node
            VStack(alignment: .leading, spacing: 3) {
                Text(set.title)
                    .font(.system(size: 17, weight: .semibold, design: .serif))
                    .foregroundColor(Palette.paper.color)
                Text(set.note)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.ash.color)
                    .lineLimit(2)
            }
            Spacer(minLength: 10)
            if set != .off {
                HStack(spacing: 6) {
                    ForEach(Cue.allCases, id: \.self) { c in
                        Pad(cue: c, playing: lab.playing == SoundLab.key(set, c)) { lab.play(set, c) }
                    }
                }
                .fixedSize()
                .layoutPriority(1)
            }
            choose.frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.amber.color.opacity(0.16), Palette.amber.color.opacity(0.04)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.amber.color.opacity(0.25)))
            } else if hover {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.paper.color.opacity(0.035))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { lab.choose(set) }
        .onHover { hover = $0 }
    }

    @ViewBuilder private var node: some View {
        if selected {
            Circle().fill(Palette.amber.color).frame(width: 11, height: 11)
                .shadow(color: Palette.amber.color.opacity(0.8), radius: 6)
                .frame(width: 14)
        } else {
            Circle().strokeBorder(Palette.dim.color, lineWidth: 1.6).frame(width: 11, height: 11).frame(width: 14)
        }
    }

    @ViewBuilder private var choose: some View {
        if selected {
            HStack(spacing: 5) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                Text("Обрано").font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundColor(Palette.amber.color)
        } else {
            Button { lab.choose(set) } label: {
                Text("Обрати")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(Palette.paper.color.opacity(hover ? 1 : 0.8))
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(Capsule().fill(Palette.paper.color.opacity(hover ? 0.11 : 0.06)))
                    .overlay(Capsule().strokeBorder(Palette.paper.color.opacity(0.08)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Пад одного звуку: натиснув — звучить; поки звучить — світиться бурштином і «грає» стовпчиками.
private struct Pad: View {
    let cue: Cue
    let playing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if playing {
                    MiniMeter().frame(width: 10, height: 10)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 8.5, weight: .bold)).frame(width: 10)
                }
                Text(cue.title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(playing ? Palette.smoke.color : Palette.paper.color.opacity(hover ? 1 : 0.82))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                Capsule().fill(playing
                    ? AnyShapeStyle(LinearGradient(colors: [Palette.filament.color, Palette.amber.color], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(Palette.paper.color.opacity(hover ? 0.11 : 0.06)))
            )
            .overlay(Capsule().strokeBorder(Palette.paper.color.opacity(playing ? 0 : 0.08)))
            .shadow(color: Palette.amber.color.opacity(playing ? 0.5 : 0), radius: 10)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Послухати: \(cue.title.lowercased())")
        .onHover { hover = $0 }
    }
}

private struct MiniMeter: View {
    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(Palette.smoke.color)
                        .frame(width: 2, height: 3 + 7 * CGFloat(0.5 + 0.5 * sin(t * 14 - Double(i) * 1.1)))
                }
            }
        }
    }
}

/// Повзунок у кольорах Voice (власний — щоб виглядав як решта вікна й малювався в PNG).
struct WarmSlider: View {
    @Binding var value: Double
    var onEnd: () -> Void = {}

    var body: some View {
        GeometryReader { g in
            let w = max(1, g.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.paper.color.opacity(0.1)).frame(height: 4)
                Capsule()
                    .fill(LinearGradient(colors: [Palette.ember.color, Palette.amber.color, Palette.filament.color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, w * value), height: 4)
                Circle()
                    .fill(Palette.paper.color)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                    .offset(x: w * value - 7)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in value = clamp01(Double(d.location.x / w)) }
                .onEnded { _ in onEnd() })
        }
        .frame(height: 20)
    }
}

final class SoundsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var monitor: Any?
    private let lab: SoundLab

    init(lab: SoundLab) {
        self.lab = lab
        super.init()
    }

    var windowNumber: Int? { window?.windowNumber }

    func show(activate: Bool = true) {
        if window == nil { build() }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func close() { window?.close() }

    private func build() {
        let w = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.title = "Voice — звуки"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 780, height: 560)
        w.isReleasedWhenClosed = false
        w.delegate = self
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        let h = NSHostingView(rootView: SoundsView(lab: lab))
        h.sizingOptions = [.minSize]
        h.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            h.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            h.topAnchor.constraint(equalTo: fx.topAnchor),
            h.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        w.contentView = fx
        if !w.setFrameUsingName("VoiceSounds") { w.center() }
        w.setFrameAutosaveName("VoiceSounds")
        window = w
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = self.window, w.isKeyWindow, e.window === w else { return e }
            guard e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return e }
            switch e.keyCode {
            case 125: self.lab.step(1); return nil                     // ↓
            case 126: self.lab.step(-1); return nil                    // ↑
            case 49, 36, 76: self.lab.choose(self.lab.selected); return nil   // пробіл, Return
            default: return e
            }
        }
    }
}
