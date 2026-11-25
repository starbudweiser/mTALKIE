// mTALKIE — jeux LucasArts à iMUSE numérique (The Dig, The Curse of Monkey Island) : archives .BUN.
// Archive « LB83 » : [LB83][position du répertoire BE32][nombre BE32], répertoire de 20 octets par fichier (nom sur 12, position, taille).
// Chaque fichier : [COMP][nombre de blocs BE32][8 octets][par bloc : position, taille, codec, 4 octets], blocs de 8 Ko décompressés.
// Codecs 0 (copie), 1 (LZ LucasArts), 2 et 3 (LZ puis une ou deux intégrations), 13 et 15 (ADPCM IMA à taille variable,
// mono ou stéréo : voix de Curse of Monkey Island, fichiers « B2GT301.IMX »). Le résultat est un fichier iMUS :
// [iMUS][MAP : FRMT (bits, fréquence, voies), TEXT, REGN, STOP…][DATA : échantillons 8 bits non signés, 12 bits groupés ou 16 bits BE].
import Foundation
import NaturalLanguage

enum BunArchive {
    static func be32(_ d: Data, _ p: Int) -> Int {
        let s = d.startIndex + p
        return Int(d[s]) << 24 | Int(d[s + 1]) << 16 | Int(d[s + 2]) << 8 | Int(d[s + 3])
    }

    /// Fichiers de l'archive : `offset` = rang dans l'archive, `name` = nom du fichier (« LIFEDIAL001 »).
    static func parse(_ d: Data) throws -> [Line] {
        guard d.count > 16, d.prefix(4).elementsEqual("LB83".utf8) else { throw FormatError.notSoundBank }
        let dir = be32(d, 4), count = be32(d, 8)
        guard count > 0, dir + count * 20 <= d.count else { throw FormatError.notSoundBank }
        var out: [Line] = []
        out.reserveCapacity(count)
        for i in 0 ..< count {
            let e = dir + i * 20
            // nom sur 8 octets puis extension sur 4 (« AST2\0\0\0\0 » + « 001\0 ») : on garde « AST2001 »
            let base = d[(d.startIndex + e) ..< (d.startIndex + e + 8)].prefix { $0 != 0 }
            let ext = d[(d.startIndex + e + 8) ..< (d.startIndex + e + 12)].prefix { $0 != 0 }
            let off = be32(d, e + 12), size = be32(d, e + 16)
            guard off + size <= d.count else { throw FormatError.notSoundBank }
            var line = Line(id: i + 1, offset: i, start: off, length: size, rate: 0, duration: 0)
            let e3 = String(decoding: ext, as: UTF8.self)
            line.name = String(decoding: base, as: UTF8.self) + (e3.uppercased() == "IMX" ? "" : e3)   // COMI : « B2GT301.IMX » → B2GT301
            out.append(line)
        }
        return out
    }

    // MARK: Décodage

    static func decode(_ d: Data, line: Line) throws -> PCM {
        let file = try decompress(d, start: line.start, length: line.length)
        return try imus(file)
    }

    /// Décompresse tous les blocs d'un fichier de l'archive.
    static func decompress(_ d: Data, start: Int, length: Int) throws -> [UInt8] {
        guard length >= 16, d[(d.startIndex + start) ..< (d.startIndex + start + 4)].elementsEqual("COMP".utf8) else { throw FormatError.notSoundBank }
        let n = be32(d, start + 4)
        guard n > 0, 16 + n * 16 <= length else { throw FormatError.notSoundBank }
        var out: [UInt8] = []
        out.reserveCapacity(n * 0x2000)
        for k in 0 ..< n {
            let e = start + 16 + k * 16
            let off = be32(d, e), size = be32(d, e + 4), codec = be32(d, e + 8)
            guard off + size <= length else { throw FormatError.notSoundBank }
            let src = [UInt8](d[(d.startIndex + start + off) ..< (d.startIndex + start + off + size)])
            var block: [UInt8]
            switch codec {
            case 0: block = src
            case 1, 2, 3:
                block = lzDecode(src)
                if codec == 2 { integrate(&block, from: 1) }
                if codec == 3 { integrate(&block, from: 2); integrate(&block, from: 1) }   // première passe dès le 3ᵉ octet
            case 13, 15: block = imaDecode(src, channels: codec == 13 ? 1 : 2, outputSize: 0x2000)
            default: throw FormatError.unsupportedCodec     // codecs 4 à 12 (musiques)
            }
            out += block
        }
        return out
    }

    // MARK: Codecs 13 / 15 (ADPCM IMA à taille variable)

    static let imcTable: [Int32] = [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
        107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166,
        1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493,
        10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767]

