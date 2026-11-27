import Foundation
import UIKit

/// The Speak screen: record (up to 10:00, chunked), send, show the styled text,
/// re-style the same transcript when the style or output language changes.
@MainActor
final class SpeakModel: ObservableObject {
    enum Phase: Equatable { case idle, recording, working, restyling }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var result: DictateResult?
    @Published var error: String?
    @Published private(set) var startedAt: Date?
    @Published var showOriginal = false

    @Published var style: DictateStyle = Prefs.style {
        didSet { Prefs.style = style; if style != oldValue { restyleIfNeeded() } }
    }
    @Published var source: String = Prefs.myLanguage {
        didSet { Prefs.myLanguage = source }
    }
    @Published var target: String? = Prefs.target {
        didSet { Prefs.target = target; if target != oldValue { restyleIfNeeded() } }
    }

    private let recorder = ChunkedRecorder()
    private var job: DictationJob?
    private var recordedSource = "en"
    private var restyleTask: Task<Void, Never>?
    private let api: DictateAPI
    private let onSignedOut: () -> Void

    init(api: DictateAPI, onSignedOut: @escaping () -> Void) {
        self.api = api
        self.onSignedOut = onSignedOut
        recorder.onChunk = { [weak self] chunk in self?.job?.add(chunk) }
        recorder.onAutoStop = { [weak self] last in self?.finish(last: last) }
        #if DEBUG
        // Simulator self-test: launch with -micSelfTest to start and stop the recorder once.
        if ProcessInfo.processInfo.arguments.contains("-micSelfTest") {
            Task { @MainActor in
                do { try recorder.start(); try await Task.sleep(for: .seconds(2))
                     let c = recorder.stop(); print("[taos-mic] self-test ok ms=\(c?.ms ?? -1)") }
                catch { print("[taos-mic] self-test failed: \(error)") }
            }
        }
        #endif
    }

    // MARK: Mic

    func toggle() {
        switch phase {
        case .idle: Task { await start() }
        case .recording: finish(last: recorder.stop())
        default: break
        }
    }

    private func start() async {
        error = nil
        guard await ChunkedRecorder.requestPermission() else {
            error = L("error.mic_denied"); return
        }
        // The keyboard session holds the mic in the background; Speak takes it over.
        KeyboardSession.shared.end()
        do {
            recordedSource = source
            job = DictationJob(api: api, source: source)
            try recorder.start()
            startedAt = recorder.started
            phase = .recording
            UIApplication.shared.isIdleTimerDisabled = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            print("[taos-mic] start failed: \(error)")
            self.error = L("error.mic_failed")
        }
    }

    private func finish(last: ChunkedRecorder.Chunk?) {
        guard phase == .recording else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        startedAt = nil
        guard let job else { phase = .idle; return }
        self.job = nil
        phase = .working
        let style = self.style, target = self.target
        Task {
            do {
                switch try await job.finish(last: last, style: style, target: target) {
                case .tooShort: error = L("error.too_short")
                case let .result(r): show(r)
                }
            } catch {
                handle(error)
            }
            if phase == .working { phase = .idle }
        }
    }

    // MARK: Re-style

    private func restyleIfNeeded() {
        guard let current = result, phase == .idle || phase == .restyling else { return }
        restyleTask?.cancel()
        phase = .restyling
        let style = self.style, target = self.target, source = recordedSource
        restyleTask = Task {
            do {
                let r = try await api.restyle(raw: current.raw, style: style, source: source, target: target)
                guard !Task.isCancelled else { return }
                show(r)
            } catch is CancellationError {
                return
            } catch {
                handle(error)
            }
            if !Task.isCancelled { phase = .idle }
        }
    }

    // MARK: Results

    private func show(_ r: DictateResult) {
        result = r
        error = nil
        SharedResult.save(r.styled)
    }

    private func handle(_ e: Error) {
        if let d = e as? DictateError {
            if d == .signedOut { onSignedOut() }
            error = d.errorDescription
        } else {
            error = e.localizedDescription
        }
    }

    func clear() {
        result = nil
        error = nil
        showOriginal = false
    }
}
