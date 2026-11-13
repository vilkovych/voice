// Вікно «Історія» — як вечірня студія звукозапису.
// Ліворуч — стрічка часу: кожна диктовка з часом, програмою, початком тексту і відбитком голосу;
// колір точки на стрічці каже, що з нею сталося. Праворуч — обрана диктовка: велика хвиля-програвач
// (клік чи протяг по ній — перемотати), сам текст книжковим шрифтом і дії.
// Клавіші: ↑↓ — інша диктовка, Return або ⌘C — копіювати, пробіл — слухати, ⌘F — пошук, Esc — закрити.
import AppKit
import AVFoundation
import SwiftUI

final class HistoryUI: ObservableObject {
    @Published var query = ""
    @Published var onlyFailed = false
    @Published private(set) var selectedId: String?
    @Published private(set) var selectedAt = -10.0
    @Published var toast: String?
    @Published var playingId: String?
    @Published var retrying: Set<String> = []
    @Published var focusSearch = 0
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var toastWork: DispatchWorkItem?

    func select(_ id: String?) {
        guard id != selectedId else { return }
        selectedId = id
        selectedAt = monoNow()
        // після «малювання» хвилі — ще раз перемалювати, щоб анімація зупинилась
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.objectWillChange.send() }
    }

    func flash(_ text: String) {
        toastWork?.cancel()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { toast = text }
        let w = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
        }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }
}

struct HistoryActions {
    var copy: (Entry) -> Void = { _ in }
    var retry: (Entry) -> Void = { _ in }
    var play: (Entry) -> Void = { _ in }
    var seek: (Entry, Double) -> Void = { _, _ in }
    var reveal: (Entry) -> Void = { _ in }
    var progress: () -> Double = { 0 }
    var position: () -> Double = { 0 }
}

/// Що зараз видно в списку (той самий відбір і для вікна, і для клавіш).
func visibleEntries(_ store: HistoryStore, _ ui: HistoryUI) -> [Entry] {
    let q = ui.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return store.entries.filter { e in
        e.status != .discarded
            && (!ui.onlyFailed || e.status == .failed)
            && (q.isEmpty || (e.text ?? "").lowercased().contains(q) || (e.appName ?? "").lowercased().contains(q))
    }
}

enum Fmt {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.dateFormat = "EEEE, d MMMM"
        return f
    }()
    static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "uk_UA")
        f.dateFormat = "d MMMM"
        return f
    }()

    static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Сьогодні" }
        if cal.isDateInYesterday(d) { return "Вчора" }
        let s = day.string(from: d)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// «Сьогодні о 14:57», «Вчора о 09:12», «10 листопада о 12:00».
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let day = cal.isDateInToday(d) ? "Сьогодні" : cal.isDateInYesterday(d) ? "Вчора" : shortDay.string(from: d)
        return "\(day) о \(time.string(from: d))"
    }
}

// MARK: - Відбитки голосу

/// Обриси гучності кожного запису (160 точок), рахуються у фоні з WAV і запам'ятовуються.
final class Waveforms: ObservableObject {
    @Published private(set) var peaks: [String: [Float]] = [:]
    private var pending: Set<String> = []
    private let queue = DispatchQueue(label: "voice.waves", qos: .utility)
    static let points = 160

    func get(_ e: Entry) -> [Float]? {
        if let p = peaks[e.id] { return p }
        request(e)
        return nil
    }

    private func request(_ e: Entry) {
        guard !e.busy, let f = e.audioFile, !pending.contains(e.id) else { return }
        pending.insert(e.id)
        let id = e.id
        queue.async { [weak self] in
            let p = Waveforms.compute(f)
            DispatchQueue.main.async {
                self?.pending.remove(id)
                if let p { self?.peaks[id] = p }
            }
        }
    }

    /// Для --png: одразу, без фону.
    func preload(_ list: [Entry]) {
        for e in list where !e.busy {
            if let f = e.audioFile, let p = Waveforms.compute(f) { peaks[e.id] = p }
        }
    }

    static func compute(_ path: String) -> [Float]? {
        guard let d = FileManager.default.contents(atPath: path), d.count > 44 + 64 else { return nil }
        let n = (d.count - 44) / 2
        var out = [Float](repeating: 0, count: points)
        d.withUnsafeBytes { raw in
            for b in 0..<points {
                let a = b * n / points, z = max(a + 1, (b + 1) * n / points)
                var sum = 0.0
                for i in a..<z {
                    let v = Double(raw.loadUnaligned(fromByteOffset: 44 + 2 * i, as: Int16.self))
                    sum += v * v
                }
                out[b] = Float(sqrt(sum / Double(z - a)) / 32768)
            }
        }
        let mx = max(out.max() ?? 0, 0.02)
        return out.map { pow($0 / mx, 0.95) }
    }
}

