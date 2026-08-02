import Compression
import Foundation
import SwiftData
import Testing
@testable import Built

/// De sync heeft geen server nodig om te testen: de interessante beslissingen zitten in
/// pure functies eromheen — mag er een nieuw anoniem account komen, is de vingerafdruk
/// stabiel, en klopt de gzip-stream die we zelf in elkaar zetten.
@Suite("Sync")
struct SyncTests {

    // MARK: - Anoniem aanmelden

    /// `auth.session` gooit zowel bij "geen sessie" als bij "refresh mislukt". Alleen het
    /// eerste geval mag een nieuw account opleveren; het tweede leverde een stille
    /// accountwissel op, met de volledige dataset onder een vers user_id en de originele
    /// rijen als wees achter.
    @Test("Verse install zonder sessie meldt anoniem aan")
    @MainActor func verseInstallMeldtAnoniemAan() {
        #expect(Sync.mayCreateAnonymousAccount(hasStoredSession: false))
    }

    @Test("Mislukte refresh met een opgeslagen sessie maakt géén nieuw account")
    @MainActor func mislukteRefreshMaaktGeenNieuwAccount() {
        #expect(Sync.mayCreateAnonymousAccount(hasStoredSession: true) == false)
    }

    // MARK: - Vingerafdruk

    /// Zonder `sortedKeys` heeft dezelfde data geen vaste JSON-vorm: `schedule`, `targets`
    /// en `exercise_notes` zijn dictionaries. Dan verschilt de vingerafdruk zonder dat er
    /// iets veranderd is, en pusht de app de volledige database voor niets.
    @Test("Encoder geeft dezelfde bytes voor dezelfde data")
    func encoderIsStabiel() throws {
        struct Row: Codable {
            var schedule: [String: String]
            var date: Date
        }
        let row = Row(schedule: ["4": "Pull", "2": "Push", "6": "Legs", "1": "Rust", "3": "Rest"],
                      date: nlDate(2025, 6, 2))

        let first = try Sync.makeEncoder().encode(row)
        for _ in 0..<20 {
            let again = try Sync.makeEncoder().encode(row)
            #expect(again == first)
        }

        let json = try #require(String(data: first, encoding: .utf8))
        // Sleutels op volgorde, en de datum als ISO8601 — niet als kaal getal, want dat
        // zou Postgres niet als timestamptz slikken.
        let eerste = try #require(json.range(of: "\"1\""))
        let tweede = try #require(json.range(of: "\"2\""))
        #expect(eerste.lowerBound < tweede.lowerBound)
        #expect(json.contains("2025-06-02T"))
    }

    @Test("Hex-digest is SHA-256, niet Swift's per-proces geseede Hasher")
    func digestIsSHA256() {
        #expect(Sync.hexDigest(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Payload

    /// `sync_push` haalt de uid uit de sessie en negeert wat de client meestuurt, dus
    /// `user_id` in elke rij was dood gewicht — ~24% van de payload. De export liet dat
    /// zien als een placeholder-uuid die nergens op sloeg.
    @Test("Payload en export dragen geen user_id meer mee")
    @MainActor func payloadZonderUserID() throws {
        let context = try memoryContext()
        context.insert(Profile(name: "Jordi", age: 30, heightCm: 180, startWeight: 60,
                               goalWeight: 62.5, goalDate: nlDate(2026, 1, 1), trainingsPerWeek: 4))
        context.insert(WeightEntry(date: nlDate(2025, 6, 2), kg: 80))
        context.insert(SetEntry(date: nlDate(2025, 6, 2), exercise: "Squat", weightKg: 60, reps: 5))

        let json = try #require(Sync.exportJSON(context))
        #expect(!json.contains("user_id"))
        #expect(json.contains("\"exercise\""))
        #expect(json.contains("\"kg\""))
    }

    // MARK: - Gzip

    @Test("CRC32 volgt de standaard-testvector")
    func crc32Klopt() {
        #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    /// De gzip-omhulling zetten we met de hand om een raw-DEFLATE-blok van `Compression`.
    /// Eén byte verkeerd en de server weigert de push — vandaar dat de rondrit hier
    /// helemaal uitgepakt wordt.
    @Test("Gzip levert een geldige stream die weer uitpakt naar het origineel")
    func gzipRondrit() throws {
        let sample = #"{"date":"2025-06-02T12:00:00.000Z","exercise":"Bankdrukken","reps":8},"#
        let original = Data(String(repeating: sample, count: 500).utf8)
        let zipped = try #require(Gzip.compress(original))

        #expect(Array(zipped.prefix(3)) == [0x1f, 0x8b, 0x08]) // magic + deflate-methode
        #expect(zipped.count * 4 < original.count)             // dit is waar het om begonnen is

        let trailer = Array(zipped.suffix(8))
        #expect(littleEndian(trailer[0..<4]) == Gzip.crc32(original))
        #expect(littleEndian(trailer[4..<8]) == UInt32(original.count))

        let deflated = Data(zipped.dropFirst(10).dropLast(8))
        #expect(inflate(deflated, capacity: original.count) == original)
    }

    @Test("Lege data levert geen stream op")
    func gzipVanLeegIsNil() {
        #expect(Gzip.compress(Data()) == nil)
    }
}

// MARK: - Hulpjes

private func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    let b = Array(bytes)
    return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
}

/// Raw DEFLATE weer uitpakken — de tegenhanger van wat `Gzip` inpakt.
private func inflate(_ data: Data, capacity: Int) -> Data? {
    let room = capacity + 1024
    let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: room)
    defer { destination.deallocate() }
    let written = data.withUnsafeBytes { raw -> Int in
        guard let source = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return compression_decode_buffer(destination, room, source, data.count, nil, COMPRESSION_ZLIB)
    }
    return written > 0 ? Data(bytes: destination, count: written) : nil
}
