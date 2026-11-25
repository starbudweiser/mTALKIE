// mTALKIE — Tales of Monkey Island (Telltale) : archives .ttarch version 8, une par épisode.
// En-tête : version, chiffrement, ?, mode des fichiers (2 = compressés par blocs), nombre de blocs et leurs tailles,
// taille des données, 2 + 2 champs, taille d'un bloc (Ko), un octet, taille du sommaire (et taille compressée en mode 2).
// Sommaire et blocs chiffrés en Blowfish (variante Telltale à partir de la version 7 : sous-clés P1–P4 permutées en
// déchiffrement et S0[118] inversée ; le calcul de la clé, lui, est standard) ; clé propre à chaque épisode.
// Voix (…_voice.ttarch) : « 107372288.aud » = en-tête ERTM puis flux Ogg Vorbis ; le nom est le numéro du texte.
// Textes et personnages : english.langdb / german.langdb dans …_data.ttarch (numéro, numéro, personnage, texte).
import Foundation
import Compression

/// Blowfish avec la variante Telltale (blocs de deux mots de 32 bits en petit-boutiste).
struct TelltaleBlowfish {
    private var p: [UInt32]
    private var s: [UInt32]
    private let modified: Bool

    init(key: [UInt8], modified: Bool) {
        self.modified = modified
        p = BlowfishTables.p
        s = BlowfishTables.s
        var j = 0
        for i in 0 ..< 18 {
            var d: UInt32 = 0
            for _ in 0 ..< 4 { d = d << 8 | UInt32(key[j]); j = (j + 1) % key.count }
            p[i] ^= d
        }
        if modified { s[118] = s[118].byteSwapped }
        var l: UInt32 = 0, r: UInt32 = 0
        for i in stride(from: 0, to: 18, by: 2) { encipher(&l, &r); p[i] = l; p[i + 1] = r }
        for i in stride(from: 0, to: 1024, by: 2) { encipher(&l, &r); s[i] = l; s[i + 1] = r }
    }

    @inline(__always) private func f(_ x: UInt32) -> UInt32 {
        ((s[Int(x >> 24)] &+ s[256 + Int((x >> 16) & 255)]) ^ s[512 + Int((x >> 8) & 255)]) &+ s[768 + Int(x & 255)]
    }

    private func encipher(_ xl: inout UInt32, _ xr: inout UInt32) {        // standard (calcul de la clé)
        var l = xl, r = xr
        for i in 0 ..< 16 { l ^= p[i]; r = f(l) ^ r; swap(&l, &r) }
        swap(&l, &r)
        xr = r ^ p[16]; xl = l ^ p[17]
    }

    private func decipher(_ xl: inout UInt32, _ xr: inout UInt32) {
        var l = xl, r = xr
        var i = 17
        while i > 1 {
            var t = p[i]
            if modified { if i == 4 { t = p[2] } else if i == 3 { t = p[1] } else if i == 2 { t = p[4] } }
            l ^= t; r = f(l) ^ r; swap(&l, &r)
            i -= 1
        }
        swap(&l, &r)
        xr = r ^ (modified ? p[3] : p[1]); xl = l ^ p[0]
    }

    func decrypt(_ b: inout [UInt8]) {
        var i = 0
        while i + 8 <= b.count {
            var l = UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
            var r = UInt32(b[i + 4]) | UInt32(b[i + 5]) << 8 | UInt32(b[i + 6]) << 16 | UInt32(b[i + 7]) << 24
            decipher(&l, &r)
            b[i] = UInt8(l & 255); b[i + 1] = UInt8((l >> 8) & 255); b[i + 2] = UInt8((l >> 16) & 255); b[i + 3] = UInt8(l >> 24)
            b[i + 4] = UInt8(r & 255); b[i + 5] = UInt8((r >> 8) & 255); b[i + 6] = UInt8((r >> 16) & 255); b[i + 7] = UInt8(r >> 24)
            i += 8
        }
    }
}

enum Telltale {
    struct Entry { let name: String, offset: Int, size: Int }

