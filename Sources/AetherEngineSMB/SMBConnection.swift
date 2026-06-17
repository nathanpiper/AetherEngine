import Foundation
import AMSMB2

/// A read-only SMB2/3 byte source over one share + file path, backed by AMSMB2.
/// There is no public persistent file handle in AMSMB2, so each `read` issues a
/// fresh `contents(atPath:range:)` that opens/seeks/closes internally.
public final class SMBConnection: ByteRangeSource, @unchecked Sendable {
    public struct SMBError: Error { public let message: String }

    private let client: SMB2Manager
    private let path: String
    public let byteSize: Int64

    private init(client: SMB2Manager, path: String, byteSize: Int64) {
        self.client = client
        self.path = path
        self.byteSize = byteSize
    }

    /// Connect, authenticate (NTLMv2 / guest), tree-connect to `share`, and
    /// stat `path` for its size. `server` is e.g. `smb://host` or `smb://host:445`.
    public static func connect(
        server: URL, share: String, path: String,
        user: String, password: String, domain: String = ""
    ) async throws -> SMBConnection {
        let credential = URLCredential(
            user: user, password: password, persistence: .forSession
        )
        guard let client = SMB2Manager(url: server, domain: domain, credential: credential) else {
            throw SMBError(message: "SMB2Manager init failed for \(server.absoluteString)")
        }
        try await client.connectShare(name: share)

        let attrs = try await client.attributesOfItem(atPath: path)
        guard let size = attrs[.fileSizeKey] as? Int64 ?? (attrs[.fileSizeKey] as? Int).map(Int64.init) else {
            throw SMBError(message: "no fileSizeKey for \(path)")
        }
        return SMBConnection(client: client, path: path, byteSize: size)
    }

    public func read(at offset: Int64, length: Int) async throws -> Data {
        guard length > 0, offset < byteSize else { return Data() }
        let upper = min(offset &+ Int64(length), byteSize)
        return try await client.contents(atPath: path, range: offset..<upper)
    }

    public func close() {
        // Fire-and-forget disconnect; AMSMB2 has no synchronous close.
        let client = self.client
        Task { try? await client.disconnectShare() }
    }
}
