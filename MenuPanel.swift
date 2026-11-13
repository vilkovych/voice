// Панель Voice під значком у смужці меню — замість стандартного сірого меню macOS.
// Угорі — стан і шестірня налаштувань. Далі остання диктовка: її «відбиток голосу» (спектр усього запису
// тим самим жаром, що й у смужці; при відкритті прогорає зліва направо), текст книжковим шрифтом
// і кнопки «Копіювати» / «Вставити». Нижче — попередні диктовки (клік копіює), історія, підказка клавіш, вихід.
// Esc або клік деінде — закрити. Правий клік по значку — старе системне меню (про запас).
//
// Панель не активує Voice: програма, в якій ти друкуєш, лишається попереду, тож «Вставити» вставляє туди.
import AppKit
import SwiftUI

enum MenuPage { case main, settings }

final class MenuModel: ObservableObject {
    @Published var phase = Phase.idle
    @Published var recStart = 0.0                  // monoNow() початку запису
    @Published var axTrusted = true
    @Published var micOK = true
    @Published var trigger = TriggerKey.rightShift
    @Published var style = BarStyle.spectrum
    @Published var soundTitle = ""
    @Published var copiedId: String?
    @Published var page = MenuPage.main
    @Published private(set) var openedAt = -10.0
    @Published private(set) var burnDone = true    // відбиток догорів — анімацію зупинено
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var burnGen = 0

    static let burnIn = 0.62                       // скільки прогорає відбиток при відкритті

    func opened() {
        burnGen += 1
        let g = burnGen
        openedAt = monoNow()
        burnDone = false
        // після прогоряння — зупинити анімацію, щоб не їла процесор, поки панель відкрита
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burnIn + 0.15) { [weak self] in
            guard let self, self.burnGen == g else { return }
            self.burnDone = true
        }
    }
}

struct MenuActions {
    var copy: (Entry) -> Void = { _ in }
    var paste: (Entry) -> Void = { _ in }
    var retry: (Entry) -> Void = { _ in }
    var openHistory: (Entry?) -> Void = { _ in }
    var setTrigger: (TriggerKey) -> Void = { _ in }
    var setStyle: (BarStyle) -> Void = { _ in }
    var openSounds: () -> Void = {}
    var openPermissions: () -> Void = {}
    var stop: () -> Void = {}
    var cancel: () -> Void = {}
    var quit: () -> Void = {}
}

extension TriggerKey {
    /// Значок клавіші для підказок: ⇧ або ⌥.
    var glyph: String { family == .maskShift ? "⇧" : "⌥" }
    var shortTitle: String {
        switch id {
        case "rshift": return "Правий ⇧"
        case "ropt": return "Правий ⌥"
        default: return "Будь-який ⌥"
        }
    }
}

// MARK: - Відбитки голосу (спектр усього запису)

final class TakeSpectra: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var order: [String] = []                // пам'ятаємо лише кілька останніх
    private var pending: Set<String> = []
    private var missing: Set<String> = []
    private let queue = DispatchQueue(label: "voice.spectra", qos: .userInitiated)
    private static let keep = 8

    private func store(_ id: String, _ img: CGImage) {
        images[id] = img
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > Self.keep { images[order.removeFirst()] = nil }
    }

    func get(_ e: Entry) -> CGImage? {
        if let i = images[e.id] { return i }
        request(e)
        return nil
    }

    func request(_ e: Entry) {
        guard !e.busy, let f = e.audioFile, images[e.id] == nil, !pending.contains(e.id), !missing.contains(e.id) else { return }
        pending.insert(e.id)
        let id = e.id
        queue.async { [weak self] in
            let img = TakeSpectrum.image(f)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending.remove(id)
                if let img { self.store(id, img) } else { self.missing.insert(id) }
            }
        }
    }

    /// Для --png: одразу, без фону.
    func preload(_ e: Entry) {
        if let f = e.audioFile, let i = TakeSpectrum.image(f) { store(e.id, i) }
    }
}

// MARK: - Вигляд

struct MenuView: View {
    @ObservedObject var model: MenuModel
    @ObservedObject var store: HistoryStore
    @ObservedObject var ui: HistoryUI
    @ObservedObject var spectra: TakeSpectra
    var actions: MenuActions
    var snapshot = false

    static let width: CGFloat = 360