    /// Une archive ouverte : sommaire et accès aux données (brutes ou par blocs compressés).
    struct Archive {
        let data: Data
        let entries: [Entry]
        let filesOffset: Int
        let compressed: Bool
        let encrypted: Bool
        let chunkSize: Int
        let chunkStarts: [Int]                 // positions cumulées des blocs compressés
        let cipher: TelltaleBlowfish

        func read(_ e: Entry) -> [UInt8]? {
            if !compressed {
                guard filesOffset + e.offset + e.size <= data.count else { return nil }
                return [UInt8](data[(data.startIndex + filesOffset + e.offset) ..< (data.startIndex + filesOffset + e.offset + e.size)])
            }
            var out: [UInt8] = []
            out.reserveCapacity(e.size + chunkSize)
            var k = e.offset / chunkSize
            let skip = e.offset % chunkSize
            while out.count < skip + e.size, k + 1 < chunkStarts.count {
                let a = filesOffset + chunkStarts[k], b = filesOffset + chunkStarts[k + 1]
                guard b <= data.count else { return nil }
                var c = [UInt8](data[(data.startIndex + a) ..< (data.startIndex + b)])
                if encrypted { cipher.decrypt(&c) }
                guard let block = Telltale.inflate(c, size: chunkSize) else { return nil }
                out += block
                k += 1
            }
            guard out.count >= skip + e.size else { return nil }
            return Array(out[skip ..< (skip + e.size)])
        }
    }

    // Clés des cinq épisodes (TTG Tools / TelltaleToolKit) : elles ne diffèrent que de trois octets.
    static func key(episode: Int) -> [UInt8] {
        var k: [UInt8] = [0x8C, 0xD8, 0x9B, 0x9F, 0x89, 0xE5, 0x7C, 0xB6, 0xDE, 0xCD, 0xE3, 0xC8, 0x63, 0x95, 0x84, 0xA4, 0xD8, 0x98, 0x98,
                          0xDC, 0xB6, 0xBE, 0xA9, 0xDB, 0xC6, 0x8F, 0xD3, 0x86, 0x69, 0x9D, 0xAE, 0xA3, 0xCD, 0xB0, 0x97, 0xC8, 0xAA, 0xD6,
                          0xA5, 0xCD, 0xE3, 0xD8, 0xA9, 0x9C, 0x68, 0x7F, 0xC1, 0xDD, 0xB0, 0xC8, 0x9F, 0x7C, 0xE3, 0xDE, 0xA0]
        let e = UInt8(max(1, min(5, episode)) - 1)
        k[14] &+= e; k[29] &+= e; k[44] &+= e
        return k
    }

    static func isArchive(_ url: URL) -> Bool { url.pathExtension.lowercased() == "ttarch" }

