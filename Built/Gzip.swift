import Compression
import Foundation

/// Gzip (RFC 1952) op basis van Apple's `Compression`.
///
/// `compression_encode_buffer` met `COMPRESSION_ZLIB` levert een **raw DEFLATE**-blok:
/// geen header, geen checksum. Een server die `Content-Encoding: gzip` leest verwacht
/// wél de gzip-omhulling, dus die zetten we er zelf omheen — 10 bytes header, en achteraan
/// de CRC32 en de lengte van de originele data, allebei little-endian.
///
/// Alleen inpakken: uitpakken doet de app nergens, dus dat staat er niet in.
enum Gzip {
    /// nil als er niets te comprimeren valt of het buffer-formaat tegenvalt; de beller
    /// moet dan gewoon de ongecomprimeerde body sturen.
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty, let deflated = deflate(data) else { return nil }
        // 0x1f 0x8b = magic, 0x08 = deflate, geen vlaggen, geen mtime, 0xff = onbekend OS.
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(deflated)
        out.append(littleEndian: crc32(data))
        out.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
        return out
    }

    /// Raw DEFLATE. De marge van 64 KB dekt het randgeval waarin niet-comprimeerbare
    /// invoer iets groter wordt dan de bron.
    private static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + 64 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { raw -> Int in
            guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, source, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: destination, count: written)
    }

    // MARK: - CRC32

    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    /// De gzip-trailer is gedefinieerd als vier losse bytes, laagste eerst. Uitschrijven
    /// leest hier beter dan een pointer-truc — en binnen een Data-extensie zou
    /// `withUnsafeBytes(of:)` bovendien op de instance-methode vallen in plaats van op de
    /// globale functie.
    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [UInt8(truncatingIfNeeded: value),
                            UInt8(truncatingIfNeeded: value >> 8),
                            UInt8(truncatingIfNeeded: value >> 16),
                            UInt8(truncatingIfNeeded: value >> 24)])
    }
}
