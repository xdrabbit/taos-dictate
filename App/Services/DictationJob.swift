import Foundation

/// One closed, separately decodable audio file.
struct AudioChunk { let index: Int; let url: URL; let ms: Int }

/// One dictation's uploads, per the API contract: earlier chunks go up as they close
/// (transcribe only); the last one carries their transcripts back as `prior`, and the
/// rewrite runs once. Shared by the Speak screen and the keyboard session.
@MainActor
final class DictationJob {
    enum Outcome { case result(DictateResult), tooShort }

    let api: DictateAPI
    let source: String
    private var earlier: [Int: Task<PriorChunk, Never>] = [:]

    init(api: DictateAPI, source: String) {
        self.api = api
        self.source = source
    }

    /// An earlier chunk closed while recording continues: upload it now.
    func add(_ chunk: AudioChunk) {
        let api = self.api, source = self.source
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

    /// Recording stopped. Sends the last chunk (with `prior` when there were earlier ones).
    func finish(last: AudioChunk?, style: DictateStyle, target: String?) async throws -> Outcome {
        defer { if let url = last?.url { try? FileManager.default.removeItem(at: url) } }
        let pending = earlier.sorted { $0.key < $1.key }.map(\.value)
        earlier = [:]

        // Nothing at all, or a tap that was over before it started.
        if pending.isEmpty, (last?.ms ?? 0) < 600 { return .tooShort }

        if pending.isEmpty {
            return .result(try await api.speak(audio: last?.url, source: source, style: style, target: target))
        }
        var prior: [PriorChunk] = []
        for t in pending { prior.append(await t.value) }
        // Omit the last audio only when it is effectively empty.
        let lastAudio = (last?.ms ?? 0) >= 500 ? last?.url : nil
        return .result(try await api.speak(audio: lastAudio, source: source, style: style, target: target,
                                           prior: prior, chunkIndex: prior.count, chunkMs: last?.ms ?? 0))
    }
}
