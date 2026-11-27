import AVFoundation

/// Records AAC (.m4a) in chunks, each a complete, separately decodable file,
/// so every upload stays well under the server's 4,000,000-byte cap.
/// 32 kbps mono ≈ 240 KB a minute; a 4.5-minute chunk ≈ 1.1 MB.
@MainActor
final class ChunkedRecorder: NSObject, AVAudioRecorderDelegate {
    struct Chunk { let index: Int; let url: URL; let ms: Int }

    static let chunkSeconds: TimeInterval = 270      // 4.5 min, as the web screen
    static let maxSeconds: TimeInterval = 600        // 10:00 hard stop

    /// A chunk closed while recording continues (an "earlier" chunk).
    var onChunk: ((Chunk) -> Void)?
    /// Recording ended by itself (cap reached, or an interruption) with the final chunk.
    var onAutoStop: ((Chunk?) -> Void)?

    private var recorder: AVAudioRecorder?
    private var chunkIndex = 0
    private var chunkStarted = Date()
    private(set) var started: Date?
    private var tick: Timer?
    private let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    var elapsed: TimeInterval { started.map { Date().timeIntervalSince($0) } ?? 0 }
    var isRecording: Bool { recorder != nil }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .spokenAudio)
        try session.setActive(true)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: session)
        chunkIndex = 0
        started = Date()
        try beginChunk()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
    }

    /// Stops and returns the last chunk (nil if nothing usable was captured in it).
    @discardableResult
    func stop() -> Chunk? {
        tick?.invalidate(); tick = nil
        NotificationCenter.default.removeObserver(self)
        let last = closeChunk()
        started = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return last
    }

    // MARK: Private

    private func onTick() {
        guard isRecording else { return }
        if elapsed >= Self.maxSeconds {
            onAutoStop?(stop())
        } else if Date().timeIntervalSince(chunkStarted) >= Self.chunkSeconds {
            if let done = closeChunk() { onChunk?(done) }
            chunkIndex += 1
            do { try beginChunk() } catch { onAutoStop?(stop()) }
        }
    }

    private func beginChunk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("taos-\(UUID().uuidString)-\(chunkIndex).m4a")
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.delegate = self
        guard r.record() else { throw RecorderError.couldNotStart }
        recorder = r
        chunkStarted = Date()
    }

    private func closeChunk() -> Chunk? {
        guard let r = recorder else { return nil }
        let ms = Int(r.currentTime * 1000)
        r.stop()
        recorder = nil
        return Chunk(index: chunkIndex, url: r.url, ms: ms)
    }

    /// A phone call or Siri takes the mic: stop and keep everything captured.
    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in if self.isRecording { self.onAutoStop?(self.stop()) } }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in if self.isRecording { self.onAutoStop?(self.stop()) } }
    }

    enum RecorderError: Error { case couldNotStart }
}
