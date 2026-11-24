// mTALKIE — jeux Sierra SCI32 en version CD (Space Quest 6, King's Quest VII, Gabriel Knight…) : RESOURCE.AUD.
// RESOURCE.AUD : sons « SOL » mis bout à bout ([8D][taille d'en-tête][SOL\0][fréquence][drapeaux][taille], DPCM 16 bits).
// RESOURCE.MAP + RESOURCE.000 : ressources du jeu. Les « map » (une par salle) relient chaque réplique, notée
// salle/nom/verbe/condition/séquence, à sa position dans RESOURCE.AUD ; les « message » (compressés STACpack) donnent son texte.
import Foundation
import NaturalLanguage

enum Sierra {
    struct Clip: Sendable { var rate: Double; var flags: UInt8; var dataStart: Int; var dataSize: Int }

    static func le16(_ d: Data, _ p: Int) -> Int { Int(d[d.startIndex + p]) | Int(d[d.startIndex + p + 1]) << 8 }
    static func le24(_ d: Data, _ p: Int) -> Int { le16(d, p) | Int(d[d.startIndex + p + 2]) << 16 }
    static func le32(_ d: Data, _ p: Int) -> Int { le24(d, p) | Int(d[d.startIndex + p + 3]) << 24 }

    /// En-tête SOL à la position `p` (nil si absent).
    static func clip(_ d: Data, at p: Int) -> Clip? {
        guard p + 14 <= d.count, d[d.startIndex + p] == 0x8D,
              d[(d.startIndex + p + 2) ..< (d.startIndex + p + 6)].elementsEqual([0x53, 0x4F, 0x4C, 0x00]) else { return nil }
        let head = Int(d[d.startIndex + p + 1]) + 2
        let c = Clip(rate: Double(le16(d, p + 6)), flags: d[d.startIndex + p + 8], dataStart: p + head, dataSize: le32(d, p + 9))
        return c.dataStart + c.dataSize <= d.count ? c : nil
    }

    static func duration(_ c: Clip) -> Double {
        let bytesPerSample = (c.flags & 0x01 != 0) ? (c.flags & 0x04 != 0 ? 1 : 0.5) : (c.flags & 0x04 != 0 ? 2.0 : 1.0)
        let ch = c.flags & 0x10 != 0 ? 2.0 : 1.0
        return c.rate > 0 ? Double(c.dataSize) / bytesPerSample / ch / c.rate : 0
    }

    // MARK: Répliques

    /// Répliques de RESOURCE.AUD : d'après les « map » du jeu (noms salle_nom_verbe_condition_séquence), sinon en parcourant le fichier.
    static func parse(_ aud: Data, url: URL) throws -> [Line] {
        var lines: [Line] = []
        var seen = Set<Int>()
        func add(_ off: Int, _ name: String) {
            guard !seen.contains(off), let c = clip(aud, at: off) else { return }
            seen.insert(off)
            var l = Line(id: lines.count + 1, offset: lines.count, start: off, length: c.dataStart + c.dataSize - off,
                         rate: c.rate, duration: duration(c))
            l.name = name
            l.supported = c.flags & 0x01 == 0 || c.flags & 0x04 != 0
            lines.append(l)
        }
        if let res = Resources(dir: url.deletingLastPathComponent()) {
            for room in res.numbers(type: 0x10) where room != 0xFFFF {
                guard let m = res.load(type: 0x10, number: room) else { continue }
                for e in audioMap(m) { add(e.offset, "\(room)_\(e.noun)_\(e.verb)_\(e.cond)_\(e.seq)") }
            }
        }
        if lines.isEmpty {
            // Sans carte lisible : chaque en-tête SOL du fichier, dans l'ordre
            var p = 0
            while let c = clip(aud, at: p) { add(p, ""); p = c.dataStart + c.dataSize }
        }
        guard !lines.isEmpty else { throw FormatError.notSoundBank }
        return lines
    }

    struct MapEntry { var noun, verb, cond, seq: Int; var offset: Int }

    /// Carte audio d'une salle (SCI 1.1 tardif / SCI32) : position de départ, puis par réplique
    /// [nom, verbe, condition, séquence (drapeaux 0x80 et 0x40)][écart sur 3 octets][tailles de synchro labiale facultatives].
    static func audioMap(_ m: Data) -> [MapEntry] {
        guard m.count >= 11 else { return [] }
        var out: [MapEntry] = []
        var offset = le32(m, 0)
        var p = 4
        while p + 7 <= m.count {
            let b = m.startIndex + p
            let noun = Int(m[b]), verb = Int(m[b + 1]), cond = Int(m[b + 2]), seqRaw = Int(m[b + 3])
            if noun == 0xFF, verb == 0xFF, cond == 0xFF, seqRaw == 0xFF { break }
            offset += le24(m, p + 4)
            p += 7
            var sync = 0
            if seqRaw & 0x80 != 0, p + 2 <= m.count { sync = le16(m, p); p += 2 }
            if seqRaw & 0x40 != 0, p + 2 <= m.count { sync += le16(m, p); p += 2 }
            out.append(MapEntry(noun: noun, verb: verb, cond: cond, seq: seqRaw & 0x3F, offset: offset + sync))
        }
        return out
    }

