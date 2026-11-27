import AVFoundation
import UIKit

/// Background dictation for the TAOS keyboard.
///
/// iOS keyboards can't use the microphone. So the keyboard's mic opens the app once,
/// the app starts this session, and the user goes back (◀ in the status bar). While the
/// session is open the app keeps an AVAudioEngine input running — that is what lets an
/// app with the `audio` background mode keep running — and only *keeps* audio between
/// the keyboard's start and stop. Results go back through the App Group.
/// The session closes after `idleTimeout` without a dictation, on an interruption, or
/// when the user ends it. iOS shows the orange mic dot the whole time it is open.
@MainActor
final class KeyboardSession: ObservableObject {
    static let shared = KeyboardSession()

    static let idleTimeout: TimeInterval = 5 * 60
    static let maxSeconds: TimeInterval = 600

    @Published private(set) var isOpen = false
    @Published private(set) var phase: KeyboardBridge.Phase = .idle
    @Published private(set) var listenStart: Date?
    @Published var lastError: String?
    /// True after the keyboard opened the app: show "go back to your app".
    @Published var showGuide = false

    /// Set once signed in; nil means signed out. A keyboard launch that arrives
    /// before sign-in has been restored waits for it.
    var api: DictateAPI? {
        didSet { if api != nil, pendingOpen { pendingOpen = false; handleOpenFromKeyboard() } }
    }
    private var pendingOpen = false

    private let engine = AVAudioEngine()
    private var writer: ChunkWriter?
    private var job: DictationJob?
    private var requestID: String?
    private var heartbeat: Timer?
    private var lastActivity = Date()
    private var observing = false

    private init() {
        #if DEBUG
        // Launch with -kbWriterTest: open a session, keep 2 s of audio, report the file.
        if ProcessInfo.processInfo.arguments.contains("-kbWriterTest") {
            Task { @MainActor in
                self.open()
                guard self.isOpen, let w = try? ChunkWriter(inputFormat: self.engine.inputNode.outputFormat(forBus: 0)) else {
                    print("[taos-kb] writer test: session failed to open"); return
                }
                self.writerLock.withLock { self.writerBox = w }
                try? await Task.sleep(for: .seconds(2))
                self.writerLock.withLock { self.writerBox = nil }
                let c = w.finish()
                let bytes = (try? c.map { try FileManager.default.attributesOfItem(atPath: $0.url.path)[.size] as? Int } ?? nil) ?? nil
                print("[taos-kb] writer test ok ms=\(c?.ms ?? -1) bytes=\(bytes ?? -1) alive=\(KeyboardBridge.sessionAlive)")
                self.end()
            }
        }
        #endif
    }

    // MARK: Entry points

    /// The keyboard opened the app (taosdictate://session): open the session and start listening.
    func handleOpenFromKeyboard() {
        guard api != nil else { pendingOpen = true; return }
        open()
        if isOpen { startListening(); showGuide = true }
    }

