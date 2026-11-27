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
    private var earlier: [Int: Task<PriorChunk, Never>] = [:]
    private var earlierMs: [Int: Int] = [:]
    private var recordedSource = "en"
    private var restyleTask: Task<Void, Never>?
    private let api: DictateAPI
    private let onSignedOut: () -> Void

    init(api: DictateAPI, onSignedOut: @escaping () -> Void) {
        self.api = api
        self.onSignedOut = onSignedOut
        recorder.onChunk = { [weak self] chunk in self?.uploadEarlier(chunk) }
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
        do {
            earlier = [:]; earlierMs = [:]
            recordedSource = source
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

    private func uploadEarlier(_ chunk: ChunkedRecorder.Chunk) {
        earlierMs[chunk.index] = chunk.ms
        let api = self.api, source = recordedSource
        earlier[chunk.index] = Task {
            defer { try? FileManager.default.removeItem(at: chunk.url) }
            do {
                let r = try await api.chunk(audio: chunk.url, source: source, index: chunk.index, ms: chunk.ms)
                return .text(r.chunk.text, ms: chunk.ms)
            } catch {
                // Contract: a failed earlier chunk does not abandon the dictation.
                return .lost(ms: chunk.ms)
            }
        }
    }

    private func finish(last: ChunkedRecorder.Chunk?) {
        guard phase == .recording else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        startedAt = nil
        let pending = earlier.sorted { $0.key < $1.key }.map(\.value)
        earlier = [:]

        // Nothing at all, or a tap that was over before it started.
        if pending.isEmpty, (last?.ms ?? 0) < 600 {
            if let url = last?.url { try? FileManager.default.removeItem(at: url) }
            phase = .idle
            error = L("error.too_short")
            return
        }

        phase = .working
        let source = recordedSource, style = self.style, target = self.target
        Task {
            defer { if let url = last?.url { try? FileManager.default.removeItem(at: url) } }
            do {
                let r: DictateResult
                if pending.isEmpty {
                    r = try await api.speak(audio: last?.url, source: source, style: style, target: target)
                } else {
                    var prior: [PriorChunk] = []
                    for t in pending { prior.append(await t.value) }
                    // Omit the last audio only when it is effectively empty.
                    let lastAudio = (last?.ms ?? 0) >= 500 ? last?.url : nil
                    r = try await api.speak(audio: lastAudio, source: source, style: style, target: target,
                                            prior: prior, chunkIndex: prior.count, chunkMs: last?.ms ?? 0)
                }
                show(r)
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
