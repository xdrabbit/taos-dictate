import AVFoundation

/// Listens continuously and hands over the audio in pieces, cut at pauses, so
/// each piece can be subtitled while the room keeps talking.
///
/// It meters the input level (AVAudioRecorder metering) and learns the room's
/// noise floor. A piece closes after a pause of `pauseSeconds` once it holds at
/// least `minSpeechSeconds` of speech, or at `maxPieceSeconds` regardless. A
/// stretch with no speech in it is thrown away, never uploaded.
@MainActor
final class LiveRecorder: NSObject, AVAudioRecorderDelegate {
    struct Piece { let url: URL; let ms: Int }

    static let pauseSeconds: TimeInterval = 0.8
    static let minSpeechSeconds: TimeInterval = 1.0
    static let maxPieceSeconds: TimeInterval = 25
    /// Silence-only stretches are dropped at this length and listening goes on.
    static let maxQuietSeconds: TimeInterval = 30

    var onPiece: ((Piece) -> Void)?
    /// The mic was taken away (a call, Siri) or failed.
    var onInterrupted: (() -> Void)?
    /// 0…1, for the level ring.
    private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var tick: Timer?
    private var pieceStarted = Date()
    private var speech: TimeInterval = 0
    private var quietRun: TimeInterval = 0
    private var floorDb: Float = -50
    private let step: TimeInterval = 0.1
    private let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    var isListening: Bool { recorder != nil }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: session)
        floorDb = -50
        try beginPiece()
        tick = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
    }

    /// Stops listening; the last piece goes out if it held speech.
    func stop() {
        tick?.invalidate(); tick = nil
        NotificationCenter.default.removeObserver(self)
        closePiece(send: speech >= 0.4)
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Private

    private func onTick() {
        guard let r = recorder else { return }
        r.updateMeters()
        let db = r.averagePower(forChannel: 0)
        // The floor follows quiet quickly and loud slowly, so talk does not
        // raise it but a noisier room does over a few seconds.
        floorDb = db < floorDb ? db : floorDb + (db - floorDb) * 0.01
        let threshold = max(floorDb + 10, -48)
        let talking = db > threshold
        level = max(0, min(1, (db + 50) / 50))

        if talking { speech += step; quietRun = 0 } else { quietRun += step }
        let length = Date().timeIntervalSince(pieceStarted)

        if speech >= Self.minSpeechSeconds && quietRun >= Self.pauseSeconds {
            cut(send: true)
        } else if length >= Self.maxPieceSeconds && speech > 0.4 {
            cut(send: true)
        } else if speech < 0.4 && length >= Self.maxQuietSeconds {
            cut(send: false)
        }
    }

    private func cut(send: Bool) {
        closePiece(send: send)
        do { try beginPiece() } catch { stop(); onInterrupted?() }
    }

    private func beginPiece() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taos-live-\(UUID().uuidString).m4a")
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.delegate = self
        r.isMeteringEnabled = true
        guard r.record() else { throw ChunkedRecorder.RecorderError.couldNotStart }
        recorder = r
        pieceStarted = Date()
        speech = 0
        quietRun = 0
    }

    private func closePiece(send: Bool) {
        guard let r = recorder else { return }
        let ms = Int(r.currentTime * 1000)
        r.stop()
        recorder = nil
        if send { onPiece?(Piece(url: r.url, ms: ms)) } else { try? FileManager.default.removeItem(at: r.url) }
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in
            if self.isListening { self.stop(); self.onInterrupted?() }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            if self.isListening { self.stop(); self.onInterrupted?() }
        }
    }
}
