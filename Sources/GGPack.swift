// mTALKIE — Thimbleweed Park (moteur Dinky de Terrible Toybox) : archives ThimbleweedPark.ggpack1…5.
// En-tête : position et taille du répertoire (LE32). Répertoire et fichiers sont chiffrés par un XOR qui dépend d'une clé de
// 16 octets, d'un multiplicateur (0x6D ou 0xAD selon l'édition), de la position et de l'octet précédent.
// Le répertoire déchiffré est un dictionnaire binaire (signature 0x04030201) : { "files": [{filename, offset, size}…] }.
// Voix : « BANKMANAGER_20204.ogg » (Ogg Vorbis) ; texte n° 20204 dans ThimbleweedText_<langue>.tsv (« 20204<tab>texte »).
import Foundation

enum GGPack {
    struct Entry { let name: String, offset: Int, size: Int }
    struct Key { let bytes: [UInt8], mult: Int }

    /// Les quatre éditions connues (Steam, GOG, Mac App Store, consoles).
    static let keys: [Key] = [(0x56, 0x6D), (0x56, 0xAD), (0x5B, 0x6D), (0x5B, 0xAD)].map { b5, m in
        Key(bytes: [0x4F, 0xD0, 0xA0, 0xAC, 0x4A, b5, 0xB9, 0xE5, 0x93, 0x79, 0x45, 0xA5, 0xC1, 0xCB, 0x31, 0x93], mult: m)
    }

    static func isPack(_ url: URL) -> Bool { url.pathExtension.lowercased().hasPrefix("ggpack") }

    /// Déchiffre un fichier entier (l'état initial dépend de sa taille).
    static func unxor(_ b: inout [UInt8], key: Key) {
        var prev = UInt8(truncatingIfNeeded: b.count)
        for i in 0 ..< b.count {
            let x = b[i] ^ key.bytes[i & 15] ^ UInt8(truncatingIfNeeded: i &* key.mult)
            b[i] = x ^ prev
            prev = x
        }
    }

    static func le32(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }

    /// Répertoire de l'archive et clé de l'édition.
    static func directory(_ d: Data) throws -> (entries: [Entry], key: Key) {
        guard d.count > 16 else { throw FormatError.notSoundBank }
        let head = [UInt8](d.prefix(8))
        let off = le32(head, 0), size = le32(head, 4)
        guard size > 16, off + size <= d.count else { throw FormatError.notSoundBank }
        let raw = [UInt8](d[(d.startIndex + off) ..< (d.startIndex + off + size)])
        for key in keys {
            var b = raw
            unxor(&b, key: key)
            guard le32(b, 0) == 0x04030201, var dict = try? Dict(b), let files = try? dict.files() else { continue }
            return (files, key)
        }
        throw FormatError.notSoundBank
    }

    /// Lecteur du dictionnaire binaire : 1 nul, 2 dictionnaire, 3 tableau, 4 chaîne, 5 entier, 6 réel ;
    /// les chaînes sont dans une table (marqueur 7, positions LE32, fin 0xFFFFFFFF) dont la position est en octet 8.
    private struct Dict {
        let b: [UInt8]
        var pos = 12
        var strings: [Int] = []
        init(_ b: [UInt8]) throws {
            self.b = b
            var p = GGPack.le32(b, 8)
            guard p < b.count, b[p] == 7 else { throw FormatError.notSoundBank }
            p += 1
            while p + 4 <= b.count {
                let o = GGPack.le32(b, p); p += 4
                if o == 0xFFFF_FFFF { break }
                strings.append(o)
            }
        }
        func string(_ i: Int) throws -> String {
            guard i < strings.count, strings[i] < b.count else { throw FormatError.notSoundBank }
            let s = strings[i]
            let e = b[s...].firstIndex(of: 0) ?? b.count
            return String(decoding: b[s ..< e], as: UTF8.self)
        }
        mutating func u32() throws -> Int {
            guard pos + 4 <= b.count else { throw FormatError.notSoundBank }
            defer { pos += 4 }
            return GGPack.le32(b, pos)
        }
        indirect enum Value { case null, dict([String: Value]), array([Value]), text(String) }
        mutating func value() throws -> Value {
            guard pos < b.count else { throw FormatError.notSoundBank }
            let t = b[pos]; pos += 1
            switch t {
            case 1: return .null
            case 2:
                var o: [String: Value] = [:]
                for _ in 0 ..< (try u32()) { let k = try string(try u32()); o[k] = try value() }
                pos += 1
                return .dict(o)
            case 3:
                var a: [Value] = []
                for _ in 0 ..< (try u32()) { a.append(try value()) }
                pos += 1
                return .array(a)
            case 4, 5, 6: return .text(try string(try u32()))
            default: throw FormatError.notSoundBank
            }
        }
        mutating func files() throws -> [Entry] {
            guard case .dict(let root) = try value(), case .array(let files)? = root["files"] else { throw FormatError.notSoundBank }
            return files.compactMap {
                guard case .dict(let f) = $0, case .text(let n)? = f["filename"], case .text(let o)? = f["offset"],
                      case .text(let s)? = f["size"], let off = Int(o), let size = Int(s) else { return nil }
                return Entry(name: n, offset: off, size: size)
            }
        }
    }