    // MARK: Décodage

    static func decode(_ d: Data, line: Line) throws -> PCM {
        guard let c = clip(d, at: line.start) else { throw FormatError.notSoundBank }
        let ch = c.flags & 0x10 != 0 ? 2 : 1
        let raw = d[(d.startIndex + c.dataStart) ..< (d.startIndex + c.dataStart + c.dataSize)]
        switch (c.flags & 0x01 != 0, c.flags & 0x04 != 0) {
        case (true, true):
            var s = [Int](repeating: 0, count: ch)
            var out: [Float] = []
            out.reserveCapacity(raw.count)
            var k = 0
            for byte in raw {
                var v = s[k] + (byte & 0x80 != 0 ? -dpcm16[Int(byte & 0x7F)] : dpcm16[Int(byte)])
                if v > 32767 { v -= 65536 } else if v < -32768 { v += 65536 }    // débordement d'un registre 16 bits, comme l'original
                s[k] = v
                out.append(Float(v) / 32768)
                k = (k + 1) % ch
            }
            return PCM(rate: c.rate, channels: ch, samples: out, bits: 16)
        case (false, true):
            var out: [Float] = []
            out.reserveCapacity(raw.count / 2)
            var it = raw.makeIterator()
            while let lo = it.next(), let hi = it.next() { out.append(Float(Int16(bitPattern: UInt16(lo) | UInt16(hi) << 8)) / 32768) }
            return PCM(rate: c.rate, channels: ch, samples: out, bits: 16)
        case (false, false):
            return PCM(rate: c.rate, channels: ch, samples: raw.map { (Float($0) - 128) / 128 }, bits: 8)
        default:
            throw FormatError.unsupportedCodec
        }
    }

    private static let dpcm16: [Int] = [
        0x0000, 0x0008, 0x0010, 0x0020, 0x0030, 0x0040, 0x0050, 0x0060, 0x0070, 0x0080, 0x0090, 0x00A0, 0x00B0, 0x00C0, 0x00D0, 0x00E0,
        0x00F0, 0x0100, 0x0110, 0x0120, 0x0130, 0x0140, 0x0150, 0x0160, 0x0170, 0x0180, 0x0190, 0x01A0, 0x01B0, 0x01C0, 0x01D0, 0x01E0,
        0x01F0, 0x0200, 0x0208, 0x0210, 0x0218, 0x0220, 0x0228, 0x0230, 0x0238, 0x0240, 0x0248, 0x0250, 0x0258, 0x0260, 0x0268, 0x0270,
        0x0278, 0x0280, 0x0288, 0x0290, 0x0298, 0x02A0, 0x02A8, 0x02B0, 0x02B8, 0x02C0, 0x02C8, 0x02D0, 0x02D8, 0x02E0, 0x02E8, 0x02F0,
        0x02F8, 0x0300, 0x0308, 0x0310, 0x0318, 0x0320, 0x0328, 0x0330, 0x0338, 0x0340, 0x0348, 0x0350, 0x0358, 0x0360, 0x0368, 0x0370,
        0x0378, 0x0380, 0x0388, 0x0390, 0x0398, 0x03A0, 0x03A8, 0x03B0, 0x03B8, 0x03C0, 0x03C8, 0x03D0, 0x03D8, 0x03E0, 0x03E8, 0x03F0,
        0x03F8, 0x0400, 0x0440, 0x0480, 0x04C0, 0x0500, 0x0540, 0x0580, 0x05C0, 0x0600, 0x0640, 0x0680, 0x06C0, 0x0700, 0x0740, 0x0780,
        0x07C0, 0x0800, 0x0900, 0x0A00, 0x0B00, 0x0C00, 0x0D00, 0x0E00, 0x0F00, 0x1000, 0x1400, 0x1800, 0x1C00, 0x2000, 0x3000, 0x4000,
    ]

    // MARK: Textes (ressources « message »)

    /// Nom de réplique (salle_nom_verbe_condition_séquence) → texte, pour toutes les salles.
    static func texts(dir: URL) -> [String: String] {
        guard let res = Resources(dir: dir) else { return [:] }
        var out: [String: String] = [:]
        for room in res.numbers(type: 0x0F) {
            guard let m = res.load(type: 0x0F, number: room), m.count >= 10 else { continue }
            let version = le32(m, 0)
            let (head, rec, countAt) = version >= 4000 ? (10, 11, 8) : (6, 10, 4)
            let count = le16(m, countAt)
            for i in 0 ..< count {
                let r = head + i * rec
                guard r + rec <= m.count else { break }
                let b = m.startIndex + r
                let key = "\(room)_\(m[b])_\(m[b + 1])_\(m[b + 2])_\(m[b + 3])"
                let so = le16(m, r + 5)
                guard so < m.count, out[key] == nil else { continue }
                let bytes = m[(m.startIndex + so)...].prefix { $0 != 0 }
                if let s = String(data: Data(bytes), encoding: dos850) {
                    let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    if !t.isEmpty { out[key] = t }
                }
            }
        }
        return out
    }