    /// Що показує панель: розпізнані й нерозпізнані диктовки (без тиші, скасованих і тих, що ще йдуть).
    static func takes(_ entries: [Entry], limit: Int = 5) -> [Entry] {
        Array(entries.lazy.filter { e in
            switch e.status {
            case .pasted, .copied, .ready: return e.hasText
            case .failed: return true
            default: return false
            }
        }.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.page == .main {
                mainPage.transition(.opacity)
            } else {
                settingsPage.transition(.opacity)
            }
            footer
        }
        .frame(width: Self.width)
        .background(MenuBackdrop())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.paper.color.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private var needsPermission: Bool { !model.axTrusted || !model.micOK }

    private func setPage(_ p: MenuPage) {
        withAnimation(model.reduceMotion ? nil : .easeOut(duration: 0.16)) { model.page = p }
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 8) {
            LogoMark().frame(width: 20, height: 20)
            Text("Voice").font(.system(size: 13.5, weight: .semibold)).foregroundColor(Palette.paper.color)
            Spacer(minLength: 8)
            if model.page == .main {
                StatusChip(model: model, needsPermission: needsPermission, snapshot: snapshot)
                IconButton(icon: "gearshape", help: "Налаштування") { setPage(.settings) }
            } else {
                DoneButton { setPage(.main) }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    // MARK: Головна сторінка

    private var mainPage: some View {
        let list = Self.takes(store.entries)
        return VStack(alignment: .leading, spacing: 0) {
            if needsPermission { permission }
            if model.phase == .recording { recordingControls }
            if let first = list.first {
                Featured(e: first, image: spectra.get(first), copied: model.copiedId == first.id,
                         retrying: ui.retrying.contains(first.id), openedAt: model.openedAt,
                         animate: !snapshot && !model.reduceMotion && !model.burnDone, actions: actions)
            } else {
                empty
            }
            if list.count > 1 {
                divider
                VStack(spacing: 0) {
                    ForEach(list.dropFirst()) { e in
                        OlderRow(e: e, copied: model.copiedId == e.id) {
                            if e.hasText { actions.copy(e) } else { actions.openHistory(e) }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            divider
            HistoryRow(summary: summary) { actions.openHistory(nil) }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        }
    }

    private var permission: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(!model.axTrusted ? "Немає дозволу «Універсальний доступ»" : "Немає дозволу на мікрофон")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Palette.signal.color)
            Text(!model.axTrusted ? "Без нього Voice не чує клавіш і не вставляє текст." : "Без нього Voice не чує голосу.")
                .font(.system(size: 12))
                .foregroundColor(Palette.ash.color)
                .fixedSize(horizontal: false, vertical: true)
            GhostButton(title: "Відкрити налаштування дозволів", icon: "lock.open", height: 28) { actions.openPermissions() }
                .padding(.top, 5)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.signal.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.signal.color.opacity(0.25)))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var recordingControls: some View {
        HStack(spacing: 8) {
            PrimaryButton(title: "Зупинити", key: model.trigger.glyph, icon: "stop.fill", height: 30) { actions.stop() }
            GhostButton(title: "Скасувати", icon: "xmark", key: "Esc", height: 30) { actions.cancel() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            TakeStrip(image: nil, dim: false, openedAt: 0, animate: false).frame(height: 44)
            Text("Тут з'явиться остання диктовка")
                .font(.system(size: 15, design: .serif))
                .foregroundColor(Palette.paper.color.opacity(0.92))
                .padding(.top, 12)
            Text("Двічі натисни \(model.trigger.title), говори, а тоді натисни його ще раз.")
                .font(.system(size: 12))
                .foregroundColor(Palette.ash.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var summary: String {
        let nb = "\u{00A0}"                                         // число не відривається від слова
        func takes(_ n: Int) -> String { "\(n)\(nb)\(uaPlural(n, "диктовка", "диктовки", "диктовок"))" }
        let withText = store.entries.filter { $0.hasText && $0.status != .discarded }
        let today = withText.filter { Calendar.current.isDateInToday($0.ts) }
        if !today.isEmpty {
            let w = today.reduce(0) { $0 + $1.words }
            return "Сьогодні \(takes(today.count)), \(groupDigits(w))\(nb)\(uaPlural(w, "слово", "слова", "слів"))"
        }
        return withText.isEmpty ? "Тут збиратимуться всі диктовки" : "Усього \(takes(withText.count))"
    }

    // MARK: Налаштування

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingBlock(title: "Клавіша для диктовки", note: "Двічі — почати, ще раз — зупинити.") {
                Segmented(options: TriggerKey.all.map { SegOption(id: $0.id, title: $0.shortTitle) },
                          selected: model.trigger.id, reduceMotion: model.reduceMotion) { id in
                    actions.setTrigger(TriggerKey.byId(id))
                }
            }
            SettingBlock(title: "Вигляд смужки", note: "Натисни — і смужка покажеться внизу екрана.") {
                Segmented(options: BarStyle.allCases.map { SegOption(id: $0.rawValue, title: $0.title) },
                          selected: model.style.rawValue, reduceMotion: model.reduceMotion) { raw in
                    if let s = BarStyle(rawValue: raw) { actions.setStyle(s) }
                }
            }
            SettingBlock(title: "Звуки", note: nil) {
                FieldButton(title: model.soundTitle.isEmpty ? "Обрати" : model.soundTitle,
                            detail: "Послухати всі") { actions.openSounds() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 18)
    }

    // MARK: Низ

    private var footer: some View {
        let g = model.trigger.glyph
        return HStack(spacing: 6) {
            KeyCap(text: "\(g) \(g)")
            Text("почати")
            KeyCap(text: g).padding(.leading, 6)
            Text("стоп")
            KeyCap(text: "Esc").padding(.leading, 6)
            Text("скасувати")
            Spacer(minLength: 8)
            QuitButton { actions.quit() }
        }
        .font(.system(size: 11.5))
        .foregroundColor(Palette.ash.color)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 42)
        .overlay(alignment: .top) { Rectangle().fill(Palette.paper.color.opacity(0.07)).frame(height: 1) }
    }

    private var divider: some View {
        Rectangle().fill(Palette.paper.color.opacity(0.07)).frame(height: 1).padding(.horizontal, 16)
    }
}

// MARK: - Частини

/// Стан праворуч у шапці: «Готовий» / «Записую 0:07» / «Розпізнаю…» / «Потрібен дозвіл».
private struct StatusChip: View {
    @ObservedObject var model: MenuModel
    let needsPermission: Bool
    let snapshot: Bool

    var body: some View {
        HStack(spacing: 6) {
            dot.frame(width: 10, height: 10)
            label
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundColor(Palette.paper.color.opacity(0.8))
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(Capsule().fill(Palette.paper.color.opacity(0.055)))
    }

    @ViewBuilder private var dot: some View {
        if needsPermission {
            Circle().fill(Palette.signal.color).frame(width: 7, height: 7)
        } else {
            switch model.phase {
            case .idle:
                Circle().fill(Palette.amber.color).frame(width: 7, height: 7)
                    .shadow(color: Palette.amber.color.opacity(0.8), radius: 4)
            case .recording:
                PulseDot(tint: Palette.amber).scaleEffect(0.8)
            case .transcribing:
                Spinner(size: 9, tint: Palette.amber)
            }
        }
    }

    @ViewBuilder private var label: some View {
        if needsPermission {
            Text("Потрібен дозвіл")
        } else {
            switch model.phase {
            case .idle:
                Text("Готовий")
            case .recording:
                if snapshot {
                    Text("Записую 0:07")
                } else {
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        Text("Записую \(clock(monoNow() - model.recStart))")
                    }
                }
            case .transcribing:
                Text("Розпізнаю…")
            }
        }
    }
}

/// Остання диктовка: відбиток голосу, коли й де, текст, дії.
private struct Featured: View {
    let e: Entry
    let image: CGImage?
    let copied: Bool
    let retrying: Bool
    let openedAt: Double
    let animate: Bool
    let actions: MenuActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TakeStrip(image: image, dim: e.status == .failed, openedAt: openedAt, animate: animate)
                .frame(height: 44)
            HStack(spacing: 6) {
                Text(Fmt.time.string(from: e.ts))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(Palette.filament.color)
                AppIconView(bundle: e.appBundle).frame(width: 14, height: 14).padding(.leading, 6)
                Text(e.appName ?? "Невідома програма")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.ash.color)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(e.hasText ? wordsText(e.words) : clock(e.audioS.rounded()))
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundColor(Palette.ash.color)
            }
            .padding(.top, 11)
            if e.hasText {
                Text(oneLine(e.text))
                    .font(.system(size: 15, design: .serif))
                    .foregroundColor(Palette.paper.color.opacity(0.95))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
            } else {
                Text("Не розпізналось: \((e.error ?? "невідома причина").lowercased())")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.signal.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 7)
                Text(e.hasAudio ? "Запис збережено — можна розпізнати ще раз." : "Звуку цієї диктовки вже немає.")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.ash.color)
                    .padding(.top, 3)
            }
            HStack(spacing: 8) {
                if e.hasText {
                    PrimaryButton(title: copied ? "Скопійовано" : "Копіювати", key: copied ? nil : "⌃⌥C",
                                  icon: copied ? "checkmark" : "doc.on.doc", height: 30) { actions.copy(e) }
                    GhostButton(title: "Вставити", icon: "character.cursor.ibeam", key: "⌃⌥V", height: 30) { actions.paste(e) }
                } else {
                    if e.hasAudio {
                        PrimaryButton(title: retrying ? "Розпізнаю…" : "Спробувати ще", key: nil, icon: "arrow.clockwise",
                                      height: 30) { if !retrying { actions.retry(e) } }
                    }
                    GhostButton(title: "В історії", icon: "clock", height: 30) { actions.openHistory(e) }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 13)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

/// Віконце з відбитком голосу: темна «ніша», як дисплей на студійному пульті. При відкритті панелі
/// відбиток прогорає зліва направо, попереду йде світла головка — та сама, що в смужці під час запису.
private struct TakeStrip: View {
    let image: CGImage?
    let dim: Bool
    let openedAt: Double
    let animate: Bool

    var body: some View {
        // кадр залежить від `p`, тож SwiftUI перемальовує його на кожному тіку (як BarFrame у смужці)
        TimelineView(.animation(minimumInterval: nil, paused: !animate)) { _ in
            StripCanvas(image: image, dim: dim, p: animate ? clamp01((monoNow() - openedAt) / MenuModel.burnIn) : 1)
        }
    }
}

private struct StripCanvas: View {
    let image: CGImage?
    let dim: Bool
    let p: Double                                   // 0…1 — скільки відбитка вже прогоріло

    var body: some View {
        Canvas { c, size in draw(&c, size) }
    }

    private func draw(_ c: inout GraphicsContext, _ size: CGSize) {
        let r = CGRect(origin: .zero, size: size)
        let well = Path(roundedRect: r, cornerRadius: 10, style: .continuous)
        c.fill(well, with: .color(Color.black.opacity(0.34)))
        if let img = image {
            let x = size.width * CGFloat(easeOut(p))
            var l = c
            l.clip(to: well)
            l.drawLayer { k in
                k.clip(to: Path(CGRect(x: 0, y: 0, width: x, height: size.height)))
                let pic = Image(decorative: img, scale: 1).interpolation(.high)
                let rect = r.insetBy(dx: 0, dy: 3)
                // під відбитком — розмите свічення, як від розжареної нитки
                var glow = k
                glow.addFilter(.blur(radius: 5))
                glow.opacity = dim ? 0.3 : 0.75
                glow.draw(pic, in: rect)
                k.opacity = dim ? 0.45 : 1
                k.draw(pic, in: rect)
                // краї віконця гаснуть, щоб відбиток не обрізався різко
                k.blendMode = .destinationOut
                k.opacity = 1
                let f: CGFloat = 18, fv: CGFloat = 8
                k.fill(Path(CGRect(x: 0, y: 0, width: f, height: size.height)),
                       with: .linearGradient(Gradient(colors: [.black, .clear]), startPoint: .zero, endPoint: CGPoint(x: f, y: 0)))
                k.fill(Path(CGRect(x: size.width - f, y: 0, width: f, height: size.height)),
                       with: .linearGradient(Gradient(colors: [.clear, .black]),
                                             startPoint: CGPoint(x: size.width - f, y: 0), endPoint: CGPoint(x: size.width, y: 0)))
                k.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: fv)),
                       with: .linearGradient(Gradient(colors: [.black.opacity(0.9), .clear]), startPoint: .zero, endPoint: CGPoint(x: 0, y: fv)))
                k.fill(Path(CGRect(x: 0, y: size.height - fv, width: size.width, height: fv)),
                       with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.9)]),
                                             startPoint: CGPoint(x: 0, y: size.height - fv), endPoint: CGPoint(x: 0, y: size.height)))
            }
            if p < 1 {
                let a = 1 - smooth01((p - 0.7) / 0.3)                 // головка згасає наприкінці
                var g = l
                g.addFilter(.blur(radius: 3))
                g.fill(Path(CGRect(x: x - 1.5, y: 5, width: 3, height: size.height - 10)),
                       with: .color(Palette.amber.color.opacity(0.9 * a)))
                l.fill(Path(roundedRect: CGRect(x: x - 0.75, y: 7, width: 1.5, height: size.height - 14), cornerRadius: 0.75),
                       with: .color(Palette.filament.color.opacity(a)))
            }
        } else {
            c.fill(Path(CGRect(x: 14, y: size.height / 2 - 0.5, width: size.width - 28, height: 1)),
                   with: .color(Palette.paper.color.opacity(0.08)))
        }
        c.stroke(well, with: .color(Palette.paper.color.opacity(0.06)), lineWidth: 1)
    }

    private func smooth01(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }
}

