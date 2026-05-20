import Foundation
import GCDWebServer

/// HLS-fMP4 loopback HTTP server backed by GCDWebServer.
///
/// Replaces the handrolled BSD-socket `HLSLocalServer` that triggered
/// CFNetwork's loopback I/O buffer pool to leak ~545 KB per segment
/// served (Instruments 2026-05-20: `VM: libnetwork` 66 MiB persistent,
/// 100% retention, OOM after ~15 min of 4K HDR playback).
///
/// DrHurt's debug Mac server (WebDAVNav) that did NOT leak with the
/// same AVPlayer client is also GCDWebServer-based. The same library
/// on-device is the most direct test that AVPlayer's CFNetwork pool
/// behaviour follows from the server-side response shape (framing,
/// headers, dispatch model) rather than from anything specific to
/// localhost or the asset content.
///
/// Same external API as `HLSLocalServer` so `HLSVideoEngine` swaps in
/// a single line. Diagnostic counters retained for memprobe wiring
/// (`activeConnectionCount`, `lifetimeBytesSent`, `lifetimeSendfileBytes`)
/// — the `sendfile` counter is repurposed to count bytes served via
/// `GCDWebServerFileResponse` (kernel-streamed file body, the moral
/// equivalent of our old sendfile fast path).
final class HLSGCDServer: @unchecked Sendable {

    // MARK: - Public surface (matches old HLSLocalServer)

    private weak var provider: HLSSegmentProvider?
    private let webServer = GCDWebServer()
    private(set) var port: UInt16 = 0
    private(set) var seg0FetchTime: Date?
    /// Strong reference to the GCDWebServerDelegate bridge so it
    /// isn't deallocated immediately (the server's `delegate`
    /// property is `weak`).
    private var connectionTracker: ConnectionTracker?

    init(provider: HLSSegmentProvider) {
        self.provider = provider
    }

    var playlistURL: URL? {
        guard port > 0 else { return nil }
        let path = (provider?.masterCodecs != nil) ? "master.m3u8" : "media.m3u8"
        return URL(string: "http://127.0.0.1:\(port)/\(path)")
    }

    var mediaPlaylistURL: URL? {
        guard port > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/media.m3u8")
    }

    // MARK: - Lifecycle

    func start() throws {
        registerHandlers()
        let options: [String: Any] = [
            GCDWebServerOption_Port: 0,             // 0 = OS picks free port
            GCDWebServerOption_BindToLocalhost: true,
        ]
        try webServer.start(options: options)
        port = UInt16(webServer.port)
        EngineLog.emit("[HLSGCDServer] Listening on port \(port)",
                       category: .hlsServer)
    }

    func stop() {
        if webServer.isRunning {
            webServer.stop()
            EngineLog.emit("[HLSGCDServer] stopped", category: .hlsServer)
        }
    }

    // MARK: - Diagnostic counters

    private let counterLock = NSLock()
    private var _lifetimeBytesSent: Int = 0
    private var _lifetimeFileBytes: Int = 0
    private var _activeConnections: Int = 0

