import Foundation

// Client for POST https://taoslite.com/api/dictate.
// Contract: docs/dictate/CLAUDE.md → "API contract" in xdrabbit/taos-lite (PR #145).
// Field names below are copied from that section; change them only with it.

enum DictateStyle: String, CaseIterable, Identifiable, Codable {
    case formal, professional, conversational, casual
    var id: String { rawValue }
    var label: String { L("style.\(rawValue)") }
}

struct Language: Identifiable, Hashable {
    let code: String   // catalog code (Whisper's), never a display name
    var id: String { code }
    var label: String { L("lang.\(code)") }

    /// A short, deliberate list. Every code exists in taos-lite's lib/languages/catalog.ts.
    static let all: [Language] = ["en", "es", "fr", "pt", "it", "de"].map(Language.init)
    static func named(_ code: String) -> Language { all.first { $0.code == code } ?? Language(code: "en") }
}

/// Response of a speak (1 or 2b) or re-style (3) request.
struct DictateResult: Decodable, Equatable {
    let raw: String
    let styled: String
    let style: String
    let lang: String
    let chunks: Int?
    let lost: Int?
}

/// Response of an earlier chunk (2a).
struct ChunkResponse: Decodable {
    struct Chunk: Decodable { let index: Int; let text: String; let ms: Int }
    let chunk: Chunk
}

/// One entry of `prior` on the last chunk.
enum PriorChunk: Encodable {
    case text(String, ms: Int)
    case lost(ms: Int)

    private enum K: String, CodingKey { case text, lost, ms }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .text(t, ms): try c.encode(t, forKey: .text); try c.encode(ms, forKey: .ms)
        case let .lost(ms): try c.encode(true, forKey: .lost); try c.encode(ms, forKey: .ms)
        }
    }
}

struct DecodeResult: Decodable, Equatable {
    let raw: String
    let cleaned: String
    let translation: String
    let notes: [String]
    let sourceLanguage: String?
}

enum DictateError: LocalizedError, Equatable {
    case nothingHeard            // 422
    case notAvailable            // 404
    case signedOut               // 401 after one refresh
    case server(Int, String)     // anything else with a message
    case network(String)

    var errorDescription: String? {
        switch self {
        case .nothingHeard: return L("error.nothing_heard")
        case .notAvailable: return L("error.not_available")
        case .signedOut: return L("error.signed_out")
        case let .server(_, msg): return msg
        case let .network(msg): return msg
        }
    }

    /// Contract: retry once on 502/504 and network failures, never on 4xx.
    var retryable: Bool {
        switch self {
        case .network: return true
        case let .server(code, _): return code == 502 || code == 504
        default: return false
        }
    }
}

/// Supplies a fresh access token; `forceRefresh` after a 401.
protocol TokenProvider: Sendable {
    func accessToken(forceRefresh: Bool) async throws -> String
}

struct DictateAPI {
    let tokens: TokenProvider
    var session: URLSession = .shared

    // MARK: Requests

    /// 1. One recording, or 2b. the last chunk of a long one (when `prior` is non-nil).
    func speak(audio: URL?, source: String, style: DictateStyle, target: String?,
               prior: [PriorChunk]? = nil, chunkIndex: Int? = nil, chunkMs: Int? = nil) async throws -> DictateResult {
        var form = MultipartForm()
        if let audio { try form.addFile(name: "audio", url: audio) }
        form.add("source", source)
        form.add("style", style.rawValue)
        form.add("target", target ?? "same")
        form.addWords()
        if let prior {
            let json = try JSONEncoder().encode(prior)
            form.add("prior", String(decoding: json, as: UTF8.self))
            if let chunkIndex { form.add("chunk_index", String(chunkIndex)) }
            if let chunkMs { form.add("chunk_ms", String(chunkMs)) }
        }
        return try await send(form: form, timeout: prior == nil ? 200 : 280)
    }

