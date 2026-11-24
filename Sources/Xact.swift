// mTALKIE — éditions spéciales LucasArts (Monkey Island 1 et 2 SE) : banques de sons Microsoft XACT 3 (.xwb).
// Speech.xwb : sons en MS ADPCM (ou PCM). SpeechCues.xsb : nom de chaque réplique (« GUY_4_shore_11_1 »).
// speech.info : par réplique, texte en 5 langues (anglais, français, italien, allemand, espagnol) et nom.
import Foundation

enum Xact {
    /// Format d'un son de la banque (MINIWAVEFORMAT de XACT 3).
    struct Entry: Sendable {
        var tag: Int          // 0 PCM, 1 XMA, 2 MS ADPCM, 3 xWMA
        var channels: Int
        var rate: Double
        var align: Int        // octets par bloc
        var bits: Int         // PCM : 8 ou 16
        var samples: Int
        var supported: Bool { tag == 0 || tag == 2 }
    }

    static func u32(_ d: Data, _ p: Int) -> UInt32 {
        let s = d.startIndex + p
        return UInt32(d[s]) | UInt32(d[s + 1]) << 8 | UInt32(d[s + 2]) << 16 | UInt32(d[s + 3]) << 24
    }
    static func u16(_ d: Data, _ p: Int) -> UInt16 { let s = d.startIndex + p; return UInt16(d[s]) | UInt16(d[s + 1]) << 8 }

    /// Répliques de la banque : `offset` = numéro du son dans la banque (clé des noms et des textes).
    static func parse(_ d: Data) throws -> [(Line, Entry)] {
        guard d.count > 0x34, d.prefix(4).elementsEqual("WBND".utf8) else { throw FormatError.notSoundBank }
        let version = u32(d, 4)
        guard version >= 42 else { throw FormatError.unsupportedXwb }   // XACT 2 : autre mise en page
        let bankOff = Int(u32(d, 0x0C)), metaOff = Int(u32(d, 0x14)), waveOff = Int(u32(d, 0x2C))
        guard bankOff + 0x60 <= d.count else { throw FormatError.notSoundBank }
        let flags = u32(d, bankOff), count = Int(u32(d, bankOff + 4)), elem = Int(u32(d, bankOff + 0x48))
        guard flags & 0x0002_0000 == 0, elem >= 24, metaOff + count * elem <= d.count else { throw FormatError.unsupportedXwb }
        var out: [(Line, Entry)] = []
        out.reserveCapacity(count)
        for i in 0 ..< count {
            let e = metaOff + i * elem
            let fd = u32(d, e), fm = u32(d, e + 4)
            let off = Int(u32(d, e + 8)), len = Int(u32(d, e + 12))
            let tag = Int(fm & 3), ch = Int(fm >> 2 & 7), rate = Double(fm >> 5 & 0x3FFFF), ba = Int(fm >> 23 & 0xFF)
            let align = tag == 2 ? (ba + 22) * max(1, ch) : ba
            let entry = Entry(tag: tag, channels: max(1, ch), rate: rate, align: align, bits: fm >> 31 == 1 ? 16 : 8, samples: Int(fd >> 4))
            let start = waveOff + off
            guard start + len <= d.count else { throw FormatError.notSoundBank }
            var line = Line(id: i + 1, offset: i, start: start, length: len, rate: rate,
                            duration: rate > 0 ? Double(entry.samples) / rate : 0)
            line.supported = entry.supported
            out.append((line, entry))
        }
        return out
    }

    // MARK: Décodage

    static func decode(_ d: Data, line: Line, entry e: Entry) throws -> PCM {
        let bytes = d.subdata(in: d.startIndex + line.start ..< d.startIndex + line.start + line.length)
        switch e.tag {
        case 0:
            var s: [Float] = []
            if e.bits == 16 {
                s.reserveCapacity(bytes.count / 2)
                bytes.withUnsafeBytes { r in for i in stride(from: 0, to: r.count - 1, by: 2) { s.append(Float(Int16(bitPattern: UInt16(r[i]) | UInt16(r[i + 1]) << 8)) / 32768) } }
            } else {
                s = bytes.map { (Float($0) - 128) / 128 }
            }
            return PCM(rate: e.rate, channels: e.channels, samples: s, bits: e.bits)
        case 2:
            return PCM(rate: e.rate, channels: e.channels, samples: msadpcm(bytes, channels: e.channels, align: e.align, samples: e.samples), bits: 16)
        default:
            throw FormatError.unsupportedCodec
        }
    }

    private static let coef1: [Int] = [256, 512, 0, 192, 240, 460, 392]
    private static let coef2: [Int] = [0, -256, 0, 64, 0, -208, -232]
    private static let adapt: [Int] = [230, 230, 230, 230, 307, 409, 512, 614, 768, 614, 512, 409, 307, 230, 230, 230]