/// Попередня диктовка одним рядком: час і початок тексту. Клік — скопіювати (нерозпізнана — відкрити в історії).
private struct OlderRow: View {
    let e: Entry
    let copied: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(Fmt.time.string(from: e.ts))
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundColor(Palette.ash.color)
                    .frame(width: 36, alignment: .leading)
                if copied {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                        Text("Скопійовано").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundColor(Palette.amber.color)
                    .transition(.opacity)
                } else if e.hasText {
                    Text(oneLine(e.text))
                        .font(.system(size: 13.5, design: .serif))
                        .foregroundColor(Palette.paper.color.opacity(hover ? 0.97 : 0.8))
                        .lineLimit(1)
                } else {
                    Text("Не розпізналось: \((e.error ?? "невідома причина").lowercased())")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Palette.signal.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.paper.color.opacity(hover ? 0.055 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(e.hasText ? "Скопіювати" : "Відкрити в історії")
    }
}

private struct HistoryRow: View {
    let summary: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Відкрити історію")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Palette.paper.color.opacity(hover ? 1 : 0.9))
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundColor(Palette.ash.color)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                KeyCap(text: "⌃⌥H")
            }
            .padding(.horizontal, 10)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.paper.color.opacity(hover ? 0.055 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct SettingBlock<Content: View>: View {
    let title: String
    let note: String?
    let content: Content

    init(title: String, note: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundColor(Palette.paper.color.opacity(0.9))
            content
            if let note {
                Text(note).font(.system(size: 11.5)).foregroundColor(Palette.ash.color)
            }
        }
    }
}

private struct SegOption: Identifiable {
    let id: String
    let title: String
}

/// Перемикач з кількох варіантів: бурштинова плашка перебігає під обраний.
private struct Segmented: View {
    let options: [SegOption]
    let selected: String
    let reduceMotion: Bool
    let pick: (String) -> Void
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { o in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) { pick(o.id) }
                } label: {
                    Text(o.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(o.id == selected ? Palette.smoke.color : Palette.paper.color.opacity(0.75))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if o.id == selected {
                                Capsule().fill(Palette.amber.color).matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Palette.paper.color.opacity(0.05)))
        .overlay(Capsule().strokeBorder(Palette.paper.color.opacity(0.08)))
    }
}

