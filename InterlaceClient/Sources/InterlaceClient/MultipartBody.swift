import Foundation
import Synchronization

struct MultipartBody: Sendable {
    let contentType: String
    let prefix: Data
    let suffix: Data

    init(fields: [(String, String)], fileName: String, contentType: String) throws {
        guard !contentType.utf8.contains(13), !contentType.utf8.contains(10) else {
            throw InterlaceError.invalidRequest
        }
        let boundary = "Interlace-" + UUID().uuidString
        self.contentType = "multipart/form-data; boundary=\(boundary)"
        var header = ""
        for (name, value) in fields {
            header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.quoted(name))\"\r\n\r\n\(value)\r\n"
        }
        header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(Self.quoted(fileName))\"\r\n"
        header += "Content-Type: \(contentType)\r\n\r\n"
        prefix = Data(header.utf8)
        suffix = Data("\r\n--\(boundary)--\r\n".utf8)
    }

    func body(_ bytes: Data) -> Data {
        prefix + bytes + suffix
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\"", with: "%22")
    }
}

/// A multipart body sent straight from its file, so an upload needs neither a copy of the file nor the file in memory.
final class MultipartFileBody: Sendable {
    /// Bytes in the whole body, for Content-Length.
    let length: Int64
    private let fileURL: URL
    private let prefix: Data
    private let suffix: Data
    private let current = Mutex<MultipartFileStream?>(nil)

    init(fileURL: URL, prefix: Data, suffix: Data) throws {
        guard fileURL.isFileURL else { throw InterlaceError.invalidRequest }
        guard let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        length = Int64(prefix.count + size + suffix.count)
        self.fileURL = fileURL
        self.prefix = prefix
        self.suffix = suffix
    }

    /// A fresh stream of the body from its first byte; the previous one stops.
    func stream() throws -> InputStream {
        let stream = try MultipartFileStream(fileURL: fileURL, prefix: prefix, suffix: suffix)
        current.withLock {
            $0?.stop()
            $0 = stream
        }
        return stream.input
    }

    func stop() {
        current.withLock { $0?.stop() }
    }
}

/// Writes the prefix, the file in chunks, then the suffix into a bound stream pair from a thread of its own;
/// URLSession reads the other end.
final class MultipartFileStream: NSObject, StreamDelegate, @unchecked Sendable {
    static let chunk = 256 * 1024

    let input: InputStream
    private let output: OutputStream
    private let file: FileHandle
    private let suffix: Data
    private let stopped = Atomic(false)
    // Touched only on the writing thread.
    private var buffer: Data
    private var offset = 0
    private var fileDone = false
    private var finished = false

    init(fileURL: URL, prefix: Data, suffix: Data) throws {
        file = try FileHandle(forReadingFrom: fileURL)
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: Self.chunk, inputStream: &input, outputStream: &output)
        guard let input, let output else { throw InterlaceError.invalidRequest }
        self.input = input
        self.output = output
        self.suffix = suffix
        buffer = prefix
        super.init()
        let thread = Thread { [self] in write() }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Ends the body where it is; the writing thread exits within a quarter second.
    func stop() {
        stopped.store(true, ordering: .relaxed)
    }

    private func write() {
        output.delegate = self
        output.schedule(in: .current, forMode: .default)
        output.open()
        // A cancelled upload stops reading, so no stream event may come to end the loop; the limit rechecks `stopped`.
        while !finished, !stopped.load(ordering: .relaxed),
              RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25)) {}
        output.remove(from: .current, forMode: .default)
        output.delegate = nil
        output.close()
        try? file.close()
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        if event.contains(.errorOccurred) || event.contains(.endEncountered) {
            finished = true
        } else if event.contains(.hasSpaceAvailable) {
            pump()
        }
    }

    private func pump() {
        while offset == buffer.count {
            guard let next = nextChunk() else {
                finished = true
                return
            }
            buffer = next
            offset = 0
        }
        let written = buffer.withUnsafeBytes { bytes in
            output.write(bytes.bindMemory(to: UInt8.self).baseAddress! + offset, maxLength: bytes.count - offset)
        }
        if written < 0 {
            finished = true
        } else {
            offset += written
        }
    }

    /// nil once the suffix is out, or when the file cannot be read; a body cut short fails the request.
    private func nextChunk() -> Data? {
        guard !fileDone else { return nil }
        do {
            if let chunk = try file.read(upToCount: Self.chunk), !chunk.isEmpty { return chunk }
        } catch {
            fileDone = true
            return nil
        }
        fileDone = true
        return suffix
    }
}