    /// Épisode d'après le nom (« 2_MonkeyIsland103_pc_voice.ttarch » → 3), sinon nil.
    static func episode(_ url: URL) -> Int? {
        guard let r = url.lastPathComponent.range(of: #"MonkeyIsland10([1-5])"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(String(url.lastPathComponent[r].suffix(1)))
    }

    static func le32(_ d: Data, _ p: Int) -> Int {
        let s = d.startIndex + p
        return Int(d[s]) | Int(d[s + 1]) << 8 | Int(d[s + 2]) << 16 | Int(d[s + 3]) << 24
    }

    static func inflate(_ src: [UInt8], size: Int) -> [UInt8]? {
        let body = src.count > 2 && src[0] == 0x78 ? Array(src.dropFirst(2)) : src      // en-tête zlib éventuel
        var out = [UInt8](repeating: 0, count: size)
        let n = compression_decode_buffer(&out, size, body, body.count, nil, COMPRESSION_ZLIB)
        return n > 0 ? Array(out.prefix(n)) : nil
    }

    static func open(_ d: Data, url: URL) throws -> Archive {
        guard d.count > 64, le32(d, 0) >= 7, le32(d, 0) <= 9 else { throw FormatError.notSoundBank }
        let version = le32(d, 0), encrypted = le32(d, 4) == 1, mode = le32(d, 12), count = le32(d, 16)
        guard count >= 0, count < 1_000_000, 20 + count * 4 + 64 < d.count else { throw FormatError.notSoundBank }
        var starts = [0]
        for i in 0 ..< count { starts.append(starts[i] + le32(d, 20 + i * 4)) }
        var p = 20 + count * 4 + 4 + 8 + 8
        let chunkSize = le32(d, p) * 1024; p += 4
        if version >= 8 { p += 1 }
        if version >= 9 { p += 4 }
        let size = le32(d, p); p += 4
        var packed = size
        if mode == 2 { packed = le32(d, p); p += 4 }
        guard size > 8, packed > 8, p + packed <= d.count else { throw FormatError.notSoundBank }
        let raw = [UInt8](d[(d.startIndex + p) ..< (d.startIndex + p + packed)])
        let candidates = episode(url).map { [$0] } ?? [1, 2, 3, 4, 5]
        for ep in candidates {
            let cipher = TelltaleBlowfish(key: key(episode: ep), modified: version >= 7)
            var h = mode == 2 ? (inflate(raw, size: size) ?? []) : raw
            if encrypted { cipher.decrypt(&h) }
            guard let entries = parseEntries(h) else { continue }
            return Archive(data: d, entries: entries, filesOffset: p + packed, compressed: mode == 2 && count > 0,
                           encrypted: encrypted, chunkSize: max(chunkSize, 0x10000), chunkStarts: starts, cipher: cipher)
        }
        throw FormatError.unsupportedCodec
    }

    /// Dossiers (ignorés) puis fichiers : nom, dossier, position, taille.
    static func parseEntries(_ h: [UInt8]) -> [Entry]? {
        var q = 0
        func i32() -> Int? {
            guard q + 4 <= h.count else { return nil }
            defer { q += 4 }
            return Int(Int32(bitPattern: UInt32(h[q]) | UInt32(h[q + 1]) << 8 | UInt32(h[q + 2]) << 16 | UInt32(h[q + 3]) << 24))
        }
        guard let dirs = i32(), dirs >= 0, dirs < 10_000 else { return nil }
        for _ in 0 ..< dirs { guard let n = i32(), n > 0, n < 1024, q + n <= h.count else { return nil }; q += n }
        guard let files = i32(), files > 0, files < 1_000_000 else { return nil }
        var out: [Entry] = []
        out.reserveCapacity(files)
        for _ in 0 ..< files {
            guard let n = i32(), n > 0, n < 256, q + n <= h.count else { return nil }
            let name = String(decoding: h[q ..< (q + n)], as: UTF8.self); q += n
            guard i32() != nil, let o = i32(), let s = i32(), o >= 0, s >= 0 else { return nil }
            out.append(Entry(name: name, offset: o, size: s))
        }
        return out
    }

    // MARK: Voix

    static func parse(_ d: Data, url: URL) throws -> (lines: [Line], archive: Archive) {
        let a = try open(d, url: url)
        let speakers = texts(near: url).first?.1 ?? [:]
        let voices = a.entries.filter { $0.name.lowercased().hasSuffix(".aud") }
            .sorted { (Int($0.name.dropLast(4)) ?? 0) < (Int($1.name.dropLast(4)) ?? 0) }
        let lines = voices.enumerated().map { i, e -> Line in
            let id = String(e.name.dropLast(4))
            var l = Line(id: i + 1, offset: Int(id) ?? i, start: e.offset, length: e.size, rate: 0, duration: 0)
            let who = speakers[Int(id) ?? -1]?.speaker ?? ""
            l.name = who.isEmpty ? id : who.uppercased().replacingOccurrences(of: " ", with: "") + "_" + id
            return l
        }
        return (lines, a)
    }

    static func decode(_ a: Archive, line: Line) throws -> PCM {
        guard let b = a.read(Entry(name: "", offset: line.start, size: line.length)) else { throw FormatError.unsupportedCodec }
        let ogg = Array("OggS".utf8)
        guard let at = (0 ..< min(b.count - 4, 4096)).first(where: { b[$0] == ogg[0] && Array(b[$0 ..< $0 + 4]) == ogg }) else {
            throw FormatError.unsupportedCodec
        }
        return try CompressedDecoder.decode(Data(b[at...]), ext: "ogg")
    }

    // MARK: Textes

    struct Text { let speaker: String, text: String }

    /// Langues trouvées dans l'archive de données voisine (…_data.ttarch) : (code, numéro → personnage et texte).
    static func texts(near url: URL) -> [(String, [Int: Text])] {
        let dir = url.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let dataURL = items.first(where: { isArchive($0) && $0.lastPathComponent.lowercased().contains("_data") }),
              let d = try? Data(contentsOf: dataURL, options: .alwaysMapped), let a = try? open(d, url: dataURL) else { return [] }
        let codes = ["english": "en", "german": "de", "french": "fr", "spanish": "es", "italian": "it"]
        var out: [(String, [Int: Text])] = []
        for e in a.entries where e.name.lowercased().hasSuffix(".langdb") {
            let stem = String(e.name.lowercased().dropLast(7))
            guard var b = a.read(e) else { continue }
            metaDecrypt(&b, cipher: a.cipher)
            let t = langdb(b)
            if !t.isEmpty { out.append((codes[stem] ?? stem, t)) }
        }
        return out.sorted { ($0.0 == "en" ? 0 : 1) < ($1.0 == "en" ? 0 : 1) }
    }

    /// Fichiers chiffrés un par un (épisodes 2 à 5) : signature puis blocs ; tous les `crypt` blocs, un bloc Blowfish ;
    /// tous les `clean` blocs, un bloc en clair ; les autres inversés (XOR 0xFF) — d'après TTG Tools (meta_crypt).
    static func metaDecrypt(_ b: inout [UInt8], cipher: TelltaleBlowfish) {
        guard b.count > 8 else { return }
        let magic = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        let (size, crypt, clean): (Int, Int, Int)
        switch magic {
        case 0xFB4A_1764, 0xEB79_4091, 0x64AF_DEFB: (size, crypt, clean) = (0x80, 0x20, 0x50)
        case 0x64AF_DEAA: (size, crypt, clean) = (0x100, 0x8, 0x18)
        case 0x4D42_4553: (size, crypt, clean) = (0x40, 0x40, 0x64)
        default: return
        }
        let blocks = (b.count - 4) / size
        for i in 0 ..< blocks {
            let at = 4 + i * size
            if i % crypt == 0 {
                var blk = Array(b[at ..< at + size])
                cipher.decrypt(&blk)
                b.replaceSubrange(at ..< at + size, with: blk)
            } else if i % clean == 0 {
                continue
            } else {
                for k in at ..< at + size { b[k] ^= 0xFF }
            }
        }
    }

    /// Entrées « numéro, numéro, [taille, longueur, personnage], [taille, longueur, texte] » repérées dans le flux.
    static func langdb(_ b: [UInt8]) -> [Int: Text] {
        func u(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
        var out: [Int: Text] = [:]
        var i = 0
        let latin = String.Encoding.windowsCP1252
        while i + 24 < b.count {
            let id = u(i)
            guard id > 0, u(i + 4) == id else { i += 1; continue }
            let s1 = u(i + 8), n1 = u(i + 12)
            guard s1 == n1 + 8, n1 >= 0, n1 < 64, i + 16 + n1 + 8 <= b.count else { i += 1; continue }
            let s2 = u(i + 16 + n1), n2 = u(i + 20 + n1)
            guard s2 == n2 + 8, n2 >= 0, n2 < 4096, i + 24 + n1 + n2 <= b.count else { i += 1; continue }
            let who = String(bytes: b[(i + 16) ..< (i + 16 + n1)], encoding: latin) ?? ""
            let text = String(bytes: b[(i + 24 + n1) ..< (i + 24 + n1 + n2)], encoding: latin) ?? ""
            let clean = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)      // indications de jeu {incredulous}
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if out[id] == nil, !clean.isEmpty { out[id] = Text(speaker: who, text: clean) }
            i += 24 + n1 + n2
        }
        return out
    }
}
