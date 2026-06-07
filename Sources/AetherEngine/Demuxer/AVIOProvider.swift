import Libavformat

/// Internal abstraction over a custom-AVIO byte source attached to an
/// `AVFormatContext.pb`. Both `AVIOReader` (URL / HTTP) and
/// `CustomIOReaderBridge` (a user `IOReader`) conform, so the `Demuxer`
/// opens, tears down, and accounts for either at one identical seam.
protocol AVIOProvider: AnyObject {
    /// The allocated `AVIOContext`, valid between `open()` and `close()`.
    var context: UnsafeMutablePointer<AVIOContext>? { get }

    /// Bytes fetched since open, for the engine's memory probe. Custom
    /// readers that do not track network I/O may report 0.
    var cumulativeBytesFetched: Int64 { get }

    /// Allocate the `AVIOContext` and begin sourcing bytes.
    func open() throws

    /// Fast, allocation-free: unblock a suspended read so the demuxer's
    /// access lock can be acquired during teardown. Called before `close()`.
    func markClosed()

    /// Free the `AVIOContext` and release the underlying source. Idempotent.
    func close()
}
