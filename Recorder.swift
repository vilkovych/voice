// Запис мікрофона: свіжий AVAudioEngine на кожен запис, 16 кГц моно 16 біт.
// Звук пишеться на диск уже під час запису (розміри в заголовку WAV дописуються в кінці),
// тож навіть якщо програма впаде посеред фрази, запис лишиться і його можна буде розпізнати.
import AVFoundation

enum RecorderError: Error, CustomStringConvertible {
    case noInput, converter, file(String), start(String)

    var description: String {
        switch self {
        case .noInput: return "немає вхідного аудіопристрою"
        case .converter: return "не вдалося створити AVAudioConverter"
        case .file(let p): return "не можу створити файл \(p)"
        case .start(let s): return "AVAudioEngine не стартував: \(s)"
        }
    }
}

func micStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "notDetermined"
    }
}

final class Recorder {
    /// Гучність шматка (RMS 0…1), момент, коли її пораховано, і спектр (20 смуг 0…1).
    /// На головному потоці, ~47 разів на секунду.
    var onLevel: ((Float, Double, [Float]) -> Void)?
    private var engine: AVAudioEngine?
    private var analyzer = SpectrumAnalyzer()     // лише в потоці звуку
    private let lock = NSLock()
    private var samples: [Int16] = []
    private let io = DispatchQueue(label: "voice.rec.io")
    private var file: FileHandle?      // лише в черзі io
    private var written = 0            // лише в черзі io

    func start(file path: String) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw RecorderError.noInput }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(wavRate),
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw RecorderError.converter }
        converter.downmix = true
        guard FileManager.default.createFile(atPath: path, contents: wavHeader(dataBytes: 0),
                                             attributes: [.posixPermissions: 0o600]),
              let h = FileHandle(forWritingAtPath: path) else { throw RecorderError.file(path) }
        _ = try? h.seekToEnd()
        io.sync { file = h; written = 0 }
        lock.lock(); samples = []; samples.reserveCapacity(wavRate * 120); lock.unlock()
        analyzer = SpectrumAnalyzer()
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        // у вихід звук не йде: тільки тап на вході
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.consume(buffer, converter, outFormat, ratio)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            io.sync { try? file?.close(); file = nil }
            throw RecorderError.start(error.localizedDescription)
        }
        self.engine = engine
    }

    /// Зупиняє запис, закриває файл з правильним заголовком і віддає семпли.
    func stop() -> [Int16] {
        if let e = engine {
            e.inputNode.removeTap(onBus: 0)
            e.stop()
        }
        engine = nil
        io.sync {
            if let h = file {
                try? h.seek(toOffset: 4); try? h.write(contentsOf: le32(36 + written))
                try? h.seek(toOffset: 40); try? h.write(contentsOf: le32(written))
                try? h.close()
            }
            file = nil
        }
        lock.lock()
        let s = samples
        samples = []
        lock.unlock()
        return s
    }

    private func consume(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter, _ outFormat: AVAudioFormat, _ ratio: Double) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let ch = out.int16ChannelData, out.frameLength > 0 else { return }
        let p = UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength))
        var sum = 0.0
        for s in p { let v = Double(s); sum += v * v }
        let rms = Float(sqrt(sum / Double(p.count)) / 32768)
        let bands = analyzer.levels(p)
        let bytes = Data(buffer: p)
        lock.lock()
        samples.append(contentsOf: p)
        lock.unlock()
        io.async { [weak self] in
            guard let self, let h = self.file else { return }
            if (try? h.write(contentsOf: bytes)) != nil { self.written += bytes.count }
        }
        let t = monoNow()
        DispatchQueue.main.async { [weak self] in self?.onLevel?(rms, t, bands) }
    }
}