// MARK: - Вікно

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var ui: HistoryUI
    @ObservedObject var waves: Waveforms
    var actions: HistoryActions
    var triggerTitle: String
    var snapshot = false

    var body: some View {
        let list = visibleEntries(store, ui)
        let selected = list.first(where: { $0.id == ui.selectedId }) ?? list.first
        HStack(spacing: 0) {
            Sidebar(store: store, ui: ui, waves: waves, list: list, selectedId: selected?.id,
                    actions: actions, triggerTitle: triggerTitle, snapshot: snapshot)
                .frame(width: 340)
                .background(Palette.smoke2.color.opacity(snapshot ? 1 : 0.86))
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.paper.color.opacity(0.06)).frame(width: 1) }
            DetailPane(entry: selected, ui: ui, waves: waves, actions: actions, triggerTitle: triggerTitle,
                       snapshot: snapshot, isEmpty: store.entries.allSatisfy { $0.status == .discarded })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if let t = ui.toast {
                        Toast(text: t).padding(.top, 10).transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
        }
        .background(StudioBackdrop(solid: snapshot))
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 780, minHeight: 500)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Ліва панель: стрічка часу

private struct DaySection: Identifiable {
    let day: Date
    let title: String
    var items: [Entry]
    var id: Date { day }
}

private struct Sidebar: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var ui: HistoryUI
    @ObservedObject var waves: Waveforms
    let list: [Entry]
    let selectedId: String?
    let actions: HistoryActions
    let triggerTitle: String
    let snapshot: Bool
    @Namespace private var ns
    @FocusState private var searchFocused: Bool

    private var sections: [DaySection] {
        var out: [DaySection] = []
        let cal = Calendar.current
        for e in list {
            let day = cal.startOfDay(for: e.ts)
            if out.last?.day == day {
                out[out.count - 1].items.append(e)
            } else {
                out.append(DaySection(day: day, title: Fmt.dayTitle(e.ts), items: [e]))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
                .padding(.horizontal, 22)
                .padding(.top, 46)
            search
                .padding(.horizontal, 18)
                .padding(.top, 18)
            FilterSwitch(ui: ui, all: store.entries.filter { $0.status != .discarded }.count,
                         failed: store.entries.filter { $0.status == .failed }.count)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 6)
            if list.isEmpty {
                Text(ui.query.isEmpty ? (ui.onlyFailed ? "Нерозпізнаних записів немає." : "Поки що порожньо.")
                                      : "За «\(ui.query)» нічого не знайшлося.")
                    .font(.system(size: 13))
                    .foregroundColor(Palette.ash.color)
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                Spacer(minLength: 0)
            } else if snapshot {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { VStack(alignment: .leading, spacing: 0) { rows } }
                    .clipped()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) { rows }
                            .padding(.bottom, 14)
                            .animation(ui.reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86), value: store.version)
                    }
                    .onChange(of: ui.selectedId) { id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: nil) }
                    }
                }
            }
            keysHint
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                LogoMark().frame(width: 22, height: 22)
                Text("Voice").font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.ash.color)
            }
            Text("Історія")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundColor(Palette.paper.color)
                .padding(.top, 4)
            Text(summary)
                .font(.system(size: 12.5))
                .foregroundColor(Palette.ash.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: String {
        let today = store.entries.filter { $0.status != .discarded && Calendar.current.isDateInToday($0.ts) }
        guard !today.isEmpty else { return "Сьогодні ще нічого. Двічі натисни \(triggerTitle) і говори." }
        let n = today.count
        let w = today.reduce(0) { $0 + $1.words }
        let s = today.reduce(0.0) { $0 + $1.audioS }
        let nb = "\u{00A0}"                                     // число не відривається від слова
        let voice = s < 60 ? "\(Int(s))\(nb)с голосу" : "\(Int((s / 60).rounded()))\(nb)хв голосу"
        let words = wordsText(w).replacingOccurrences(of: " слов", with: "\(nb)слов").replacingOccurrences(of: " слів", with: "\(nb)слів")
        return "Сьогодні \(n)\(nb)\(uaPlural(n, "диктовка", "диктовки", "диктовок")), \(words) і \(voice)."
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.ash.color)
            if snapshot {
                Text("Знайти в диктовках").font(.system(size: 13)).foregroundColor(Palette.ash.color.opacity(0.8))
                Spacer(minLength: 0)
            } else {
                TextField("Знайти в диктовках", text: $ui.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Palette.paper.color)
                    .focused($searchFocused)
                    .onChange(of: ui.focusSearch) { _ in searchFocused = true }
                if !ui.query.isEmpty {
                    Button { ui.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundColor(Palette.ash.color)
                        .help("Очистити пошук")
                }
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.smoke.color.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(searchFocused ? Palette.amber.color.opacity(0.6) : Palette.paper.color.opacity(0.08)))
    }

    @ViewBuilder private var rows: some View {
        ForEach(sections) { s in
            DayHeader(title: s.title)
                .padding(.top, 14)
                .padding(.bottom, 4)
            ForEach(Array(s.items.enumerated()), id: \.element.id) { i, e in
                TakeRow(e: e, selected: e.id == selectedId, peaks: waves.get(e), retrying: ui.retrying.contains(e.id),
                        last: i == s.items.count - 1, ns: ns, reduceMotion: ui.reduceMotion)
                    .id(e.id)
                    .contentShape(Rectangle())
                    .gesture(TapGesture().onEnded {
                        withAnimation(ui.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { ui.select(e.id) }
                    })
                    .simultaneousGesture(TapGesture(count: 2).onEnded { actions.copy(e) })
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .padding(.horizontal, 10)
    }

    private var keysHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) { KeyCap(text: "⌃⌥V"); Text("вставити останнє будь-де") }
            HStack(spacing: 8) { KeyCap(text: "⌃⌥C"); Text("скопіювати останнє") }
        }
        .font(.system(size: 11.5))
        .foregroundColor(Palette.ash.color)
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Palette.paper.color.opacity(0.06)).frame(height: 1) }
    }
}