    private static let dos850 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatin1.rawValue)))

    static func detect(_ t: [String: String]) -> String {
        let r = NLLanguageRecognizer()
        r.processString(t.values.prefix(400).joined(separator: " "))
        return r.dominantLanguage?.rawValue ?? "en"
    }

    /// Nom du jeu d'après la commande de lancement de RESOURCE.CFG (« cmd = SQ6DOSF »).
    static func gameName(dir: URL) -> String? {
        guard let cfg = try? String(contentsOf: dir.appendingPathComponent("RESOURCE.CFG"), encoding: .isoLatin1) else { return nil }
        let names = ["SQ6": "Space Quest 6", "KQ7": "King's Quest VII", "GK1": "Gabriel Knight", "GK2": "Gabriel Knight 2",
                     "PQ4": "Police Quest 4", "LSL6": "Leisure Suit Larry 6", "LSL7": "Leisure Suit Larry 7",
                     "PHANT": "Phantasmagoria", "TORIN": "Torin's Passage", "SHIVERS": "Shivers", "LIGHTH": "Lighthouse",
                     "QFG4": "Quest for Glory IV", "RAMA": "RAMA", "MOTHERGOOSE": "Mixed-Up Mother Goose"]
        for line in cfg.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].lowercased() == "cmd" else { continue }
            let cmd = parts[1].uppercased()
            return names.first { cmd.hasPrefix($0.key) }?.value
        }
        return nil
    }
}

/// Ressources SCI32 : RESOURCE.MAP (types, puis numéro et position sur 6 octets) et RESOURCE.000
/// (en-tête de 13 octets : type, numéro, taille compressée, taille, méthode — 0 aucune, 32 STACpack).
struct Resources {
    let map: Data
    let volume: Data
    private var table: [Int: [(Int, Int)]] = [:]

    init?(dir: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let m = items.first(where: { $0.lastPathComponent.uppercased() == "RESOURCE.MAP" }),
              let v = items.first(where: { $0.lastPathComponent.uppercased() == "RESOURCE.000" }),
              let md = try? Data(contentsOf: m), let vd = try? Data(contentsOf: v, options: .alwaysMapped) else { return nil }
        map = md; volume = vd
        var types: [(Int, Int)] = []
        var p = 0
        while p + 3 <= md.count {
            let t = Int(md[p]), off = Sierra.le16(md, p + 1)
            types.append((t, off)); p += 3
            if t == 0xFF { break }
        }
        guard types.count > 1, types.last?.0 == 0xFF else { return nil }
        for (a, b) in zip(types, types.dropFirst()) {
            guard (b.1 - a.1) % 6 == 0, b.1 <= md.count else { return nil }    // autre mise en page (SCI 1.1 : 5 octets)
            var list: [(Int, Int)] = []
            var q = a.1
            while q + 6 <= b.1 { list.append((Sierra.le16(md, q), Sierra.le32(md, q + 2))); q += 6 }
            table[a.0 & 0x7F] = list
        }
    }

    func numbers(type: Int) -> [Int] { (table[type] ?? []).map(\.0) }

    func load(type: Int, number: Int) -> Data? {
        guard let off = table[type]?.first(where: { $0.0 == number })?.1, off + 13 <= volume.count else { return nil }
        let packed = Sierra.le32(volume, off + 3), size = Sierra.le32(volume, off + 7), method = Sierra.le16(volume, off + 11)
        guard off + 13 + packed <= volume.count, size < 50_000_000 else { return nil }
        let src = volume.subdata(in: (volume.startIndex + off + 13) ..< (volume.startIndex + off + 13 + packed))
        switch method {
        case 0: return src
        case 32: return Data(Self.lzs([UInt8](src), size: size))
        default: return nil
        }
    }

    /// STACpack (LZS) : bits lus de poids fort à poids faible ; 0 = octet littéral, 1 = copie (distance sur 7 ou 11 bits, longueur codée).
    static func lzs(_ src: [UInt8], size: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(size)
        var p = 0, acc = 0, n = 0
        func bits(_ k: Int) -> Int {
            while n < k { acc = (acc << 8 | (p < src.count ? Int(src[p]) : 0)) & 0xFFFFFF; p += 1; n += 8 }
            n -= k
            return acc >> n & ((1 << k) - 1)
        }
        func length() -> Int {
            let a = bits(2); if a < 3 { return a + 2 }
            let b = bits(2); if b < 3 { return b + 5 }
            var c = 8
            while true { let x = bits(4); c += x; if x != 15 { return c } }
        }
        while out.count < size, p <= src.count {
            if bits(1) == 1 {
                let dist: Int
                if bits(1) == 1 { dist = bits(7); if dist == 0 { break } } else { dist = bits(11) }
                let len = length()
                guard dist > 0, dist <= out.count else { break }
                for _ in 0 ..< len { out.append(out[out.count - dist]) }
            } else {
                out.append(UInt8(bits(8)))
            }
        }
        return out
    }
}
