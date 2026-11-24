// mTALKIE — Escape from Monkey Island (moteur GrimE) : archives .M4B (« LABN ») de voix .wVC.
// Archive : [LABN][version][nombre][taille de la table des noms][position de la table + 0x13D0F], entrées de 16 octets
// (position du nom, position, taille, réservé) ; noms chiffrés par XOR 0x96.
// Voix .wVC : [MCMP][nombre de blocs BE16][par bloc : codec, taille décompressée BE32, taille compressée BE32]
// [taille des noms de codecs BE16][« NULL\0VIMA\0 »][en-tête WAV de 44 octets][blocs VIMA de 8 Ko décompressés].
// Textes : script.tab (archive artAll.m4b), chiffré « RCNE », lignes « clatri001<tab>Whoaaaaaa! ».
import Foundation
import NaturalLanguage

enum Grime {
    static func le32(_ d: Data, _ p: Int) -> Int {
        let s = d.startIndex + p
        return Int(d[s]) | Int(d[s + 1]) << 8 | Int(d[s + 2]) << 16 | Int(d[s + 3]) << 24
    }
    static func be32(_ d: Data, _ p: Int) -> Int {
        let s = d.startIndex + p
        return Int(d[s]) << 24 | Int(d[s + 1]) << 16 | Int(d[s + 2]) << 8 | Int(d[s + 3])
    }
    static func be16(_ d: Data, _ p: Int) -> Int { let s = d.startIndex + p; return Int(d[s]) << 8 | Int(d[s + 1]) }

    struct Entry { var name: String; var start: Int; var size: Int }

    /// Fichiers de l'archive LABN.
    static func entries(_ d: Data) throws -> [Entry] {
        guard d.count > 0x14, d.prefix(4).elementsEqual("LABN".utf8) else { throw FormatError.notSoundBank }
        let count = le32(d, 8), nameSize = le32(d, 12), nameOff = le32(d, 16) - 0x13D0F
        guard count > 0, 0x14 + count * 16 <= d.count, nameOff >= 0, nameOff + nameSize <= d.count else { throw FormatError.notSoundBank }
        let names = [UInt8](d[(d.startIndex + nameOff) ..< (d.startIndex + nameOff + nameSize)])
        var out: [Entry] = []
        out.reserveCapacity(count)
        for i in 0 ..< count {
            let e = 0x14 + i * 16
            let no = le32(d, e), start = le32(d, e + 4), size = le32(d, e + 8)
            guard no < names.count, start + size <= d.count else { throw FormatError.notSoundBank }
            let end = names[no...].firstIndex(of: 0) ?? names.count
            let name = String(decoding: names[no ..< end].map { $0 ^ 0x96 }, as: UTF8.self)
            out.append(Entry(name: name, start: start, size: size))
        }
        return out
    }

    /// Répliques de l'archive (fichiers .wVC) : `name` = nom sans extension (« clatri001 »), durée lue dans l'en-tête.
    static func parse(_ d: Data) throws -> [Line] {
        var out: [Line] = []
        for e in try entries(d) where e.name.lowercased().hasSuffix(".wvc") {
            var line = Line(id: out.count + 1, offset: out.count, start: e.start, length: e.size, rate: 0, duration: 0)
            line.name = String(e.name.dropLast(4))
            if let h = try? header(d, start: e.start, length: e.size) {
                line.rate = h.rate
                line.duration = h.rate > 0 ? Double(h.total / (2 * h.channels)) / h.rate : 0
            } else { line.supported = false }
            out.append(line)
        }
        return out
    }

    struct Block { var codec: Int; var decomp: Int; var comp: Int; var offset: Int }
    struct Header { var rate: Double; var channels: Int; var bits: Int; var blocks: [Block]; var total: Int }