private struct FieldButton: View {
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundColor(Palette.amber.color)
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundColor(Palette.paper.color.opacity(0.92))
                Spacer(minLength: 6)
                Text(detail).font(.system(size: 11.5)).foregroundColor(Palette.ash.color)
                Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold)).foregroundColor(Palette.ash.color)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(Palette.paper.color.opacity(hover ? 0.085 : 0.05)))
            .overlay(Capsule().strokeBorder(Palette.paper.color.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct IconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Palette.paper.color.opacity(hover ? 0.95 : 0.6))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.paper.color.opacity(hover ? 0.08 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct DoneButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text("Готово")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.amber.color.opacity(hover ? 1 : 0.9))
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(Capsule().fill(Palette.amber.color.opacity(hover ? 0.14 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct QuitButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(hover ? Palette.signal.color : Palette.paper.color.opacity(0.55))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.paper.color.opacity(hover ? 0.07 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Вийти з Voice")
        .accessibilityLabel("Вийти з Voice")
    }
}

/// Тло панелі: той самий теплий дим, що й у вікнах, світло лампи в куті й зерно. Непрозоре —
/// щоб крізь панель не просвічував термінал.
private struct MenuBackdrop: View {
    var body: some View {
        Palette.smoke.color
            .overlay(alignment: .topTrailing) {
                Circle().fill(Palette.amber.color.opacity(0.11)).frame(width: 300, height: 300).blur(radius: 80)
                    .offset(x: 120, y: -170)
            }
            .overlay(alignment: .bottomLeading) {
                Circle().fill(Palette.ember.color.opacity(0.06)).frame(width: 260, height: 260).blur(radius: 80)
                    .offset(x: -130, y: 150)
            }
            .overlay(Image(nsImage: Grain.image).resizable(resizingMode: .tile).opacity(0.045))
            .allowsHitTesting(false)
    }
}

private func oneLine(_ s: String?) -> String {
    (s ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Панель на екрані

private struct MenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Панель стає ключовою (для Esc), але не активує Voice — програма під нею лишається попереду.
final class MenuPanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

final class MenuPanelController {
    let model: MenuModel
    private let panel: MenuPanel
    private var host: NSHostingView<AnyView>!
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var closeWork: DispatchWorkItem?
    private var gen = 0
    private var top: CGFloat = 0
    private var lastHeight: CGFloat = 470
    private(set) var isOpen = false
    private(set) var closedAt = -10.0
    /// Прямокутник значка в смужці меню (координати екрана).
    var anchor: () -> NSRect? = { nil }
    var onOpenChange: (Bool) -> Void = { _ in }

    init(model: MenuModel, store: HistoryStore, ui: HistoryUI, spectra: TakeSpectra, actions: MenuActions) {
        self.model = model
        panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: MenuView.width, height: 470),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let root = VStack(spacing: 0) {
            MenuView(model: model, store: store, ui: ui, spectra: spectra, actions: actions)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in Color.clear.preference(key: MenuHeightKey.self, value: g.size.height) })
            Spacer(minLength: 0)
        }
        .frame(width: MenuView.width)
        .onPreferenceChange(MenuHeightKey.self) { [weak self] h in
            DispatchQueue.main.async { self?.fit(h) }
        }
        host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        panel.onResign = { [weak self] in self?.close() }
    }

    var windowNumber: Int { panel.windowNumber }

    func toggle() {
        if isOpen { close(); return }
        if monoNow() - closedAt < 0.25 { return }          // щойно закрилась цим самим кліком
        open()
    }

    /// `makeKey: false` — лише показати (для перевірки вигляду), не забираючи клавіатуру.
    func open(makeKey: Bool = true) {
        closeWork?.cancel()
        closeWork = nil
        gen += 1
        let a = anchor() ?? defaultAnchor()
        let screen = NSScreen.screens.first { $0.frame.intersects(a) } ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        let w = MenuView.width
        let fit = host.fittingSize.height
        let h = min(fit > 120 ? fit : lastHeight, vf.height - 12)
        top = min(a.minY, vf.maxY) - 6
        let x = max(vf.minX + 8, min(a.minX - 12, vf.maxX - w - 8))
        panel.setFrame(NSRect(x: x, y: top - h, width: w, height: h), display: true)
        model.opened()
        panel.alphaValue = 0
        if makeKey { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        isOpen = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = model.reduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.panel.invalidateShadow() }
        if makeKey { installMonitors() }
        onOpenChange(true)
    }

    func close(animated: Bool = true) {
        closeWork?.cancel()
        closeWork = nil
        guard isOpen else { return }
        isOpen = false
        closedAt = monoNow()
        gen += 1
        let g = gen
        removeMonitors()
        onOpenChange(false)
        let finish = { [weak self] in
            guard let self, self.gen == g else { return }
            self.panel.orderOut(nil)
            self.model.page = .main
            self.model.copiedId = nil
        }
        if animated && !model.reduceMotion {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                self.panel.animator().alphaValue = 0
            }, completionHandler: finish)
        } else {
            finish()
        }
    }

    /// Закрити трохи згодом (щоб встигнути побачити «Скопійовано»).
    func closeSoon(_ t: Double) {
        closeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: w)
    }

    /// Вміст змінив висоту — підігнати панель, тримаючи верхній край під смужкою меню.
    private func fit(_ h: CGFloat) {
        guard h > 120 else { return }
        lastHeight = h
        guard isOpen else { return }
        var f = panel.frame
        guard abs(f.height - h) > 0.5 else { return }
        f.origin.y = top - h
        f.size.height = h
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    private func defaultAnchor() -> NSRect {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        return NSRect(x: vf.maxX - 420, y: vf.maxY, width: 28, height: 24)
    }

    /// Клік у будь-якій іншій програмі (зокрема по чужому значку в смужці меню) — закрити; Esc — закрити.
    private func installMonitors() {
        removeMonitors()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.isOpen, e.window === self.panel else { return e }
            if e.keyCode == 53 { self.close(); return nil }                     // Esc
            return e
        }
    }

    private func removeMonitors() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        keyMonitor = nil
    }
}