    var lifetimeBytesSent: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return _lifetimeBytesSent
    }

    /// Bytes that went out via `GCDWebServerFileResponse` (kernel-side
    /// file streaming). Mapped to the old `srvSfMB` field in the engine
    /// memprobe so the diagnostic line keeps its shape across the
    /// server swap.
    var lifetimeSendfileBytes: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return _lifetimeFileBytes
    }

    var activeConnectionCount: Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        return _activeConnections
    }

    private func bumpBytesSent(_ n: Int, file: Bool) {
        guard n > 0 else { return }
        counterLock.lock()
        _lifetimeBytesSent &+= n
        if file { _lifetimeFileBytes &+= n }
        counterLock.unlock()
    }

    // MARK: - Routing

    private func registerHandlers() {
        // GCDWebServer hands the processBlock to its own GCD work
        // queue. Provider methods are thread-safe.
        let tracker = ConnectionTracker(owner: self)
        connectionTracker = tracker
        webServer.delegate = tracker

        // GET /master.m3u8
        webServer.addHandler(
            forMethod: "GET",
            path: "/master.m3u8",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            guard let self, let provider = self.provider else {
                return GCDWebServerResponse(statusCode: 503)
            }
            let text = HLSLocalServer.buildMasterPlaylistText(provider: provider)
            let data = Data(text.utf8)
            let response = GCDWebServerDataResponse(
                data: data,
                contentType: "application/vnd.apple.mpegurl"
            )
            self.bumpBytesSent(data.count, file: false)
            EngineLog.emit("[HLSGCDServer] -> 200 /master.m3u8 bytes=\(data.count)",
                           category: .hlsServer)
            return response
        }

        // GET /media.m3u8
        webServer.addHandler(
            forMethod: "GET",
            path: "/media.m3u8",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            guard let self, let provider = self.provider else {
                return GCDWebServerResponse(statusCode: 503)
            }
            let text = HLSLocalServer.buildMediaPlaylistText(provider: provider)
            let data = Data(text.utf8)
            let response = GCDWebServerDataResponse(
                data: data,
                contentType: "application/vnd.apple.mpegurl"
            )
            self.bumpBytesSent(data.count, file: false)
            EngineLog.emit("[HLSGCDServer] -> 200 /media.m3u8 bytes=\(data.count)",
                           category: .hlsServer)
            return response
        }

        // GET /init.mp4
        webServer.addHandler(
            forMethod: "GET",
            path: "/init.mp4",
            request: GCDWebServerRequest.self
        ) { [weak self] _ in
            guard let self, let provider = self.provider else {
                return GCDWebServerResponse(statusCode: 503)
            }
            guard let data = provider.initSegment(), !data.isEmpty else {
                EngineLog.emit("[HLSGCDServer] -> 404 /init.mp4 not ready",
                               category: .hlsServer)
                return GCDWebServerResponse(statusCode: 404)
            }
            let response = GCDWebServerDataResponse(
                data: data,
                contentType: "video/mp4"
            )
            self.bumpBytesSent(data.count, file: false)
            EngineLog.emit("[HLSGCDServer] -> 200 /init.mp4 bytes=\(data.count)",
                           category: .hlsServer)
            return response
        }

        // GET /seg{N}.mp4 — prefer GCDWebServerFileResponse so the
        // body streams from disk through GCDWebServer's chunked write
        // path. No Swift Data wrapping the segment bytes; no per-
        // request 5-15 MiB heap allocation. Falls back to the Data
        // path for providers that aren't file-backed (BufferedSegment
        // Provider in the audio engine, if it's ever wired here).
        webServer.addHandler(
            forMethod: "GET",
            pathRegex: "^/seg(\\d+)\\.mp4$",
            request: GCDWebServerRequest.self
        ) { [weak self] request in
            guard let self, let provider = self.provider else {
                return GCDWebServerResponse(statusCode: 503)
            }
            let path = request.path
            // `/seg42.mp4` → `42`
            let indexStr = path.dropFirst("/seg".count).dropLast(".mp4".count)
            guard let index = Int(indexStr), index >= 0 else {
                return GCDWebServerResponse(statusCode: 400)
            }
            if index == 0 {
                self.counterLock.lock()
                if self.seg0FetchTime == nil { self.seg0FetchTime = Date() }
                self.counterLock.unlock()
            }
            // File-backed fast path: kernel-side body streaming.
            if let fileURL = provider.mediaSegmentURL(at: index),
               let response = GCDWebServerFileResponse(file: fileURL.path) {
                response.contentType = "video/mp4"
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
                self.bumpBytesSent(fileSize, file: true)
                EngineLog.emit("[HLSGCDServer] -> 200 /seg\(index).mp4 bytes=\(fileSize) [file]",
                               category: .hlsServer)
                return response
            }
            // Fallback: in-memory Data (blocking fetch with timeout).
            if let data = provider.mediaSegment(at: index), !data.isEmpty {
                let response = GCDWebServerDataResponse(
                    data: data,
                    contentType: "video/mp4"
                )
                self.bumpBytesSent(data.count, file: false)
                EngineLog.emit("[HLSGCDServer] -> 200 /seg\(index).mp4 bytes=\(data.count) [data]",
                               category: .hlsServer)
                return response
            }
            let providerCount = provider.segmentCount
            EngineLog.emit("[HLSGCDServer] -> 404 /seg\(index).mp4 segmentCount=\(providerCount)",
                           category: .hlsServer)
            return GCDWebServerResponse(statusCode: 404)
        }
    }

    fileprivate func connectionOpened() {
        counterLock.lock()
        _activeConnections += 1
        counterLock.unlock()
    }

    fileprivate func connectionClosed() {
        counterLock.lock()
        _activeConnections = max(0, _activeConnections - 1)
        counterLock.unlock()
    }
}

/// `GCDWebServerDelegate` bridge so the server can tick our
/// `activeConnectionCount` diagnostic without HLSGCDServer itself
/// having to inherit NSObject. GCDWebServer's connect/disconnect
/// callbacks are dispatched on its internal queue.
private final class ConnectionTracker: NSObject, GCDWebServerDelegate {
    weak var owner: HLSGCDServer?
    init(owner: HLSGCDServer) {
        self.owner = owner
    }
    func webServerDidConnect(_ server: GCDWebServer) {
        owner?.connectionOpened()
    }
    func webServerDidDisconnect(_ server: GCDWebServer) {
        owner?.connectionClosed()
    }
}