private struct DayHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundColor(Palette.paper.color.opacity(0.82))
            Rectangle().fill(Palette.paper.color.opacity(0.07)).frame(height: 1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
    }
}

/// Перемикач «Усі / Не розпізнались»: світла плашка перебігає під обраний.
private struct FilterSwitch: View {
    @ObservedObject var ui: HistoryUI
    let all: Int
    let failed: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            item("Усі", all, selected: !ui.onlyFailed) { ui.onlyFailed = false }
            if failed > 0 || ui.onlyFailed {
                item("Не розпізнались", failed, selected: ui.onlyFailed) { ui.onlyFailed = true }
            }
            Spacer(minLength: 0)
        }
    }

    private func item(_ title: String, _ n: Int, selected: Bool, _ act: @escaping () -> Void) -> some View {
        Button {
            withAnimation(ui.reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) { act() }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text("\(n)").font(.system(size: 11.5, weight: .semibold).monospacedDigit()).opacity(0.7)
            }
            .foregroundColor(selected ? Palette.smoke.color : Palette.ash.color)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background {
                if selected {
                    Capsule().fill(Palette.amber.color).matchedGeometryEffect(id: "seg", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct TakeRow: View {
    let e: Entry
    let selected: Bool
    let peaks: [Float]?
    let retrying: Bool
    let last: Bool
    let ns: Namespace.ID
    let reduceMotion: Bool
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(Fmt.time.string(from: e.ts))
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundColor(selected ? Palette.filament.color : Palette.ash.color)
                .frame(width: 38, alignment: .trailing)
                .padding(.top, 11)
            Rail(status: e.status, selected: selected, busy: retrying || e.busy, last: last)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AppIconView(bundle: e.appBundle).frame(width: 14, height: 14)
                    Text(e.appName ?? "Невідома програма")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Palette.paper.color.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(clock(e.audioS.rounded()))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundColor(Palette.ash.color)
                }
                preview
                MiniWave(peaks: peaks, active: selected).frame(height: 14)
            }
            .padding(.top, 9)
            .padding(.bottom, 12)
            .padding(.trailing, 12)
        }
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.amber.color.opacity(0.17), Palette.amber.color.opacity(0.04)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.amber.color.opacity(0.22)))
                    .matchedGeometryEffect(id: "selection", in: ns)
            } else if hover {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.paper.color.opacity(0.035))
            }
        }
        .onHover { hover = $0 }
    }

    @ViewBuilder private var preview: some View {
        if e.hasText {
            Text(e.text ?? "")
                .font(.system(size: 13.5, design: .serif))
                .foregroundColor(Palette.paper.color.opacity(selected ? 0.95 : 0.78))
                .lineSpacing(2)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(statusLine)
                .font(.system(size: 12.5, weight: e.status == .failed ? .semibold : .regular))
                .foregroundColor(e.status == .failed ? Palette.signal.color : Palette.ash.color)
                .lineLimit(1)
        }
    }

    private var statusLine: String {
        switch e.status {
        case .recording: return "Іде запис…"
        case .transcribing: return "Розпізнаю…"
        case .failed: return "Не розпізналось: \((e.error ?? "невідома причина").lowercased())"
        case .cancelled: return "Скасовано, звук збережено"
        case .empty: return "Тиша — слів не почуто"
        default: return "Без тексту"
        }
    }
}