    /// Voix d'un personnage : « NOM_12345.ogg ».
    static func isVoice(_ name: String) -> Bool {
        name.range(of: #"^[A-Z0-9]+_[0-9]+\.ogg$"#, options: .regularExpression) != nil
    }

    /// Archives voisines (ggpack1, ggpack2…), dans l'ordre.
    static func siblings(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter(isPack).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// L'archive qui contient le plus de voix parmi les voisines (ggpack2 pour l'édition d'origine).
    static func voicePack(for url: URL) -> URL {
        func voices(_ u: URL) -> Int {
            guard let d = try? Data(contentsOf: u, options: .alwaysMapped), let dir = try? directory(d) else { return 0 }
            return dir.entries.filter { isVoice($0.name) }.count
        }
        let counts = Dictionary(siblings(of: url).map { ($0, voices($0)) }, uniquingKeysWith: { a, _ in a })
        return counts.filter { $0.value > 0 }.max { $0.value < $1.value }?.key ?? url
    }

    /// Répliques : `name` = « BANKMANAGER_20204 », triées par numéro de texte.
    static func parse(_ d: Data) throws -> [Line] {
        let dir = try directory(d)
        let voices = dir.entries.filter { isVoice($0.name) && $0.offset + $0.size <= d.count }
            .sorted { (id($0.name) ?? 0, $0.name) < (id($1.name) ?? 0, $1.name) }
        return voices.enumerated().map { i, e in
            var l = Line(id: i + 1, offset: i, start: e.offset, length: e.size, rate: 0, duration: 0)
            l.name = String(e.name.dropLast(4))
            return l
        }
    }

    /// Numéro de texte d'une réplique : « BANKMANAGER_20204 » → 20204.
    static func id(_ name: String) -> Int? {
        let stem = name.hasSuffix(".ogg") ? String(name.dropLast(4)) : name
        return stem.split(separator: "_").last.flatMap { Int($0) }
    }

    /// Déchiffre une entrée ; la clé est celle qui donne « OggS » (ou celle donnée).
    static func entry(_ d: Data, start: Int, length: Int, key: Key? = nil, magic: String? = "OggS") throws -> [UInt8] {
        guard length > 4, start + length <= d.count else { throw FormatError.notSoundBank }
        let raw = [UInt8](d[(d.startIndex + start) ..< (d.startIndex + start + length)])
        for k in key.map({ [$0] }) ?? keys {
            var b = raw
            unxor(&b, key: k)
            if magic == nil || b.prefix(4).elementsEqual(magic!.utf8) { return b }
        }
        throw FormatError.unsupportedCodec
    }

    static func decode(_ d: Data, line: Line) throws -> PCM {
        try CompressedDecoder.decode(Data(try entry(d, start: line.start, length: line.length)), ext: "ogg")
    }

    // MARK: Textes

    /// Textes des 6 langues (ThimbleweedText_en.tsv…), dans ggpack1 : « 20204 » → texte. Anglais d'abord (langue des voix).
    static func textSets(near url: URL) -> (url: URL, sets: [(String, [String: String])])? {
        var sets: [(String, [String: String])] = []
        var found: URL?
        for u in siblings(of: url) {
            guard let d = try? Data(contentsOf: u, options: .alwaysMapped), let dir = try? directory(d) else { continue }
            for e in dir.entries {
                let n = e.name.lowercased()
                guard n.hasPrefix("thimbleweedtext_"), n.hasSuffix(".tsv"),
                      let b = try? entry(d, start: e.offset, length: e.size, key: dir.key, magic: nil) else { continue }
                let lang = String(n.dropFirst("thimbleweedtext_".count).dropLast(4))
                let t = tsv(b)
                if !t.isEmpty, !sets.contains(where: { $0.0 == lang }) { sets.append((lang, t)); found = found ?? u }
            }
        }
        let order = ["en", "fr", "de", "es", "it", "ru"]
        sets.sort { (order.firstIndex(of: $0.0) ?? 99) < (order.firstIndex(of: $1.0) ?? 99) }
        guard let found, !sets.isEmpty else { return nil }
        return (found, sets)
    }

    /// « 20204<tab>texte » ; les marques de jeu entre accolades ({laugh}…) sont retirées.
    static func tsv(_ b: [UInt8]) -> [String: String] {
        var out: [String: String] = [:]
        for raw in b.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) {
            guard let tab = raw.firstIndex(of: 0x09) else { continue }
            let key = String(decoding: raw[raw.startIndex ..< tab], as: UTF8.self)
            guard Int(key) != nil else { continue }
            var text = String(decoding: raw[(tab + 1)...], as: UTF8.self)
            text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { out[key] = text }
        }
        return out
    }
}