    func open() {
        observeKeyboard()
        guard !isOpen else { return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.record, mode: .default)
            try s.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                // Audio thread. The writer copies and converts on its own queue.
                self?.currentWriter?.append(buffer)
            }
            engine.prepare()
            try engine.start()
            NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                                   name: AVAudioSession.interruptionNotification, object: s)
            isOpen = true
            lastActivity = Date()
            KeyboardBridge.beat()
            setPhase(.idle)
            heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        } catch {
            print("[taos-kb] session open failed: \(error)")
            fail(L("error.mic_failed"))
            teardown()
        }
    }

    func end() {
        guard isOpen else { return }
        if phase == .listening { _ = writerFinish() ; job = nil }
        teardown()
        setPhase(.idle)
    }

    // MARK: Listening

    func startListening() {
        guard isOpen, phase != .listening else { return }
        guard let api else { fail(L("error.signed_out")); return }
        requestID = KeyboardBridge.requestID
        do {
            let w = try ChunkWriter(inputFormat: engine.inputNode.outputFormat(forBus: 0))
            w.onChunk = { [weak self] chunk in
                Task { @MainActor in self?.job?.add(chunk) }
            }
            job = DictationJob(api: api, source: SharedPrefs.myLanguage)
            writerLock.withLock { writerBox = w }
            writer = w
            listenStart = Date()
            KeyboardBridge.listenStart = listenStart
            KeyboardBridge.error = nil
            lastError = nil
            setPhase(.listening)
        } catch {
            print("[taos-kb] writer failed: \(error)")
            fail(L("error.mic_failed"))
        }
    }

    func stopListening() {
        guard phase == .listening, let job else { return }
        let last = writerFinish()
        self.job = nil
        listenStart = nil
        lastActivity = Date()
        setPhase(.working)
        let style = DictateStyle(rawValue: SharedPrefs.style) ?? .professional
        let target = SharedPrefs.target
        let id = requestID ?? UUID().uuidString
        Task {
            do {
                switch try await job.finish(last: last, style: style, target: target) {
                case .tooShort:
                    fail(L("error.too_short"))
                case let .result(r):
                    SharedResult.save(r.styled)
                    KeyboardBridge.publishResult(id: id, text: r.styled)
                    setPhase(.idle)
                }
            } catch {
                fail((error as? DictateError)?.errorDescription ?? error.localizedDescription)
            }
            lastActivity = Date()
        }
    }

    // MARK: Private

    private func observeKeyboard() {
        guard !observing else { return }
        observing = true
        DarwinNotify.observe(KeyboardBridge.Note.start) { [weak self] in
            guard let self else { return }
            if self.isOpen { self.startListening() } else { self.fail(L("kb.session_closed")) }
        }
        DarwinNotify.observe(KeyboardBridge.Note.stop) { [weak self] in self?.stopListening() }
        DarwinNotify.observe(KeyboardBridge.Note.end) { [weak self] in self?.end() }
    }

    private func tick() {
        guard isOpen else { return }
        KeyboardBridge.beat()
        if phase == .listening, let s = listenStart, Date().timeIntervalSince(s) >= Self.maxSeconds {
            stopListening()
        } else if phase == .idle || phase == .error, Date().timeIntervalSince(lastActivity) >= Self.idleTimeout {
            end()
        }
    }

    private func setPhase(_ p: KeyboardBridge.Phase) {
        phase = p
        KeyboardBridge.phase = p
        DarwinNotify.post(KeyboardBridge.Note.state)
    }

    private func fail(_ message: String) {
        lastError = message
        KeyboardBridge.error = message
        setPhase(.error)
    }

    private func teardown() {
        heartbeat?.invalidate(); heartbeat = nil
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.interruptionNotification, object: nil)
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        writerLock.withLock { writerBox = nil }
        writer = nil
        listenStart = nil
        isOpen = false
        KeyboardBridge.clearBeat()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func writerFinish() -> AudioChunk? {
        writerLock.withLock { writerBox = nil }
        let last = writer?.finish()
        writer = nil
        return last
    }

    /// A call or Siri takes the mic: keep what was said, close the session.
    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in
            if self.phase == .listening { self.stopListening() }
            self.teardown()
        }
    }

    // The tap runs on the audio thread, so it reads the writer through a lock.
    private let writerLock = NSLock()
    nonisolated(unsafe) private var writerBox: ChunkWriter?
    nonisolated private var currentWriter: ChunkWriter? {
        writerLock.withLock { writerBox }
    }
}

/// Converts engine buffers to 16 kHz mono and writes AAC (.m4a) chunks of up to 4.5 min,
/// each a complete file, so every upload stays well under the server's 4 MB cap.
final class ChunkWriter {
    static let chunkSeconds: Double = 270

    var onChunk: ((AudioChunk) -> Void)?

    private let queue = DispatchQueue(label: "taos.chunkwriter")
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                          channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    private var file: AVAudioFile?
    private var url: URL?
    private var index = 0
    private var frames: AVAudioFramePosition = 0
    private var closed = false

    init(inputFormat: AVAudioFormat) throws {
        guard let c = AVAudioConverter(from: inputFormat, to: outFormat) else { throw RecorderError.couldNotStart }
        converter = c
        try queue.sync { try openFile() }
    }

    /// Audio thread: copy the buffer, then convert and write on our queue.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        queue.async { [weak self] in self?.write(copy) }
    }

    /// Closes the current file and returns it as the last chunk.
    func finish() -> AudioChunk? {
        queue.sync {
            closed = true
            return closeFile()
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard !closed, let file else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0 else { return }
        do { try file.write(from: out) } catch { return }
        frames += AVAudioFramePosition(out.frameLength)
        if Double(frames) / outFormat.sampleRate >= Self.chunkSeconds, let done = closeFile() {
            onChunk?(done)
            index += 1
            try? openFile()
        }
    }

    private func openFile() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("taos-kb-\(UUID().uuidString)-\(index).m4a")
        file = try AVAudioFile(forWriting: u, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 24_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        url = u
        frames = 0
    }

    private func closeFile() -> AudioChunk? {
        guard let u = url else { return nil }
        let ms = Int(Double(frames) / outFormat.sampleRate * 1000)
        file = nil   // AVAudioFile finalizes the container when released
        url = nil
        return AudioChunk(index: index, url: u, ms: ms)
    }

    enum RecorderError: Error { case couldNotStart }
}