/// Відрізок стрічки часу з точкою: заповнена бурштинова — вставлено, кільце — є текст, але не вставлено,
/// червона — не розпізналось, сіра — скасовано чи тиша, жива — запис або розпізнавання.
private struct Rail: View {
    let status: EntryStatus
    let selected: Bool
    let busy: Bool
    let last: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Palette.paper.color.opacity(0.08)).frame(width: 1, height: 11)
            node.frame(height: 14)
            Rectangle().fill(Palette.paper.color.opacity(last ? 0 : 0.08)).frame(width: 1).frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var node: some View {
        let d: CGFloat = selected ? 11 : 9
        if busy {
            Spinner(size: 10, tint: Palette.amber)
                .background(Circle().fill(Palette.smoke2.color).frame(width: 14, height: 14))
        } else {
            switch status {
            case .pasted:
                Circle().fill(Palette.amber.color).frame(width: d, height: d)
                    .shadow(color: Palette.amber.color.opacity(selected ? 0.8 : 0), radius: 6)
            case .copied, .ready:
                Circle().strokeBorder(Palette.amber.color, lineWidth: 1.6).frame(width: d, height: d)
                    .background(Circle().fill(Palette.smoke2.color))
            case .failed:
                Circle().fill(Palette.signal.color).frame(width: d, height: d)
                    .shadow(color: Palette.signal.color.opacity(selected ? 0.7 : 0), radius: 6)
            case .recording:
                PulseDot(tint: Palette.amber)
            default:
                Circle().strokeBorder(Palette.dim.color, lineWidth: 1.6).frame(width: d, height: d)
                    .background(Circle().fill(Palette.smoke2.color))
            }
        }
    }
}

private struct MiniWave: View {
    let peaks: [Float]?
    let active: Bool

    var body: some View {
        Canvas { c, size in
            let step: CGFloat = 3.5, bw: CGFloat = 2
            let n = max(1, Int(size.width / step))
            let mid = size.height / 2
            for i in 0..<n {
                let x = CGFloat(i) * step
                var v: CGFloat = 0
                if let p = peaks, !p.isEmpty {
                    let a = i * p.count / n, z = max(a + 1, (i + 1) * p.count / n)
                    v = CGFloat(p[a..<min(z, p.count)].max() ?? 0)
                }
                let h = max(2, v * size.height)
                let col: Color = active ? glow(0.3 + 0.7 * Double(v)).color : Palette.ash.color.opacity(peaks == nil ? 0.25 : 0.45)
                c.fill(Path(roundedRect: CGRect(x: x, y: mid - h / 2, width: bw, height: h), cornerRadius: 1), with: .color(col))
            }
        }
    }
}

// MARK: - Права панель: обрана диктовка

private struct DetailPane: View {
    let entry: Entry?
    @ObservedObject var ui: HistoryUI
    @ObservedObject var waves: Waveforms
    let actions: HistoryActions
    let triggerTitle: String
    let snapshot: Bool
    let isEmpty: Bool

    var body: some View {
        if let e = entry {
            VStack(alignment: .leading, spacing: 0) {
                header(e)
                    .padding(.top, 44)
                Deck(e: e, ui: ui, peaks: waves.get(e), actions: actions, snapshot: snapshot)
                    .padding(.top, 18)
                transcript(e)
                    .padding(.top, 22)
                ActionBar(e: e, retrying: ui.retrying.contains(e.id), actions: actions)
                    .padding(.vertical, 18)
            }
            .padding(.horizontal, 34)
            .id(e.id)
            .transition(.opacity)
        } else {
            EmptyStudio(triggerTitle: triggerTitle, isEmpty: isEmpty)
        }
    }

