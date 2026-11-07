import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Parses server-sent-events frames line by line; fields repeat per the spec, data lines join with newlines.
struct SSEFrameParser {
    struct Frame: Equatable { var id: String?; var event = "message"; var data = "" }
    private var id: String?
    private var event: String?
    private var data: [String] = []

    /// Feed one line without its terminator; returns a frame when a blank line completes one.
    mutating func feed(line raw: String) -> Frame? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            guard id != nil || event != nil || !data.isEmpty else { return nil }
            let frame = Frame(id: id, event: event ?? "message", data: data.joined(separator: "\n"))
            id = nil; event = nil; data = []
            return frame
        }
        if line.hasPrefix(":") { return nil }
        let field: String, value: String
        if let colon = line.firstIndex(of: ":") {
            field = String(line[..<colon])
            var rest = String(line[line.index(after: colon)...])
            if rest.hasPrefix(" ") { rest.removeFirst() }
            value = rest
        } else { field = line; value = "" }
        switch field {
        case "id": id = value
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }
}

public struct SubscribeOptions: Sendable {
    /// Resume after this durable cursor; capture it with `changesHead()` before loading a snapshot.
    public var after: String?
    public var initialBackoff: TimeInterval = 0.5
    public var maxBackoff: TimeInterval = 10
    /// A connection without any frame for this long is reopened. The server heartbeats well inside it.
    public var idleTimeout: TimeInterval = 30
    public init(after: String? = nil) { self.after = after }
}

/// The cursor and liveness of one subscription, shared between the reading task and its watchdog.
actor StreamState {
    private(set) var cursor: String
    private var lastFrame = Date()
    init(cursor: String) { self.cursor = cursor }
    func touch() { lastFrame = Date() }
    func advance(to next: String) { cursor = next; lastFrame = Date() }
    func silent(for interval: TimeInterval) -> Bool { Date().timeIntervalSince(lastFrame) > interval }
}

extension AdoorClient {
    /// A resumable change subscription. The cursor advances only on frames the server sent, so a reconnect never
    /// skips or repeats an authorized event. The stream ends when its task is cancelled, and throws when the
    /// caller's authority ends.
    public func subscribeChanges(_ options: SubscribeOptions = SubscribeOptions()) -> AsyncThrowingStream<ChangeFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let state = StreamState(cursor: options.after ?? "0")
                var delay = options.initialBackoff
                while !Task.isCancelled {
                    await state.touch()
                    let attempt = Task<Void, Error> { try await self.readStream(state: state, continuation: continuation) }
                    let watchdog = Task<Void, Never> {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: UInt64(options.idleTimeout / 2 * 1_000_000_000))
                            if Task.isCancelled { return }
                            if await state.silent(for: options.idleTimeout) { attempt.cancel(); return }
                        }
                    }
                    do {
                        try await withTaskCancellationHandler { try await attempt.value } onCancel: { attempt.cancel(); watchdog.cancel() }
                        watchdog.cancel()
                        delay = options.initialBackoff
                    } catch {
                        watchdog.cancel()
                        if Task.isCancelled { break }
                        let typed = error as? AdoorError ?? AdoorError.network(error)
                        if typed.authority { continuation.finish(throwing: typed); return }
                    }
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay = min(options.maxBackoff, delay * 2)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One connection attempt: reads frames until the server or the network ends the stream.
    func readStream(state: StreamState, continuation: AsyncThrowingStream<ChangeFrame, Error>.Continuation) async throws {
        let request = try await makeRequest(path: "api/changes/stream", accept: "text/event-stream", extra: ["Last-Event-ID": await state.cursor])
        let transport = ChunkedResponse(configuration: session.configuration)
        let chunks = transport.open(request)
        let http: HTTPURLResponse
        do { http = try await transport.response() }
        catch { throw error as? AdoorError ?? AdoorError.network(error) }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await chunk in chunks { body.append(chunk); if body.count > 65_536 { break } }
            throw AdoorError.from(response: http, data: body)
        }
        await state.touch()
        var parser = SSEFrameParser(), pending = Data()
        // Split on newline bytes. AsyncLines-style APIs drop the blank line that ends an SSE frame.
        for try await chunk in chunks {
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: newline)
                pending.removeSubrange(...newline)
                if line.count > 1_048_576 { throw AdoorError(code: "STREAM_FRAME_LIMIT", message: "The change stream line exceeded its limit.", status: 502) }
                await state.touch()
                guard let frame = parser.feed(line: String(decoding: line, as: UTF8.self)) else { continue }
                switch frame.event {
                case "change":
                    let change = try JSON.decode(ChangeEvent.self, from: Data(frame.data.utf8))
                    await state.advance(to: change.cursor)
                    continuation.yield(.change(change))
                case "checkpoint":
                    let checkpoint = try JSON.decode(Checkpoint.self, from: Data(frame.data.utf8))
                    await state.advance(to: checkpoint.cursor)
                    continuation.yield(.checkpoint(cursor: checkpoint.cursor))
                case "error":
                    let body = try JSON.decode(JSONValue.self, from: Data(frame.data.utf8))
                    throw AdoorError(code: body["error"]?["code"]?.stringValue ?? "STREAM_FAILED", message: body["error"]?["message"]?.stringValue ?? "The change stream stopped.", status: 503)
                default:
                    break
                }
            }
            if pending.count > 1_048_576 { throw AdoorError(code: "STREAM_FRAME_LIMIT", message: "The change stream line exceeded its limit.", status: 502) }
        }
    }
}

/// Incremental body for the change stream. Linux URLSession has no `bytes(for:)`, and a buffered `data(for:)`
/// would not return until the stream ended. Redirects are refused, matching the other authenticated calls.
private final class ChunkedResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var body: AsyncThrowingStream<Data, Error>.Continuation?
    private var responseWaiter: CheckedContinuation<HTTPURLResponse, Error>?
    private var responseResult: Result<HTTPURLResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionTask?

    init(configuration: URLSessionConfiguration) { self.configuration = configuration }

    func open(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        let streaming = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = streaming.dataTask(with: request)
        self.session = streaming
        self.task = task
        return AsyncThrowingStream { continuation in
            self.body = continuation
            continuation.onTermination = { _ in task.cancel(); streaming.invalidateAndCancel() }
            task.resume()
        }
    }

    func response() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let responseResult { lock.unlock(); continuation.resume(with: responseResult) }
            else { responseWaiter = continuation; lock.unlock() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = (response as? HTTPURLResponse) ?? HTTPURLResponse(url: response.url ?? URL(string: "https://invalid.invalid")!, statusCode: 0, httpVersion: nil, headerFields: nil)!
        lock.lock(); responseResult = .success(http); let waiter = responseWaiter; responseWaiter = nil; lock.unlock()
        waiter?.resume(returning: http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { body?.yield(data) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let waiting = responseResult == nil; lock.unlock()
        if waiting {
            let failure: Error = error.map { AdoorError.network($0) } ?? AdoorError(code: "HTTP_INVALID", message: "The server returned no HTTP response.", status: 0)
            lock.lock(); responseResult = .failure(failure); let waiter = responseWaiter; responseWaiter = nil; lock.unlock()
            waiter?.resume(throwing: failure)
        }
        if let error { body?.finish(throwing: AdoorError.network(error)) } else { body?.finish() }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct Checkpoint: Decodable { let cursor: String }
