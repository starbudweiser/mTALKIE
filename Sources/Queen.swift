// mTALKIE — Flight of the Amazon Queen (Interactive Binary Illusions) : fichier queen.1c reconstruit par les outils ScummVM.
// En-tête : « QTBL », version (6 octets), 2 octets, compression (0 aucune, 1 MP3, 2 Ogg Vorbis, 3 FLAC), nombre (BE16),
// puis par fichier : nom (12), lot (1), position et taille (BE32). Les voix sont les fichiers .SB.
// Nom d'une voix = préfixe + numéro de segment (hexadécimal) ; la phrase est découpée sur « * » suivi d'une commande :
//  - dialogues (.DOG, n° de dialogue « talkKey ») : « 02 0006 P 1 » = dialogue 2, réplique 6, Personnage ou Joe, segment 1 ;
//  - scènes (.CUT) : « C18A_ » + n° de la phrase sur 2 chiffres + segment ;
//  - remarques de Joe : « JOE0024 » + segment, texte n° 24 de QUEEN2.JAS.
import Foundation
import NaturalLanguage

enum Queen {
    struct Entry { let name: String, offset: Int, size: Int }

    static func isQueen(_ url: URL) -> Bool { url.lastPathComponent.lowercased().hasPrefix("queen.1") }

    static func be16(_ d: Data, _ p: Int) -> Int { Int(d[d.startIndex + p]) << 8 | Int(d[d.startIndex + p + 1]) }
    static func be32(_ d: Data, _ p: Int) -> Int { be16(d, p) << 16 | be16(d, p + 2) }

    static func table(_ d: Data) throws -> (compression: Int, entries: [String: Entry]) {
        guard d.count > 16, d.prefix(4).elementsEqual("QTBL".utf8) else { throw FormatError.notSoundBank }
        let compression = Int(d[d.startIndex + 12]), n = be16(d, 13)
        guard n > 0, 15 + n * 21 <= d.count else { throw FormatError.notSoundBank }
        var out: [String: Entry] = [:]
        for i in 0 ..< n {
            let e = 15 + i * 21
            let name = String(decoding: d[(d.startIndex + e) ..< (d.startIndex + e + 12)].prefix { $0 != 0 }, as: UTF8.self)
            let off = be32(d, e + 13), size = be32(d, e + 17)
            if off + size <= d.count { out[name] = Entry(name: name, offset: off, size: size) }
        }
        return (compression, out)
    }

    static func ext(_ compression: Int) -> String { [1: "mp3", 2: "ogg", 3: "flac"][compression] ?? "ogg" }