    private func header(_ e: Entry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconView(bundle: e.appBundle).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline(e))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(e.status == .failed ? Palette.signal.color : Palette.paper.color)
                Text(Fmt.when(e.ts)).font(.system(size: 12.5)).foregroundColor(Palette.ash.color)
            }
            Spacer(minLength: 0)
        }
    }

    private func headline(_ e: Entry) -> String {
        let app = e.appName ?? "програму"
        switch e.status {
        case .pasted: return "Вставлено в «\(app)»"
        case .copied: return "Скопійовано в буфер"
        case .ready: return "Розпізнано пізніше, коли з'явився зв'язок"
        case .failed: return "Не розпізналось: \((e.error ?? "невідома причина").lowercased())"
        case .empty: return "Тиша — слів не почуто"
        case .cancelled: return "Скасовано"
        case .recording: return "Іде запис…"
        case .transcribing: return "Розпізнаю…"
        case .discarded: return "Відкинуто"
        }
    }

    @ViewBuilder private func transcript(_ e: Entry) -> some View {
        if e.hasText {
            let words = VStack(alignment: .leading, spacing: 14) {
                Text(e.text ?? "")
                    .font(.system(size: 19, design: .serif))
                    .lineSpacing(7)
                    .foregroundColor(Palette.paper.color)
                    .textSelection(.enabled)
                    .frame(maxWidth: 620, alignment: .leading)
                Text(facts(e)).font(.system(size: 12)).foregroundColor(Palette.ash.color)
            }
            .padding(.leading, 26)
            .overlay(alignment: .topLeading) {
                Text("\u{201C}")
                    .font(.system(size: 56, weight: .bold, design: .serif))
                    .foregroundStyle(LinearGradient(colors: [Palette.filament.color, Palette.amber.color, Palette.ember.color],
                                                    startPoint: .top, endPoint: .bottom))
                    .offset(x: -4, y: -14)
            }
            if snapshot {
                words.padding(.top, 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            } else {
                ScrollView { words.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6) }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(explain(e).0)
                    .font(.system(size: 19, design: .serif))
                    .foregroundColor(Palette.paper.color.opacity(0.9))
                Text(explain(e).1)
                    .font(.system(size: 13))
                    .foregroundColor(Palette.ash.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 0)
        }
    }

    private func explain(_ e: Entry) -> (String, String) {
        switch e.status {
        case .failed:
            let auto = e.retryable ? " Коли з'явиться зв'язок, Voice спробує сам." : ""
            return ("Текст не вийшов, але звук на місці.", "Натисни «Спробувати ще», щоб розпізнати запис знову.\(auto)")
        case .cancelled:
            return e.hasAudio ? ("Ти скасував цей запис.", "Звук збережено — його можна розпізнати.")
                              : ("Ти скасував цей запис.", "Звуку не збереглося.")
        case .empty:
            return ("У цьому записі тиша.", "Мікрофон нічого не почув — перевір, чи правильний вибрано в налаштуваннях звуку.")
        case .recording:
            return ("Слухаю…", "Натисни правий Shift ще раз, щоб закінчити.")
        case .transcribing:
            return ("Перетворюю голос на текст…", "Зазвичай це 2–5 секунд.")
        default:
            return ("Тексту немає.", "")
        }
    }

    private func facts(_ e: Entry) -> String {
        var s = "\(wordsText(e.words)), \(Int(e.audioS.rounded())) с голосу."
        if let ms = e.totalMs { s += " Розпізнано за \(ua1(Double(ms) / 1000)) с." }
        return s
    }
}

/// Пульт програвача: кругла кнопка, велика хвиля (клік чи протяг — перемотати), час.
private struct Deck: View {
    let e: Entry
    @ObservedObject var ui: HistoryUI
    let peaks: [Float]?
    let actions: HistoryActions
    let snapshot: Bool

    private var playing: Bool { ui.playingId == e.id }

    var body: some View {
        let animating = !snapshot && !ui.reduceMotion && monoNow() - ui.selectedAt < 0.6
        HStack(spacing: 16) {
            PlayButton(playing: playing, enabled: e.hasAudio && !e.busy) { actions.play(e) }
            TimelineView(.animation(minimumInterval: nil, paused: !(animating || playing))) { _ in
                let reveal = snapshot || ui.reduceMotion ? 1 : clamp01((monoNow() - ui.selectedAt) / 0.45)
                let progress = playing ? actions.progress() : 0
                HStack(spacing: 14) {
                    BigWave(peaks: e.hasAudio ? peaks : nil, progress: progress, reveal: reveal, playing: playing)
                        .frame(height: 58)
                        .overlay(GeometryReader { geo in
                            Color.clear.contentShape(Rectangle())
                                .gesture(DragGesture(minimumDistance: 0).onEnded { g in
                                    guard e.hasAudio, !e.busy else { return }
                                    actions.seek(e, clamp01(Double(g.location.x / max(1, geo.size.width))))
                                })
                        })
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(clock(playing ? actions.position() : 0))
                            .foregroundColor(playing ? Palette.filament.color : Palette.ash.color)
                        Text(clock(e.audioS.rounded())).foregroundColor(Palette.ash.color.opacity(0.7))
                    }
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Palette.deck.color, Palette.smoke2.color], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Palette.paper.color.opacity(0.12), Palette.paper.color.opacity(0.03)],
                                                 startPoint: .top, endPoint: .bottom)))
                .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)
        )
        .background(
            Ellipse().fill(Palette.amber.color.opacity(playing ? 0.22 : 0.12)).blur(radius: 40).padding(-10)
        )
    }
}

private struct PlayButton: View {
    let playing: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(enabled ? AnyShapeStyle(LinearGradient(colors: [Palette.filament.color, Palette.amber.color, Palette.ember.color],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                                  : AnyShapeStyle(Palette.dim.color.opacity(0.4)))
                    .shadow(color: Palette.amber.color.opacity(enabled ? (hover ? 0.7 : 0.45) : 0), radius: hover ? 14 : 10)
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Palette.smoke.color)
                    .offset(x: playing ? 0 : 1.5)
            }
            .frame(width: 46, height: 46)
            .scaleEffect(hover && enabled ? 1.05 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(playing ? "Пауза (пробіл)" : "Прослухати (пробіл)")
        .onHover { hover = $0 }
    }
}