    /// Microsoft ADPCM : par bloc et par voie, prédicteur, delta, deux échantillons de départ, puis un quartet par échantillon.
    static func msadpcm(_ data: Data, channels ch: Int, align: Int, samples total: Int) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(total * ch)
        let b = [UInt8](data)
        guard align > 7 * ch else { return [] }
        var p = 0
        func s16(_ i: Int) -> Int { Int(Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8)) }
        while p + 7 * ch <= b.count, out.count < total * ch {
            let end = min(b.count, p + align)
            var c1 = [Int](repeating: 0, count: ch), c2 = c1, delta = c1, s1 = c1, s2 = c1
            for c in 0 ..< ch { let k = min(6, Int(b[p + c])); c1[c] = coef1[k]; c2[c] = coef2[k] }
            var q = p + ch
            for c in 0 ..< ch { delta[c] = s16(q); q += 2 }
            for c in 0 ..< ch { s1[c] = s16(q); q += 2 }
            for c in 0 ..< ch { s2[c] = s16(q); q += 2 }
            for c in 0 ..< ch { out.append(Float(s2[c]) / 32768) }
            for c in 0 ..< ch { out.append(Float(s1[c]) / 32768) }
            var c = 0
            func step(_ n: Int) {
                let signed = n >= 8 ? n - 16 : n
                var v = (s1[c] * c1[c] + s2[c] * c2[c]) / 256      // division entière (vers zéro), comme la référence Microsoft
                v = max(-32768, min(32767, v + signed * delta[c]))
                s2[c] = s1[c]; s1[c] = v
                delta[c] = max(16, (adapt[n] * delta[c]) >> 8)   // en Swift, >> passe avant *
                out.append(Float(v) / 32768)
                c = (c + 1) % ch
            }
            while q < end { step(Int(b[q] >> 4)); step(Int(b[q] & 0x0F)); q += 1 }
            p += align
        }
        if out.count > total * ch { out.removeLast(out.count - total * ch) }
        return out
    }

    // MARK: Noms des répliques (.xsb)

    /// Fichier de repères de la banque : « SpeechCues.xsb » ou « Speech.xsb ».
    static func cueFile(for bank: URL) -> URL? {
        let stem = bank.deletingPathExtension().lastPathComponent.uppercased()
        let items = (try? FileManager.default.contentsOfDirectory(at: bank.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension.uppercased() == "XSB" && [stem + "CUES", stem].contains($0.deletingPathExtension().lastPathComponent.uppercased()) }
    }

    /// Numéro du son → nom du repère. Seuls les repères simples (un son chacun) sont lus, comme dans les éditions spéciales.
    static func cueNames(_ url: URL) -> [Int: String] {
        guard let d = try? Data(contentsOf: url), d.count > 0x8A, d.prefix(4).elementsEqual("SDBK".utf8) else { return [:] }
        var o = 4 + 2 + 2 + 2 + 8 + 1
        let simple = Int(u16(d, o)); o += 8
        o += 1 + 6
        let simpleOff = Int(u32(d, o)), namesOff = Int(u32(d, o + 8))
        guard simpleOff > 0, simpleOff != 0xFFFF_FFFF, namesOff < d.count, simpleOff + simple * 5 <= d.count else { return [:] }
        let names = d[(d.startIndex + namesOff)...].split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var out: [Int: String] = [:]
        for i in 0 ..< min(simple, names.count) {
            let so = Int(u32(d, simpleOff + i * 5 + 1))
            guard so + 11 <= d.count, d[d.startIndex + so] & 1 == 0 else { continue }
            out[Int(u16(d, so + 9))] = names[i]
        }
        return out
    }

    // MARK: Textes (speech.info)

    static let infoLanguages = ["en", "fr", "it", "de", "es"]
    private static let record = 0x530

    static func infoFile(for bank: URL) -> URL? {
        let stem = bank.deletingPathExtension().lastPathComponent.uppercased()
        let items = (try? FileManager.default.contentsOfDirectory(at: bank.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        return items.first { $0.pathExtension.uppercased() == "INFO" && $0.deletingPathExtension().lastPathComponent.uppercased() == stem }
    }

    /// Nom de réplique → textes dans les 5 langues (ordre de `infoLanguages`).
    static func infoTexts(_ url: URL) -> [String: [String]] {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped), d.count >= record, d.count % record == 0 else { return [:] }
        var out: [String: [String]] = [:]
        func str(_ a: Int, _ n: Int) -> String {
            let s = d.startIndex + a
            let raw = d[s ..< s + n].prefix { $0 != 0 }
            return (String(data: Data(raw), encoding: .windowsCP1252) ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        for r in 0 ..< d.count / record {
            let base = r * record
            let name = str(base + 0x510, 32)
            guard !name.isEmpty, out[name] == nil else { continue }
            out[name] = (0 ..< 5).map { str(base + 0x10 + $0 * 0x100, 0x100) }
        }
        return out
    }

    /// Textes d'une langue pour les répliques nommées (numéro du son → texte). Les variantes « _1a », « _1b » partagent leur texte.
    static func texts(names: [Int: String], info: [String: [String]], language: String) -> [Int: String] {
        guard let li = infoLanguages.firstIndex(of: language) else { return [:] }
        var out: [Int: String] = [:]
        for (i, n) in names {
            // Quelques répliques (prix, variantes) n'existent qu'en anglais : texte anglais à défaut.
            if let all = info[n] ?? info[n + "a"], let t = [all[li], all[0]].first(where: { !$0.isEmpty }) { out[i] = t }
        }
        return out
    }
}
