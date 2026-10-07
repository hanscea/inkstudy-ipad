import Foundation

public enum StoredZIP {
    public struct Entry: Sendable {
        public let name: String
        public let url: URL
        public init(name: String, url: URL) { self.name = name; self.url = url }
    }

    // Stored entries keep exports dependency-free and permit streaming one source file at a time.
    public static func write(_ entries: [Entry], to output: URL) throws {
        guard entries.count < 65_535, Set(entries.map(\.name)).count == entries.count else {
            throw DrawingError.persistence("ZIP entry limit or duplicate path.")
        }
        let temporary = output.appendingPathExtension(UUID().uuidString + ".partial")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw DrawingError.persistence("ZIP creation failed.") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        var central = Data()
        var offset: UInt64 = 0
        for entry in entries {
            guard !entry.name.hasPrefix("/"), !entry.name.contains("\\"), !entry.name.split(separator: "/").contains(".."),
                  !entry.name.isEmpty, entry.name.utf8.count < 65_535 else { throw DrawingError.persistence("Unsafe ZIP path.") }
            let content = try Data(contentsOf: entry.url, options: .mappedIfSafe)
            guard content.count < Int(UInt32.max), offset + UInt64(content.count) + UInt64(entry.name.utf8.count) + 30 < UInt32.max else {
                throw DrawingError.persistence("Export exceeds ZIP32 size limit.")
            }
            let name = Data(entry.name.utf8), crc = crc32(content), size = UInt32(content.count)
            var local = Data()
            local.le(UInt32(0x04034b50)); local.le(UInt16(20)); local.le(UInt16(0x0800)); local.le(UInt16(0))
            local.le(UInt16(0)); local.le(UInt16(0x0021)); local.le(crc); local.le(size); local.le(size)
            local.le(UInt16(name.count)); local.le(UInt16(0)); local.append(name)
            try file.write(contentsOf: local); try file.write(contentsOf: content)
            central.le(UInt32(0x02014b50)); central.le(UInt16(20)); central.le(UInt16(20)); central.le(UInt16(0x0800))
            central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0x0021)); central.le(crc); central.le(size); central.le(size)
            central.le(UInt16(name.count)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0))
            central.le(UInt16(0)); central.le(UInt32(0)); central.le(UInt32(offset)); central.append(name)
            offset += UInt64(local.count + content.count)
        }
        guard offset + UInt64(central.count) + 22 < UInt32.max else { throw DrawingError.persistence("ZIP32 directory is too large.") }
        try file.write(contentsOf: central)
        var end = Data()
        end.le(UInt32(0x06054b50)); end.le(UInt16(0)); end.le(UInt16(0)); end.le(UInt16(entries.count)); end.le(UInt16(entries.count))
        end.le(UInt32(central.count)); end.le(UInt32(offset)); end.le(UInt16(0))
        try file.write(contentsOf: end); try file.synchronize(); try file.close()
        guard !FileManager.default.fileExists(atPath: output.path) else { throw DrawingError.persistence("ZIP output already exists.") }
        try FileManager.default.moveItem(at: temporary, to: output)
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return crc ^ UInt32.max
    }

    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