private struct BigWave: View {
    let peaks: [Float]?
    let progress: Double
    let reveal: Double
    let playing: Bool

    var body: some View {
        Canvas { c, size in
            let step: CGFloat = 4.2, bw: CGFloat = 2.5
            let n = max(1, Int(size.width / step))
            let mid = size.height / 2
            let playX = CGFloat(progress) * size.width
            for i in 0..<n {
                let x = CGFloat(i) * step
                var v: CGFloat = 0.04
                if let p = peaks, !p.isEmpty {
                    let a = i * p.count / n, z = max(a + 1, (i + 1) * p.count / n)
                    v = max(0.04, CGFloat(p[a..<min(z, p.count)].max() ?? 0))
                }
                let u = Double(i) / Double(n)
                let grow = CGFloat(clamp01((reveal * 1.3 - u) * 5))
                let h = max(2.5, v * size.height * grow)
                let played = playing && x < playX
                let col: Color
                if peaks == nil {
                    col = Palette.dim.color.opacity(0.35)
                } else if played || !playing {
                    col = glow(0.25 + 0.75 * Double(v)).color.opacity(played || !playing ? 1 : 0.3)
                } else {
                    col = Palette.paper.color.opacity(0.22)
                }
                c.fill(Path(roundedRect: CGRect(x: x, y: mid - h / 2, width: bw, height: h), cornerRadius: bw / 2), with: .color(col))
            }
            if playing {
                c.fill(Path(roundedRect: CGRect(x: playX - 1, y: 0, width: 2, height: size.height), cornerRadius: 1),
                       with: .color(Palette.filament.color))
            }
        }
    }
}

private struct ActionBar: View {
    let e: Entry
    let retrying: Bool
    let actions: HistoryActions

