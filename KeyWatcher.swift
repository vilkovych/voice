// Клавіші Voice:
//   двічі «чисто» натиснути тригер (типово правий Shift) — почати запис;
//   під час запису натиснути його один раз — зупинити;
//   Esc під час запису — скасувати (Esc ковтаємо, щоб він не перервав, наприклад, Claude Code);
//   ⌃⌥V — вставити останнє, ⌃⌥C — скопіювати останнє, ⌃⌥H — історія.
// Перехоплювач подій живе в окремому потоці: хоч би чим був зайнятий головний потік, клавіатура не гальмує.
import AppKit
import CoreGraphics

/// Тап: клавішу відпущено не пізніше ніж за стільки після натискання.
let tapMaxHold: Double = 0.35
/// Друге натискання — не пізніше ніж за стільки після першого відпускання.
let doubleTapGap: Double = 0.40
/// Одразу після старту одинарний тап не зупиняє (щоб випадкове третє натискання не обірвало запис).
let stopGuard: Double = 0.35

struct TriggerKey: Equatable {
    let id: String
    let title: String          // «правий Shift» — у написах
    let menuTitle: String
    let codes: [Int64]         // які фізичні клавіші рахуються
    let family: CGEventFlags   // .maskShift / .maskAlternate
    let familyBits: UInt64     // біти обох боків (NX_DEVICE…KEYMASK): Shift 0x6, Option 0x60

    static let rightShift = TriggerKey(id: "rshift", title: "правий Shift", menuTitle: "Правий Shift",
                                       codes: [60], family: .maskShift, familyBits: 0x6)
    static let rightOption = TriggerKey(id: "ropt", title: "правий Option", menuTitle: "Правий Option",
                                        codes: [61], family: .maskAlternate, familyBits: 0x60)
    static let anyOption = TriggerKey(id: "opt", title: "Option", menuTitle: "Будь-який Option",
                                      codes: [58, 61], family: .maskAlternate, familyBits: 0x60)
    static let all = [rightShift, rightOption, anyOption]
    static func byId(_ id: String) -> TriggerKey { all.first { $0.id == id } ?? .rightShift }
}

/// Біт конкретної клавіші-модифікатора у прапорцях події.
private func deviceBit(_ code: Int64) -> UInt64 {
    switch code {
    case 56: return 0x2      // лівий Shift
    case 60: return 0x4      // правий Shift
    case 58: return 0x20     // лівий Option
    case 61: return 0x40     // правий Option
    default: return 0
    }
}

enum KeyAction { case start, stop, cancel, pasteLast, copyLast, history }

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let w = Unmanaged<KeyWatcher>.fromOpaque(refcon).takeUnretainedValue()
    return w.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}

final class KeyWatcher {
    /// Викликається на головному потоці.
    var onAction: ((KeyAction) -> Void)?

    private let lock = NSLock()
    private var _trigger = TriggerKey.rightShift
    private var _recording = false
    private var _recordingSince = 0.0
    private var _installed = false

    // далі — лише в потоці перехоплювача
    private var tap: CFMachPort?
    private var loop: CFRunLoop?
    private var downAt: Double?
    private var firstUpAt: Double?
    private var swallowUp: Set<Int64> = []

    var installed: Bool { lock.lock(); defer { lock.unlock() }; return _installed }

    var trigger: TriggerKey {
        get { lock.lock(); defer { lock.unlock() }; return _trigger }
        set { lock.lock(); _trigger = newValue; lock.unlock() }
    }

    func setRecording(_ on: Bool) {
        lock.lock()
        _recording = on
        _recordingSince = monoNow()
        lock.unlock()
    }

    /// Ставить перехоплювач. false — macOS не дала (немає «Універсального доступу»).
    @discardableResult
    func install() -> Bool {
        if installed { return true }
        let ready = DispatchSemaphore(value: 0)
        let th = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let ok = self.createTap()
            ready.signal()
            if ok { CFRunLoopRun() }
        }
        th.name = "voice.keys"
        th.qualityOfService = .userInteractive
        th.start()
        ready.wait()
        return installed
    }

    func remove() {
        lock.lock()
        let was = _installed
        _installed = false
        lock.unlock()
        guard was else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
    }

    private func createTap() -> Bool {
        var mask: CGEventMask = 0
        for t in [CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            mask |= CGEventMask(1) << CGEventMask(t.rawValue)
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: keyTapCallback, userInfo: me) else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let rl = CFRunLoopGetCurrent()
        CFRunLoopAddSource(rl, src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.loop = rl
        lock.lock(); _installed = true; lock.unlock()
        return true
    }

    /// true — подію проковтнути (далі в систему вона не піде).
    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .flagsChanged:
            flagsChanged(e)
            return false
        case .keyDown:
            return keyDown(e)
        case .keyUp:
            return swallowUp.remove(e.getIntegerValueField(.keyboardEventKeycode)) != nil
        default:
            reset()           // клацання мишею (наприклад, Shift+клік) — це не тап
            return false
        }
    }

    private func reset() { downAt = nil; firstUpAt = nil }

    private func fire(_ a: KeyAction) {
        DispatchQueue.main.async { [weak self] in self?.onAction?(a) }
    }

    private func flagsChanged(_ e: CGEvent) {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        lock.lock()
        let k = _trigger, recording = _recording, since = _recordingSince
        lock.unlock()
        guard k.codes.contains(code) else { reset(); return }         // інший модифікатор — скидання
        let f = e.flags, raw = f.rawValue
        let others = CGEventFlags([.maskShift, .maskAlternate, .maskControl, .maskCommand, .maskSecondaryFn]).subtracting(k.family)
        let mine = deviceBit(code)
        if !f.intersection(others).isEmpty || raw & (k.familyBits & ~mine) != 0 { reset(); return }
        // якщо біти конкретних клавіш не прийшли (рідкісні клавіатури) — орієнтуємось на загальний прапорець
        let isDown = raw & k.familyBits != 0 ? raw & mine != 0 : f.contains(k.family)
        let now = monoNow()
        if isDown {
            if downAt != nil { reset(); return }
            if let up = firstUpAt, now - up > doubleTapGap { firstUpAt = nil }
            downAt = now
            return
        }
        guard let d = downAt, now - d <= tapMaxHold else { reset(); return }
        downAt = nil
        if recording {
            reset()
            if now - since >= stopGuard { fire(.stop) }
        } else if let up = firstUpAt, now - up <= doubleTapGap {
            reset()
            fire(.start)
        } else {
            firstUpAt = now
        }
    }

    private func keyDown(_ e: CGEvent) -> Bool {
        reset()                                               // натиснута звичайна клавіша — це не тап
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let mods = e.flags.intersection([.maskShift, .maskAlternate, .maskControl, .maskCommand])
        let repeated = e.getIntegerValueField(.keyboardEventAutorepeat) != 0
        lock.lock(); let recording = _recording; lock.unlock()
        if code == 53, mods.isEmpty, recording {              // Esc
            if !repeated { fire(.cancel) }
            swallowUp.insert(code)
            return true
        }
        if mods == [.maskControl, .maskAlternate] {
            let action: KeyAction?
            switch code {                                     // фізичні клавіші — працює на будь-якій розкладці
            case 9: action = .pasteLast                       // V
            case 8: action = .copyLast                        // C
            case 4: action = .history                         // H
            default: action = nil
            }
            if let a = action {
                if !repeated { fire(a) }
                swallowUp.insert(code)
                return true
            }
        }
        return false
    }
}