    /// Ajustement de l'index de pas, par nombre de bits du paquet (2 à 7) et valeur des bits de données.
    static let imxOther: [[Int]] = [
        [-1, 4],
        [-1, -1, 2, 8],
        [-1, -1, -1, -1, 1, 2, 4, 6],
        [-1, -1, -1, -1, -1, -1, -1, -1, 1, 2, 4, 6, 8, 12, 16, 32],
        Array(repeating: -1, count: 16) + [1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 32],
        Array(repeating: -1, count: 32) + Array(1 ... 32)]

    /// Nombre de bits par paquet selon l'index de pas, et deltas précalculés (64 valeurs de données par index).
    static let imcBits: [Int] = imcTable.map { v in
        var put = 1, t = ((Int(v) * 4) / 7) / 2
        while t != 0 { t /= 2; put += 1 }
        return min(8, max(3, put)) - 1
    }
    static let imcDelta: [Int32] = {
        var out = [Int32](repeating: 0, count: 89 * 64)
        for n in 0 ..< 64 {
            for pos in 0 ..< 89 {
                var count = 32, put: Int32 = 0, v = imcTable[pos]
                repeat { if count & n != 0 { put += v }; count /= 2; v /= 2 } while count != 0
                out[n + pos * 64] = put
            }
        }
        return out
    }()

    /// Un bloc : 2 octets BE = taille d'un en-tête copié tel quel (0 : état initial de chaque voie, 9 octets), puis les paquets
    /// de chaque voie à la suite, sur un nombre de bits qui suit l'index de pas. Sortie en 16 bits BE entrelacés.
    static func imaDecode(_ src: [UInt8], channels: Int, outputSize: Int) -> [UInt8] {
        guard src.count >= 2 else { return [] }
        var dst = [UInt8](repeating: 0, count: outputSize)
        var p = 2, d = 0, size = outputSize
        var tablePos = [Int](repeating: 0, count: channels), word = [Int32](repeating: 0, count: channels)
        let first = Int(src[0]) << 8 | Int(src[1])
        if first != 0 {
            let n = min(first, src.count - 2, size)
            for i in 0 ..< n { dst[i] = src[2 + i] }
            p += n; d = n; size -= n
        } else {
            for c in 0 ..< channels where p + 9 <= src.count {
                tablePos[c] = Int(src[p])
                word[c] = Int32(bitPattern: UInt32(src[p + 5]) << 24 | UInt32(src[p + 6]) << 16 | UInt32(src[p + 7]) << 8 | UInt32(src[p + 8]))
                p += 9
            }
        }
        var bitOffset = 0
        for c in 0 ..< channels {
            var pos = min(88, tablePos[c]), out = word[c]
            var dpos = d + c * 2
            var left = channels == 1 ? (size + 1) / 2 : size / 4
            while left > 0 {
                left -= 1
                let bits = imcBits[pos]
                let r = p + (bitOffset >> 3)
                let hi = r < src.count ? Int(src[r]) : 0, lo = r + 1 < src.count ? Int(src[r + 1]) : 0
                let readWord = ((hi << 8 | lo) << (bitOffset & 7)) & 0xFFFF
                let packet = readWord >> (16 - bits)
                bitOffset += bits
                let sign = 1 << (bits - 1), data = packet & (sign - 1)
                var delta = (imcTable[pos] >> Int32(bits - 1)) + imcDelta[(data << (7 - bits)) + pos * 64]
                if packet & sign != 0 { delta = -delta }
                out = min(32767, max(-32768, out + delta))
                if dpos + 1 < dst.count { dst[dpos] = UInt8(truncatingIfNeeded: out >> 8); dst[dpos + 1] = UInt8(truncatingIfNeeded: out) }
                dpos += channels * 2
                pos = min(88, max(0, pos + imxOther[bits - 2][data]))
            }
        }
        return dst
    }

    private static func integrate(_ b: inout [UInt8], from start: Int) {
        guard b.count > start else { return }
        for i in start ..< b.count { b[i] = b[i] &+ b[i - 1] }
    }

    /// Décompresseur LZ des jeux LucasArts : un bit par élément (lu dans des mots de 16 bits) — 1 : octet copié tel quel ;
    /// 0 puis 0 : copie courte (2 bits de longueur, distance sur 8 bits) ; 0 puis 1 : copie longue (distance sur 12 bits).
    static func lzDecode(_ src: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(0x2000)
        guard src.count >= 2 else { return out }
        var p = 2
        var mask = Int(src[0]) | Int(src[1]) << 8
        var left = 16
        func bit() -> Int {
            let b = mask & 1
            mask >>= 1; left -= 1
            if left == 0 {
                mask = p + 1 < src.count ? Int(src[p]) | Int(src[p + 1]) << 8 : 0
                p += 2; left = 16
            }
            return b
        }
        while p < src.count {
            if bit() == 1 {
                out.append(src[p]); p += 1
                continue
            }
            var size: Int, dist: Int
            if bit() == 0 {
                size = bit() << 1
                size = (size | bit()) + 3
                guard p < src.count else { break }
                dist = Int(src[p]) - 256; p += 1
            } else {
                guard p + 1 < src.count else { break }
                let lo = Int(src[p]), hi = Int(src[p + 1]); p += 2
                dist = (lo | (hi & 0xF0) << 4) - 4096
                size = (hi & 0x0F) + 3
                if size == 3 {
                    guard p < src.count else { break }
                    let x = src[p]; p += 1
                    if x == 0 { break }      // fin du bloc
                }
            }
            var r = out.count + dist
            guard r >= 0 else { break }
            for _ in 0 ..< size { out.append(out[r]); r += 1 }
        }
        return out
    }