    var body: some View {
        HStack(spacing: 10) {
            if e.hasText {
                PrimaryButton(title: "Копіювати", key: "⌘C", icon: "doc.on.doc") { actions.copy(e) }
            } else if e.hasAudio && (e.status == .failed || e.status == .cancelled) {
                PrimaryButton(title: retrying ? "Розпізнаю…" : "Спробувати ще", key: nil, icon: "arrow.clockwise") {
                    if !retrying { actions.retry(e) }
                }
            }
            if e.hasText && e.hasAudio && !e.busy {
                GhostButton(title: retrying ? "Розпізнаю…" : "Розпізнати ще раз", icon: "arrow.clockwise") {
                    if !retrying { actions.retry(e) }
                }
            }
            if e.hasAudio && !e.busy {
                GhostButton(title: "Показати файл", icon: "folder") { actions.reveal(e) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Головна кнопка: бурштинова капсула (спільна для вікна історії й панелі в смужці меню).
struct PrimaryButton: View {
    let title: String
    let key: String?
    let icon: String
    let height: CGFloat
    let action: () -> Void
    @State private var hover = false

    init(title: String, key: String?, icon: String, height: CGFloat = 34, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.icon = icon
        self.height = height
        self.action = action
    }

    var body: some View {
        let small = height < 32
        Button(action: action) {
            HStack(spacing: small ? 7 : 8) {
                Image(systemName: icon).font(.system(size: small ? 11 : 12, weight: .bold))
                Text(title).font(.system(size: small ? 12.5 : 13, weight: .semibold))
                if let key {
                    Text(key)
                        .font(.system(size: small ? 10.5 : 11, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Palette.smoke.color.opacity(0.14)))
                }
            }
            .foregroundColor(Palette.smoke.color)
            .padding(.horizontal, small ? 13 : 16)
            .frame(height: height)
            .background(Capsule().fill(LinearGradient(colors: [Palette.filament.color, Palette.amber.color],
                                                      startPoint: .top, endPoint: .bottom)))
            .shadow(color: Palette.amber.color.opacity(hover ? 0.5 : 0.25), radius: hover ? 12 : 8, x: 0, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Другорядна кнопка: напівпрозора капсула.
struct GhostButton: View {
    let title: String
    let icon: String
    let key: String?
    let height: CGFloat
    let action: () -> Void
    @State private var hover = false

    init(title: String, icon: String, key: String? = nil, height: CGFloat = 34, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.key = key
        self.height = height
        self.action = action
    }

    var body: some View {
        let small = height < 32
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: small ? 11 : 11.5, weight: .semibold))
                Text(title).font(.system(size: small ? 12.5 : 12.5, weight: .medium))
                if let key {
                    Text(key)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Palette.ash.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Palette.paper.color.opacity(0.07)))
                }
            }
            .foregroundColor(Palette.paper.color.opacity(hover ? 1 : 0.85))
            .padding(.horizontal, small ? 12 : 14)
            .frame(height: height)
            .background(Capsule().fill(Palette.paper.color.opacity(hover ? 0.11 : 0.06)))
            .overlay(Capsule().strokeBorder(Palette.paper.color.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct EmptyStudio: View {
    let triggerTitle: String
    let isEmpty: Bool

    var body: some View {
        VStack(spacing: 16) {
            WaveGlyph(animated: false).frame(width: 110, height: 52)
            Text(isEmpty ? "Тут будуть твої диктовки" : "Обери диктовку ліворуч")
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .foregroundColor(Palette.paper.color)
            if isEmpty {
                Text("Двічі натисни \(triggerTitle), говори, а тоді натисни його ще раз.")
                    .font(.system(size: 13.5))
                    .foregroundColor(Palette.ash.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Toast: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(Palette.amber.color)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(Palette.paper.color)
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Capsule().fill(Palette.smoke2.color))
        .overlay(Capsule().strokeBorder(Palette.amber.color.opacity(0.45)))
        .shadow(color: .black.opacity(0.4), radius: 16, x: 0, y: 6)
    }
}

// MARK: - Дрібні спільні частини

struct Spinner: View {
    var size: CGFloat = 11
    var tint: RGB = Palette.amber

    var body: some View {
        TimelineView(.animation) { tl in
            let a = (tl.date.timeIntervalSinceReferenceDate * 400).truncatingRemainder(dividingBy: 360)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(tint.color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(a))
        }
        .frame(width: size, height: size)
    }
}

struct PulseDot: View {
    var tint: RGB

    var body: some View {
        TimelineView(.animation) { tl in
            let k = 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 4)
            Circle()
                .fill(tint.color)
                .frame(width: 9, height: 9)
                .opacity(0.5 + 0.5 * k)
                .shadow(color: tint.color.opacity(0.8 * k), radius: 6)
        }
        .frame(width: 12, height: 12)
    }
}

enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ bundle: String?) -> NSImage? {
        guard let b = bundle else { return nil }
        if let i = cache[b] { return i }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) else { return nil }
        let i = NSWorkspace.shared.icon(forFile: url.path)
        cache[b] = i
        return i
    }
}

struct AppIconView: View {
    let bundle: String?

    var body: some View {
        if let img = AppIcons.icon(bundle) {
            Image(nsImage: img).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed").resizable().foregroundColor(Palette.ash.color)
        }
    }
}

struct LogoMark: View {
    var body: some View {
        GeometryReader { g in
            let s = g.size.width
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.filament.color, Palette.amber.color, Palette.ember.color],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                HStack(spacing: s * 0.07) {
                    ForEach(Array([0.35, 0.7, 1.0, 0.62, 0.32].enumerated()), id: \.offset) { _, h in
                        Capsule().fill(Palette.smoke.color.opacity(0.85)).frame(width: s * 0.085, height: s * 0.5 * h)
                    }
                }
            }
        }
    }
}

struct WaveGlyph: View {
    var animated = true

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !animated)) { tl in
            let t = animated ? tl.date.timeIntervalSinceReferenceDate : 0.6
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<9, id: \.self) { i in
                    let shape = 1 - abs(Double(i) - 4) / 6
                    let h = 0.22 + 0.78 * (0.5 + 0.5 * sin(t * 2.4 - Double(i) * 0.6)) * shape
                    Capsule().fill(glow(Double(i) / 8).color).frame(width: 5, height: 52 * CGFloat(h))
                }
            }
        }
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundColor(Palette.paper.color.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Palette.paper.color.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Palette.paper.color.opacity(0.12)))
    }
}

/// Тло: теплий дим, світло від пульта і ледь помітне зерно — щоб поверхня не була пластиковою.
struct StudioBackdrop: View {
    let solid: Bool

    var body: some View {
        Palette.smoke.color.opacity(solid ? 1 : 0.9)
            .overlay(alignment: .topTrailing) {
                Circle().fill(Palette.amber.color.opacity(0.13)).frame(width: 520, height: 520).blur(radius: 120)
                    .offset(x: 60, y: -200)
            }
            .overlay(alignment: .bottomLeading) {
                Circle().fill(Palette.ember.color.opacity(0.08)).frame(width: 420, height: 420).blur(radius: 120)
                    .offset(x: -160, y: 180)
            }
            .overlay(Image(nsImage: Grain.image).resizable(resizingMode: .tile).opacity(0.05))
            .clipped()
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

enum Grain {
    static let image: NSImage = {
        let side = 96
        var px = [UInt8](repeating: 0, count: side * side * 4)
        var seed: UInt32 = 0x9E3779B9
        for i in 0..<(side * side) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            let v = UInt8(truncatingIfNeeded: seed)
            px[4 * i] = v; px[4 * i + 1] = v; px[4 * i + 2] = v; px[4 * i + 3] = 255
        }
        let img = NSImage(size: NSSize(width: side, height: side))
        if let ctx = CGContext(data: &px, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let cg = ctx.makeImage() {
            img.addRepresentation(NSBitmapImageRep(cgImage: cg))
        }
        return img
    }()
}

// MARK: - Прослуховування

final class Playback: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private(set) var path: String?
    var onEnd: (() -> Void)?

    func play(_ path: String, from fraction: Double = 0) -> Bool {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else { return false }
        p.delegate = self
        p.currentTime = p.duration * clamp01(fraction)
        player = p
        self.path = path
        return p.play()
    }

    func seek(_ fraction: Double) {
        guard let p = player else { return }
        p.currentTime = p.duration * clamp01(fraction)
    }

    func stop() {
        player?.stop()
        player = nil
        path = nil
    }

    var progress: Double {
        guard let p = player, p.duration > 0 else { return 0 }
        return p.currentTime / p.duration
    }

    var position: Double { player?.currentTime ?? 0 }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.player = nil
            self?.path = nil
            self?.onEnd?()
        }
    }
}