    /// Voix triées ; `name` = « BUD_020006P1 » (personnage tiré du nom du dialogue), « JOE_JOE00241 », ou le code tel quel (scènes).
    static func parse(_ d: Data) throws -> [Line] {
        let t = try table(d)
        guard t.compression != 0 else { throw FormatError.unsupportedCodec }    // .SB non compressés : pas encore lus
        var speakers: [Int: String] = [:]                                        // talkKey → personnage (BUD1.DOG → BUD)
        for e in t.entries.values where e.name.hasSuffix(".DOG") && e.size > 30 {
            let key = be16(d, e.offset + 20 + 4)
            let stem = e.name.dropLast(4).replacingOccurrences(of: #"[0-9]+$"#, with: "", options: .regularExpression)
            if speakers[key] == nil { speakers[key] = stem }
        }
        let voices = t.entries.values.filter { $0.name.hasSuffix(".SB") }.sorted { $0.name < $1.name }
        return voices.enumerated().map { i, e in
            let code = String(e.name.dropLast(3))
            var l = Line(id: i + 1, offset: i, start: e.offset, length: e.size, rate: 0, duration: 0)
            if code.range(of: #"^[0-9]{2}[0-9A-FXS]{4}[JP][0-9A-F]$"#, options: .regularExpression) != nil {
                let joe = code.dropFirst(6).first == "J"
                l.name = (joe ? "JOE" : speakers[Int(code.prefix(2)) ?? -1] ?? "P") + "_" + code
            } else if code.hasPrefix("JOE") {
                l.name = "JOE_" + code
            } else {
                l.name = code
            }
            return l
        }
    }

    /// Code d'origine d'une voix (sans le personnage ajouté devant).
    static func code(_ name: String) -> String {
        if let u = name.firstIndex(of: "_"), name.distance(from: u, to: name.endIndex) == 9 { return String(name[name.index(after: u)...]) }
        return name
    }

    static func decode(_ d: Data, line: Line, compression: Int) throws -> PCM {
        try CompressedDecoder.decode(d.subdata(in: d.startIndex + line.start ..< d.startIndex + line.start + line.length), ext: ext(compression))
    }

    // MARK: Textes

    private static let dos850 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatin1.rawValue)))

    /// Chaîne précédée de sa longueur, la position suivante étant alignée sur `align`.
    static func string(_ b: Data, _ off: inout Int, align: Int) -> String {
        guard off < b.count else { return "" }
        let n = Int(b[b.startIndex + off]); off += 1
        guard n > 0, off + n <= b.count else { return "" }
        let s = String(data: b[(b.startIndex + off) ..< (b.startIndex + off + n)], encoding: dos850) ?? ""
        off = (off + n + align - 1) & ~(align - 1)
        return s
    }

    /// Segments d'une phrase (séparés par « * » + commande de 2 caractères, 13 pour « XY ») → code + n° de segment.
    static func segments(_ prefix: String, _ sentence: String, into out: inout [String: String]) {
        let c = Array(sentence)
        var parts: [String] = [], start = 0, i = 0
        while i < c.count {
            if c[i] == "*" {
                parts.append(String(c[start ..< i])); i += 1
                i += (i + 1 < c.count && c[i] == "X" && c[i + 1] == "Y") ? 13 : 2
                start = min(i, c.count)
            } else { i += 1 }
        }
        if start < c.count { parts.append(String(c[start...])) }
        for (k, p) in parts.enumerated() {
            let t = p.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = (prefix + String(k + 1, radix: 16)).replacingOccurrences(of: " ", with: "0").uppercased()
            if !t.isEmpty, out[key] == nil { out[key] = t }
        }
    }

    /// Textes de la version du fichier (une langue), par code de voix.
    static func texts(_ d: Data) -> [String: String] {
        guard let t = try? table(d) else { return [:] }
        func file(_ e: Entry, skip: Int = 20) -> Data { d.subdata(in: (d.startIndex + e.offset + skip) ..< (d.startIndex + e.offset + e.size)) }
        var out: [String: String] = [:]
        for e in t.entries.values where e.name.hasSuffix(".DOG") && e.size > 52 {
            let b = file(e)
            let levels = abs(Int(Int16(truncatingIfNeeded: be16(b, 0)))), key = be16(b, 4), jMax = be16(b, 6), pMax = be16(b, 8)
            let p1 = be16(b, 22), p2 = be16(b, 26), jp = 32 + levels * 96
            guard jp + 4 < b.count else { continue }
            for (base, max, who) in [(p1, pMax, "P"), (jp, jMax, "J")] {
                var off = base
                for _ in 0 ..< max {
                    guard off + 4 < b.count else { break }
                    off += 2; let id = Int(Int16(truncatingIfNeeded: be16(b, off))); off += 2
                    let s = string(b, &off, align: 4)
                    guard id >= 0, !s.isEmpty else { continue }
                    segments(String(format: "%2d%4x", key, id) + who, s, into: &out)
                    if who == "P", id == 1 { segments(String(format: "%2dXXXXP", key), s, into: &out) }
                }
            }
            if be16(b, jp + 2) == 0 { var off = jp + 4; segments(String(format: "%2dSSSSJ", key), string(b, &off, align: 2), into: &out) }
            var off = p2
            _ = string(b, &off, align: 2)
            segments(String(format: "%2dXXXXJ", key), string(b, &off, align: 2), into: &out)
        }
        for e in t.entries.values where e.name.hasSuffix(".CUT") && e.size > 34 {
            let b = file(e)
            let count = abs(Int(Int16(truncatingIfNeeded: be16(b, 2))))
            var off = be16(b, 8)
            var base = String(e.name.dropLast(4))
            while base.count < 5 { base += "_" }
            _ = string(b, &off, align: 2)                                       // phrase d'entrée
            for i in 0 ..< count where off < b.count {
                let s = string(b, &off, align: 2)
                if !s.isEmpty { segments(base + String(format: "%02d", i + 1), s, into: &out) }
            }
        }
        if let jas = t.entries["QUEEN2.JAS"], let s = String(data: file(jas, skip: 0), encoding: .isoLatin1) {
            let lines = s.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where i < 9999 && !l.isEmpty { segments(String(format: "JOE%04d", i + 1), l, into: &out) }
        }
        return out
    }

    static func textSets(near url: URL, data: Data) -> (url: URL, sets: [(String, [String: String])])? {
        let t = texts(data)
        guard !t.isEmpty else { return nil }
        let r = NLLanguageRecognizer()
        r.processString(t.values.prefix(300).joined(separator: " "))
        return (url, [(r.dominantLanguage?.rawValue ?? "en", t)])
    }
}