    static func header(_ d: Data, start: Int, length: Int) throws -> Header {
        guard length > 16, d[(d.startIndex + start) ..< (d.startIndex + start + 4)].elementsEqual("MCMP".utf8) else { throw FormatError.unsupportedCodec }
        let n = be16(d, start + 4)
        guard n > 0, start + 6 + n * 9 + 2 <= start + length else { throw FormatError.unsupportedCodec }
        let headerSize = be32(d, start + 6 + 5)
        let codecsSize = be16(d, start + 6 + n * 9)
        let wav = start + 6 + n * 9 + 2 + codecsSize
        guard headerSize >= 36, wav + headerSize <= start + length,
              d[(d.startIndex + wav) ..< (d.startIndex + wav + 4)].elementsEqual("RIFF".utf8) else { throw FormatError.unsupportedCodec }
        let s = d.startIndex + wav
        let channels = max(1, Int(d[s + 22]) | Int(d[s + 23]) << 8)
        let rate = Double(le32(d, wav + 24))
        let bits = Int(d[s + 34]) | Int(d[s + 35]) << 8
        var blocks: [Block] = []
        var off = wav + headerSize, total = 0
        for i in 1 ..< n {
            let p = start + 6 + i * 9
            let b = Block(codec: Int(d[d.startIndex + p]), decomp: be32(d, p + 1), comp: be32(d, p + 5), offset: off)
            guard off + b.comp <= start + length, b.decomp <= 0x2000 else { throw FormatError.unsupportedCodec }
            blocks.append(b); off += b.comp; total += b.decomp
        }
        return Header(rate: rate, channels: channels, bits: bits, blocks: blocks, total: total)
    }

    static func decode(_ d: Data, line: Line) throws -> PCM {
        let h = try header(d, start: line.start, length: line.length)
        guard h.bits == 16 else { throw FormatError.unsupportedCodec }
        var out: [Float] = []
        out.reserveCapacity(h.total / 2)
        for b in h.blocks {
            let src = [UInt8](d[(d.startIndex + b.offset) ..< (d.startIndex + b.offset + b.comp)])
            if b.codec == 0 {
                for i in stride(from: 0, to: src.count - 1, by: 2) { out.append(Float(Int16(bitPattern: UInt16(src[i]) | UInt16(src[i + 1]) << 8)) / 32768) }
            } else {
                out.append(contentsOf: vima(src, outBytes: b.decomp).map { Float($0) / 32768 })
            }
        }
        return PCM(rate: h.rate, channels: h.channels, samples: out, bits: 16)
    }

    // MARK: VIMA (ADPCM à pas variable de LucasArts, d'après ScummVM engines/grim/movie/codecs/vima.cpp)