    /// Fichier iMUS : format dans MAP/FRMT, échantillons dans DATA.
    static func imus(_ f: [UInt8]) throws -> PCM {
        func be(_ p: Int) -> Int { Int(f[p]) << 24 | Int(f[p + 1]) << 16 | Int(f[p + 2]) << 8 | Int(f[p + 3]) }
        func tag(_ p: Int) -> String { String(decoding: f[p ..< p + 4], as: UTF8.self) }
        guard f.count > 16, tag(0) == "iMUS" else { throw FormatError.notSoundBank }
        var bits = 8, rate = 22050, ch = 1
        var p = 8
        while p + 8 <= f.count {
            let t = tag(p), size = be(p + 4)
            if t == "MAP " {
                var q = p + 8
                while q + 8 <= min(f.count, p + 8 + size) {
                    let st = tag(q), ss = be(q + 4)
                    if st == "FRMT", q + 8 + 20 <= f.count { bits = be(q + 16); rate = be(q + 20); ch = max(1, be(q + 24)) }
                    q += 8 + ss
                }
            } else if t == "DATA" {
                let end = min(f.count, p + 8 + size)
                let raw = Array(f[(p + 8) ..< end])
                return PCM(rate: Double(rate), channels: ch, samples: samples(raw, bits: bits), bits: bits == 8 ? 8 : 16)
            }
            p += 8 + size
        }
        throw FormatError.notSoundBank
    }

    static func samples(_ raw: [UInt8], bits: Int) -> [Float] {
        switch bits {
        case 8:
            return raw.map { (Float($0) - 128) / 128 }
        case 12:
            // 3 octets pour 2 échantillons de 12 bits
            var s: [Float] = []
            s.reserveCapacity(raw.count / 3 * 2)
            var i = 0
            while i + 2 < raw.count {
                let v1 = Int(raw[i]), v2 = Int(raw[i + 1]), v3 = Int(raw[i + 2])
                s.append(Float(((((v2 & 0x0F) << 8) | v1) << 4) - 0x8000) / 32768)
                s.append(Float(((((v2 & 0xF0) << 4) | v3) << 4) - 0x8000) / 32768)
                i += 3
            }
            return s
        default:
            var s: [Float] = []
            s.reserveCapacity(raw.count / 2)
            var i = 0
            while i + 1 < raw.count { s.append(Float(Int16(bitPattern: UInt16(raw[i]) << 8 | UInt16(raw[i + 1]))) / 32768); i += 2 }
            return s
        }
    }

    // MARK: Textes