    /// 2a. An earlier chunk: transcribe only.
    func chunk(audio: URL, source: String, index: Int, ms: Int) async throws -> ChunkResponse {
        var form = MultipartForm()
        try form.addFile(name: "audio", url: audio)
        form.add("source", source)
        form.add("chunk_part", "1")
        form.addWords()
        form.add("chunk_index", String(index))
        form.add("chunk_ms", String(ms))
        return try await send(form: form, timeout: 210)
    }

    /// 3. Same words, another style or language.
    func restyle(raw: String, style: DictateStyle, source: String, target: String?) async throws -> DictateResult {
        try await send(json: ["raw": raw, "style": style.rawValue, "source": source, "target": target ?? "same",
                              "words": SharedPrefs.words], timeout: 160)
    }

    /// 4. Decoder.
    func decode(raw: String, reader: String, other: String) async throws -> DecodeResult {
        try await send(json: ["mode": "decode", "raw": raw, "reader": reader, "other": other,
                              "words": SharedPrefs.words], timeout: 90)
    }

    // MARK: Transport

    private func send<T: Decodable>(form: MultipartForm, timeout: TimeInterval) async throws -> T {
        let body = form.finish()
        return try await perform(timeout: timeout) { req in
            req.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
    }

    private func send<T: Decodable>(json: [String: Any], timeout: TimeInterval) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: json)
        return try await perform(timeout: timeout) { req in
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
    }

    /// One attempt with 401 → refresh → retry once, plus one retry on 502/504/network.
    private func perform<T: Decodable>(timeout: TimeInterval, configure: (inout URLRequest) -> Void) async throws -> T {
        do {
            return try await attempt(timeout: timeout, configure: configure)
        } catch let e as DictateError where e.retryable {
            return try await attempt(timeout: timeout, configure: configure)
        }
    }

    private func attempt<T: Decodable>(timeout: TimeInterval, configure: (inout URLRequest) -> Void) async throws -> T {
        var (data, status) = try await raw(timeout: timeout, forceRefresh: false, configure: configure)
        if status == 401 {
            (data, status) = try await raw(timeout: timeout, forceRefresh: true, configure: configure)
            if status == 401 { throw DictateError.signedOut }
        }
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DictateError.server(status, L("error.bad_reply"))
        }
    }

    private func raw(timeout: TimeInterval, forceRefresh: Bool,
                     configure: (inout URLRequest) -> Void) async throws -> (Data, Int) {
        let token: String
        do { token = try await tokens.accessToken(forceRefresh: forceRefresh) }
        catch { throw DictateError.signedOut }
        var req = URLRequest(url: TaosConfig.dictateURL, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        configure(&req)
        do {
            let (data, resp) = try await session.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DictateError.network(L("error.network"))
        }
    }

    private static func error(status: Int, data: Data) -> DictateError {
        switch status {
        case 422: return .nothingHeard
        case 404: return .notAvailable
        default:
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            return .server(status, msg ?? String(format: L("error.http"), status))
        }
    }
}

/// Minimal multipart/form-data builder.
struct MultipartForm {
    let boundary = "taos-\(UUID().uuidString)"
    private var data = Data()
    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func add(_ name: String, _ value: String) {
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    /// The contract asks for a filename and type that match the audio: `audio.m4a` / `audio/mp4`.
    /// "Our words", as the JSON string the contract asks for. Omitted when empty.
    mutating func addWords() {
        let words = SharedPrefs.words
        guard !words.isEmpty, let json = try? JSONSerialization.data(withJSONObject: words) else { return }
        add("words", String(decoding: json, as: UTF8.self))
    }

    mutating func addFile(name: String, url: URL) throws {
        let bytes = try Data(contentsOf: url)
        data.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"audio.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n")
        data.append(bytes)
        data.append("\r\n")
    }

    func finish() -> Data {
        var out = data
        out.append("--\(boundary)--\r\n")
        return out
    }
}

private extension Data {
    mutating func append(_ s: String) { append(Data(s.utf8)) }
}
