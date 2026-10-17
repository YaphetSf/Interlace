import Foundation

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

    nonisolated static func write(fileURL: URL, prefix: Data, suffix: Data, to destination: URL) throws {
        guard fileURL.isFileURL else { throw InterlaceError.invalidRequest }
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.write(contentsOf: prefix)
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: suffix)
    }

    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\"", with: "%22")
    }
}