    /// Textes de la version d'origine, dans les scripts du jeu : « /LIFEDIAL.001/Do you think… » → LIFEDIAL001.
    static func scriptTexts(_ url: URL) -> [String: String] {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return [:] }
        var out: [String: String] = [:]
        d.withUnsafeBytes { (r: UnsafeRawBufferPointer) in
            let p = r.bindMemory(to: UInt8.self)
            let n = p.count
            func isKey(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2D }
            var i = 0
            while i < n - 8 {
                guard p[i] == 0x2F, isKey(p[i + 1]) else { i += 1; continue }
                var j = i + 1
                while j < n, isKey(p[j]) { j += 1 }
                guard j < n - 5 else { i += 1; continue }
                var k = j
                if p[j] == 0x2E {                                   // The Dig : « /LIFEDIAL.001/ »
                    k = j + 1
                    while k < n, p[k] >= 0x30, p[k] <= 0x39 { k += 1 }
                    guard k < n, p[k] == 0x2F, k - j - 1 >= 1, k - j - 1 <= 4 else { i += 1; continue }
                } else {                                            // COMI : « /B2GT301/ »
                    guard p[j] == 0x2F, j - i - 1 >= 4, j - i - 1 <= 8, p[(i + 1) ..< j].contains(where: { $0 >= 0x30 && $0 <= 0x39 }) else { i += 1; continue }
                }
                var e = k + 1
                var bytes: [UInt8] = []
                while e < n, p[e] != 0, bytes.count < 600 {
                    if p[e] == 0xFF, e + 1 < n { e += p[e + 1] == 0x0A ? 16 : 4; continue }   // codes de contrôle SCUMM
                    bytes.append(p[e] < 0x20 ? 0x20 : p[e]); e += 1
                }
                let key = String(decoding: p[(i + 1) ..< j], as: UTF8.self) + (k > j ? String(decoding: p[(j + 1) ..< k], as: UTF8.self) : "")
                if out[key] == nil, let t = clean(bytes, encoding: dos437), !t.isEmpty { out[key] = t }
                i = e
            }
        }
        return out
    }

    /// Traduction (LANGUAGE.BND) : sections « @AIRLOCK » puis lignes « 3/texte » chiffrées par XOR 0x13 → AIRLOCK003.
    static func languageTexts(_ url: URL) -> [String: String] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        var out: [String: String] = [:]
        var section = ""
        for raw in d.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) {
            let l = Array(raw)
            if l.first == 0x40 { section = String(decoding: l.dropFirst(), as: UTF8.self).trimmingCharacters(in: .whitespaces).uppercased(); continue }
            guard !section.isEmpty, let slash = l.firstIndex(of: 0x2F), let num = Int(String(decoding: l[..<slash], as: UTF8.self)) else { continue }
            let text = l[(slash + 1)...].map { $0 ^ 0x13 }
            let key = section + String(format: "%03d", num)
            if out[key] == nil, let t = clean(text, encoding: dos850), !t.isEmpty { out[key] = t }
        }
        return out
    }

    /// Traduction de COMI (LANGUAGE.TAB) : lignes « B2GT301<tab>texte » en Windows-1252.
    static func tabTexts(_ url: URL) -> [String: String] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        var out: [String: String] = [:]
        for raw in d.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) {
            let l = Array(raw)
            guard let tab = l.firstIndex(of: 0x09), tab > 0, tab <= 12 else { continue }
            let key = String(decoding: l[..<tab], as: UTF8.self).uppercased()
            var bytes: [UInt8] = []
            var e = tab + 1
            while e < l.count {
                if l[e] == 0xFF, e + 1 < l.count { e += l[e + 1] == 0x0A ? 16 : 4; continue }
                bytes.append(l[e] < 0x20 ? 0x20 : l[e]); e += 1
            }
            if out[key] == nil, let t = clean(bytes, encoding: .windowsCP1252), !t.isEmpty { out[key] = t }
        }
        return out
    }

    private static let dos437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
    private static let dos850 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatin1.rawValue)))

    private static func clean(_ b: [UInt8], encoding: String.Encoding) -> String? {
        guard let s = String(bytes: b, encoding: encoding) else { return nil }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Jeux de textes trouvés à côté de l'archive, par langue détectée : version d'origine d'abord, puis la traduction.
    static func textSets(near bank: URL) -> (url: URL, sets: [(String, [String: String])])? {
        let dir = bank.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var sets: [(String, [String: String])] = []
        var first: URL?
        // Scripts : The Dig (DIG.LA1 / .LAB), COMI (COMI.LA1 et COMI.LA2, dans RESOURCE ou dans le dossier parent).
        let parent = ((try? FileManager.default.contentsOfDirectory(at: dir.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey])) ?? [])
        let scripts = (items + parent).filter { ["LA1", "LA2", "LAB"].contains($0.pathExtension.uppercased()) }
        var seen = Set<String>(), merged: [String: String] = [:]
        for u in scripts.sorted(by: { size($0) > size($1) }) where seen.insert(u.lastPathComponent.uppercased()).inserted {
            merged.merge(scriptTexts(u)) { a, _ in a }
            first = first ?? u
        }
        if !merged.isEmpty { sets.append((detect(merged), merged)) } else { first = nil }
        if let bnd = items.first(where: { $0.lastPathComponent.uppercased() == "LANGUAGE.BND" }) {
            let t = languageTexts(bnd)
            let code = detect(t)
            if !t.isEmpty, !sets.contains(where: { $0.0 == code }) { sets.append((code, t)); first = first ?? bnd }
        }
        if let tab = (items + parent).first(where: { $0.lastPathComponent.uppercased() == "LANGUAGE.TAB" }) {
            let t = tabTexts(tab)
            let code = detect(t)
            // Voix doublées dans la langue de LANGUAGE.TAB (version française : voix françaises) : ces textes passent en premier.
            if !t.isEmpty, !sets.contains(where: { $0.0 == code }) { sets.insert((code, t), at: 0); first = first ?? tab }
        }
        guard let u = first, !sets.isEmpty else { return nil }
        return (u, sets)
    }

    private static func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    private static func detect(_ t: [String: String]) -> String {
        let r = NLLanguageRecognizer()
        r.processString(t.values.prefix(400).joined(separator: " "))
        return r.dominantLanguage?.rawValue ?? "en"
    }
}