// MARK: - Контролер вікна

/// Звичайне вікно, але Esc і ⌘W закривають його, а ⌘V/⌘X/⌘A працюють у пошуку
/// (у програми без головного меню цих команд інакше немає).
final class HistoryWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == .command {
            switch e.keyCode {                       // фізичні клавіші — працює на будь-якій розкладці
            case 13: close(); return true                                                         // W
            case 7: return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)       // X
            case 9: return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)     // V
            case 0: return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) // A
            default: break
            }
        }
        return super.performKeyEquivalent(with: e)
    }
}

final class HistoryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var host: NSHostingView<HistoryView>?
    private var monitor: Any?
    private let store: HistoryStore
    private let ui: HistoryUI
    let waves = Waveforms()
    private let actions: HistoryActions
    private let triggerTitle: () -> String
    var onClose: (() -> Void)?

    init(store: HistoryStore, ui: HistoryUI, actions: HistoryActions, triggerTitle: @escaping () -> String) {
        self.store = store
        self.ui = ui
        self.actions = actions
        self.triggerTitle = triggerTitle
        super.init()
    }

    var isOpen: Bool { window?.isVisible ?? false }
    var windowNumber: Int? { window?.windowNumber }

    func toggle() {
        if let w = window, w.isVisible, NSApp.isActive, w.isKeyWindow { w.close() } else { show() }
    }

    func show(activate: Bool = true) {
        if window == nil { build() }
        host?.rootView = makeView()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    func close() { window?.close() }

    private func makeView() -> HistoryView {
        HistoryView(store: store, ui: ui, waves: waves, actions: actions, triggerTitle: triggerTitle())
    }

    private var selected: Entry? {
        let list = visibleEntries(store, ui)
        return list.first(where: { $0.id == ui.selectedId }) ?? list.first
    }

    private func move(_ d: Int) {
        let list = visibleEntries(store, ui)
        guard !list.isEmpty else { return }
        let cur = list.firstIndex(where: { $0.id == ui.selectedId }) ?? 0
        let next = min(list.count - 1, max(0, cur + d))
        withAnimation(ui.reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { ui.select(list[next].id) }
    }

    private func build() {
        let w = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        w.title = "Voice — історія"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.minSize = NSSize(width: 780, height: 500)
        w.isReleasedWhenClosed = false
        w.delegate = self
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        let h = NSHostingView(rootView: makeView())
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
        if !w.setFrameUsingName("VoiceHistory2") { w.center() }
        w.setFrameAutosaveName("VoiceHistory2")
        window = w
        host = h
        installKeys()
    }

    /// ↑↓ — інша диктовка, Return — копіювати, пробіл — слухати, ⌘C — копіювати (виділене або всю), ⌘F — пошук.
    private func installKeys() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = self.window, w.isKeyWindow, e.window === w else { return e }
            let editing = w.firstResponder is NSTextView && (w.firstResponder as? NSTextView)?.isFieldEditor == true
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            switch (e.keyCode, mods) {
            case (125, []), (126, []):                                    // ↓ ↑
                if editing { w.makeFirstResponder(nil) }
                self.move(e.keyCode == 125 ? 1 : -1)
                return nil
            case (36, []), (76, []):                                      // Return
                if editing { w.makeFirstResponder(nil); return nil }
                if let s = self.selected { self.actions.copy(s) }
                return nil
            case (49, []) where !editing:                                 // пробіл
                if let s = self.selected { self.actions.play(s) }
                return nil
            case (8, [.command]) where !editing:                          // ⌘C
                let before = NSPasteboard.general.changeCount
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                if NSPasteboard.general.changeCount != before {
                    self.ui.flash("Скопійовано виділене")
                } else if let s = self.selected {
                    self.actions.copy(s)
                }
                return nil
            case (3, [.command]):                                         // ⌘F
                self.ui.focusSearch += 1
                return nil
            default:
                return e
            }
        }
    }

    func windowWillClose(_ n: Notification) { onClose?() }
}
