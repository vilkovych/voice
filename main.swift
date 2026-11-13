// Voice — диктовка: двічі правий Shift → говориш → ще раз Shift → текст під курсором (і в історії).
//
//   Voice                      — програма у смужці меню (одразу просить дозволи)
//   Voice --no-prompts         — те саме без запитів дозволів (лише для перевірки збірки)
//   Voice --transcribe <wav>   — розпізнати файл тим самим кодом, надрукувати один рядок JSON
//   Voice --png <тека>         — смужка в усіх станах і вікно історії → PNG (без екрана)
//   Voice --demo <тека>        — показати смужку й вікно наживо і зняти кадри (для перевірки)
import AppKit

let argv = CommandLine.arguments

func argument(after flag: String) -> String? {
    guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}

/// Прогріває з'єднання (як під час запису в програмі), далі той самий ланцюжок, що й після диктовки.
func runTranscribe(_ path: String) -> Never {
    guard let wav = FileManager.default.contents(atPath: path) else {
        print(jobj([("error", jstr("не можу прочитати \(path)"))]))
        exit(1)
    }
    let keys = loadKeys()
    let start = startIndex(keys, lastGood: lastGoodKeyTail())
    Task.detached {
        await warmConnectionAndWait()
        let t0 = monoNow()
        let out = await transcribe(wav, keys: keys, startAt: start, note: {
            FileHandle.standardError.write(Data("\($0)\n".utf8))
        })
        let total = ms(since: t0)
        if let text = out.text {
            print(jobj([("audio_s", jnum(wavSeconds(wav), 2)), ("upload_ms", jint(out.uploadMs)),
                        ("create_ms", jint(out.createMs)), ("wait_ms", jint(out.waitMs)), ("total_ms", jint(total)),
                        ("key_tail", jstr(out.keyTail)), ("text", jstr(text))]))
            exit(0)
        }
        let f = out.failure ?? .failed("невідомо")
        print(jobj([("error", jstr("\(f.reason): \(f.detail)"))]))
        exit(1)
    }
    dispatchMain()
}

if argv.contains("--transcribe") {
    guard let path = argument(after: "--transcribe") else {
        print(jobj([("error", jstr("треба: Voice --transcribe <file.wav>"))]))
        exit(1)
    }
    runTranscribe(path)
}

if argv.contains("--png") {
    guard let dir = argument(after: "--png") else { print("треба: Voice --png <тека>"); exit(1) }
    MainActor.assumeIsolated {
        do {
            for p in try renderPreviews(to: dir) { print(p) }
        } catch {
            print("помилка: \(error)")
            exit(1)
        }
    }
    exit(0)
}

// Перевірка захисту від тиші: розпізнати файл, показати сирий і очищений текст.
if argv.contains("--clean") {
    guard let path = argument(after: "--clean"), let wav = FileManager.default.contents(atPath: path),
          let vad = VoiceActivity(wavFile: path, ignoreFirst: 0.45) else { print("треба: Voice --clean <file.wav>"); exit(1) }
    let keys = loadKeys()
    Task.detached {
        let voiced = vad.voiced()
        if voiced < 0.25 {
            print(jobj([("file", jstr((path as NSString).lastPathComponent)), ("voiced_s", jnum(voiced, 2)),
                        ("verdict", jstr("тиша — не відправляю"))]))
            exit(0)
        }
        let out = await transcribe(wav, keys: keys, startAt: startIndex(keys, lastGood: lastGoodKeyTail()), note: { _ in })
        let raw = out.text ?? ""
        let c = Hallucinations.clean(raw, words: out.words, vad: vad)
        print(jobj([("file", jstr((path as NSString).lastPathComponent)), ("voiced_s", jnum(voiced, 2)),
                    ("words", jint(out.words.count)), ("raw", jstr(raw)), ("clean", jstr(c.text)), ("removed", jint(c.removed))]))
        exit(0)
    }
    dispatchMain()
}

if argv.contains("--sounds") {
    guard let dir = argument(after: "--sounds") else { print("треба: Voice --sounds <тека>"); exit(1) }
    do {
        for p in try exportSounds(to: dir) { print(p) }
    } catch {
        print("помилка: \(error)")
        exit(1)
    }
    exit(0)
}

if argv.contains("--demo") {
    guard let dir = argument(after: "--demo") else { print("треба: Voice --demo <тека>"); exit(1) }
    NSApplication.shared.setActivationPolicy(.accessory)
    let demo = DemoRunner(dir: dir)
    demo.run()
    NSApplication.shared.run()
    exit(0)
}

// Другий екземпляр не потрібен: два слухачі клавіш вставили б текст двічі.
if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.8gate.voice")
    .first(where: { $0.processIdentifier != getpid() && !$0.isTerminated }) {
    log("уже працює інший Voice (pid \(other.processIdentifier)) — цей виходить")
    exit(0)
}

let delegate = App(noPrompts: argv.contains("--no-prompts"))

// kill (так зупиняє install.sh) — спершу акуратно закрити запис, що йде, щоб він лишився в історії.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSource.setEventHandler {
    delegate.shutdown()
    exit(0)
}
termSource.resume()

NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