    private static let step: [Int] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
        337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
        15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]

    private static let sizes: [Int] = [
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
        6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7]

    private static let offsets: [[Int]] = {
        let m = -1
        let t4h = [m, m, m, m, m, m, m, m, 1, 1, 1, 2, 2, 4, 5, 6]
        let t5h = [m, m, m, m, m, m, m, m, m, m, m, m, m, m, m, m, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 5, 5, 6, 6]
        let t6h = [Int](repeating: m, count: 32) + [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 6, 6]
        return [[m, 4, m, 4], [m, m, 2, 6, m, m, 2, 6], [m, m, m, m, 1, 2, 4, 6, m, m, m, m, 1, 2, 4, 6], t4h + t4h, t5h + t5h, t6h + t6h]
    }()

    /// destTable[n + pos * 64] : somme des fractions du pas désignées par les 6 bits de n.
    private static let table: [Int] = {
        var t = [Int](repeating: 0, count: 64 * 89)
        for n in 0 ..< 64 {
            for pos in 0 ..< 89 {
                var put = 0, count = 32, v = step[pos]
                while count != 0 { if n & count != 0 { put += v }; count >>= 1; v >>= 1 }
                t[n + pos * 64] = put
            }
        }
        return t
    }()

    static func vima(_ src: [UInt8], outBytes: Int) -> [Int16] {
        var p = 0
        func byte() -> Int { defer { p += 1 }; return p < src.count ? Int(src[p]) : 0 }
        var channels = 1
        var tablePos = [byte(), 0], word = [0, 0]
        if tablePos[0] & 0x80 != 0 { tablePos[0] = ~tablePos[0] & 0xFF; channels = 2 }
        word[0] = Int(Int16(bitPattern: UInt16(byte() << 8 | byte())))
        if channels > 1 { tablePos[1] = byte(); word[1] = Int(Int16(bitPattern: UInt16(byte() << 8 | byte()))) }
        let frames = outBytes / (channels * 2)
        var out = [Int16](repeating: 0, count: frames * channels)
        guard frames > 0 else { return out }
        var bits = byte() << 8 | byte(), bitPtr = 0
        for c in 0 ..< channels {
            var pos = min(88, tablePos[c]), value = word[c]
            for f in 0 ..< frames {
                let numBits = sizes[pos]
                bitPtr += numBits
                var highBit = 1 << (numBits - 1)
                let lowBits = highBit - 1
                var val = (bits >> (16 - bitPtr)) & (highBit | lowBits)
                if bitPtr > 7 { bits = ((bits & 0xFF) << 8) | byte(); bitPtr -= 8 }
                if val & highBit != 0 { val ^= highBit } else { highBit = 0 }
                if val == lowBits {
                    // valeur brute sur 16 bits
                    var w = Int(Int16(truncatingIfNeeded: bits << bitPtr)) & ~0xFF
                    bits = ((bits & 0xFF) << 8) | byte()
                    w |= (bits >> (8 - bitPtr)) & 0xFF
                    bits = ((bits & 0xFF) << 8) | byte()
                    value = Int(Int16(truncatingIfNeeded: w))
                } else {
                    var delta = table[(val << (7 - numBits)) | (pos << 6)]
                    if val != 0 { delta += step[pos] >> (numBits - 1) }
                    if highBit != 0 { delta = -delta }
                    value = max(-0x8000, min(0x7FFF, value + delta))
                }
                out[f * channels + c] = Int16(value)
                pos = max(0, min(88, pos + offsets[numBits - 2][val]))
            }
        }
        return out
    }

    // MARK: Textes (script.tab)

    /// Nom de réplique (minuscules) → texte, lus dans le script.tab d'une archive voisine (artAll.m4b).
    static func texts(dir: URL) -> [String: String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let archives = items.filter { $0.pathExtension.lowercased() == "m4b" }
            .sorted { a, _ in a.lastPathComponent.lowercased().hasPrefix("art") }
        for a in archives {
            guard let d = try? Data(contentsOf: a, options: .alwaysMapped), let list = try? entries(d),
                  let e = list.first(where: { $0.name.lowercased() == "script.tab" }) else { continue }
            var b = [UInt8](d[(d.startIndex + e.start) ..< (d.startIndex + e.start + e.size)])
            guard b.count > 4 else { continue }
            if b.prefix(4).elementsEqual("RCNE".utf8) {
                var next: UInt32 = 0x16
                for i in 4 ..< b.count {
                    next = next &* 0x343FD &+ 0x269EC3
                    b[i] ^= UInt8(truncatingIfNeeded: Int(Float((next >> 16) & 0x7FFF) / 32767 * 254) + 1)
                }
            }
            let s = String(data: Data(b[4...]), encoding: .windowsCP1252) ?? ""
            var out: [String: String] = [:]
            for raw in s.split(whereSeparator: \.isNewline) {  // « \r\n » est un seul caractère en Swift
                guard let tab = raw.firstIndex(of: "\t") else { continue }
                let key = raw[..<tab].trimmingCharacters(in: .whitespaces).lowercased()
                let text = raw[raw.index(after: tab)...].split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !key.isEmpty, !text.isEmpty, out[key] == nil { out[key] = text }
            }
            if !out.isEmpty { return out }
        }
        return [:]
    }

    static func detect(_ texts: [String: String]) -> String {
        let r = NLLanguageRecognizer()
        r.processString(texts.values.prefix(400).joined(separator: " "))
        return r.dominantLanguage?.rawValue ?? "en"
    }

    /// Escape from Monkey Island : archives voiceAll.m4b / artAll.m4b dans le dossier.
    static func isGame(names: Set<String>) -> Bool { names.contains("VOICEALL.M4B") || names.contains("ARTALL.M4B") }
}
