// mTALKIE — Broken Sword : The Shadow of the Templars (Revolution, version ScummVM) : speech1.clv / speech2.clv
// (aussi .clf en FLAC et .cl3 en MP3). En-tête : taille (LE32) puis mots LE32 ; le mot n° 1 + scène donne, divisé par 4,
// le mot où commencent les répliques de la scène : pour la réplique n, position absolue puis taille du flux compressé.
// Textes : clusters/text.clu, décrit par swordres.rif (cluster 3, un groupe par langue, une ressource par section).
// La voix (scène, n) et le texte (section, n) portent le même numéro : c'est le paramètre du script fnISpeak.
import Foundation
import NaturalLanguage

enum Sword1 {
    static let extensions = ["clv", "clf", "cl3"]
    static func isSpeech(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    static func ext(_ url: URL) -> String { ["clv": "ogg", "clf": "flac", "cl3": "mp3"][url.pathExtension.lowercased()] ?? "ogg" }

    static func le32(_ d: Data, _ p: Int) -> Int {
        let s = d.startIndex + p
        return Int(d[s]) | Int(d[s + 1]) << 8 | Int(d[s + 2]) << 16 | Int(d[s + 3]) << 24
    }

    /// Répliques : `name` = « 012-0034 » (scène 12, réplique 34), `offset` = scène × 65536 + n (numéro du texte).
    static func parse(_ d: Data) throws -> [Line] {
        guard d.count > 16 else { throw FormatError.notSoundBank }
        let size = le32(d, 0)
        guard size > 8, size % 4 == 0, size < d.count else { throw FormatError.notSoundBank }
        let words = size / 4
        func w(_ i: Int) -> Int { le32(d, i * 4) }
        // Table des scènes : mots 1… jusqu'au premier bloc de répliques.
        var first = words
        var i = 1
        while i < first, i < words {
            let v = w(i) >> 2
            if v > 0, v < first { first = v }
            i += 1
        }
        var rooms: [(room: Int, start: Int)] = []
        for r in 1 ..< first where w(r) > 0 { rooms.append((r - 1, w(r) >> 2)) }
        guard !rooms.isEmpty else { throw FormatError.notSoundBank }
        rooms.sort { $0.start < $1.start }
        var out: [Line] = []
        for (k, room) in rooms.enumerated() {
            let end = k + 1 < rooms.count ? rooms[k + 1].start : words
            var n = 0
            while room.start + 2 * n + 1 < end {
                let off = w(room.start + 2 * n), len = w(room.start + 2 * n + 1)
                if len > 0, len != 0xFFFF_FFFF, off + len <= d.count {
                    var l = Line(id: out.count + 1, offset: room.room << 16 | n, start: off, length: len, rate: 0, duration: 0)
                    l.name = String(format: "%03d-%04d", room.room, n)
                    out.append(l)
                }
                n += 1
            }
        }
        return out
    }

    static func decode(_ d: Data, line: Line, ext: String) throws -> PCM {
        try CompressedDecoder.decode(d.subdata(in: d.startIndex + line.start ..< d.startIndex + line.start + line.length), ext: ext)
    }

    // MARK: Textes

    /// Sections qui ont des textes, dans l'ordre des ressources de text.clu (table _textList de ScummVM).
    static let sections: [Int] = Array(0 ... 7) + [9] + Array(11 ... 25) + [27, 28, 29] + Array(31 ... 43) + [45, 47, 48, 49, 50]
        + Array(54 ... 61) + [63, 65, 66, 69, 71, 72, 73, 74, 90, 99, 129, 131, 133, 145, 146]

    /// Dossier des clusters (swordres.rif) : à côté du fichier de voix, dans « clusters », ou dans le dossier parent.
    static func clusters(near url: URL) -> URL? {
        let dir = url.deletingLastPathComponent(), parent = dir.deletingLastPathComponent()
        let fm = FileManager.default
        for d in [dir, dir.appendingPathComponent("clusters"), parent, parent.appendingPathComponent("clusters")] {
            if let n = (try? fm.contentsOfDirectory(atPath: d.path))?.first(where: { $0.lowercased() == "swordres.rif" }) {
                return d.appendingPathComponent(n)
            }
        }
        return nil
    }

    /// Ressources du cluster TEXT : par langue (groupe), la position et la taille de chaque section.
    static func textResources(_ rif: Data) -> (label: String, groups: [[(Int, Int)?]])? {
        var p = 0
        func u() -> Int? { guard p + 4 <= rif.count else { return nil }; defer { p += 4 }; return le32(rif, p) }
        guard let ncl = u(), ncl > 2, ncl < 64 else { return nil }
        var present: [Int] = []
        for _ in 0 ..< ncl { guard let v = u() else { return nil }; present.append(v) }
        for c in 0 ..< ncl where present[c] != 0 {
            guard p + 32 <= rif.count else { return nil }
            let label = String(decoding: rif[(rif.startIndex + p) ..< (rif.startIndex + p + 32)].prefix { $0 != 0 }, as: UTF8.self)
            p += 32
            guard let ng = u(), ng < 256 else { return nil }
            var gi: [Int] = []
            for _ in 0 ..< ng { guard let v = u() else { return nil }; gi.append(v) }
            var groups: [[(Int, Int)?]] = []
            for g in 0 ..< ng {
                guard gi[g] != 0 else { groups.append([]); continue }
                guard let nr = u(), nr < 100_000 else { return nil }
                var ri: [Int] = []
                for _ in 0 ..< nr { guard let v = u() else { return nil }; ri.append(v) }
                var res: [(Int, Int)?] = []
                for k in 0 ..< nr {
                    if ri[k] != 0 { guard let o = u(), let l = u() else { return nil }; res.append((o, l)) } else { res.append(nil) }
                }
                groups.append(res)
            }
            if c == 2 { return (label, groups) }
        }
        return nil
    }

    /// Textes par langue : « numéro de texte » (section × 65536 + n) → texte.
    static func textSets(near url: URL) -> (url: URL, sets: [(String, [Int: String])])? {
        guard let rifURL = clusters(near: url), let rif = try? Data(contentsOf: rifURL),
              let res = textResources(rif) else { return nil }
        let dir = rifURL.deletingLastPathComponent()
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.lowercased() == res.label.lowercased() + ".clu" }),
              let t = try? Data(contentsOf: dir.appendingPathComponent(name), options: .alwaysMapped) else { return nil }
        var sets: [(String, [Int: String])] = []
        let dos852 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatin2.rawValue)))
        for (gi, group) in res.groups.enumerated() {
            let enc: String.Encoding = gi == 5 ? dos852 : .windowsCP1252          // groupe 5 : tchèque, en page de code DOS 852
            var dict: [Int: String] = [:]
            for (k, section) in sections.enumerated() where k < group.count {
                guard let (o, l) = group[k], o + l <= t.count, l > 24 else { continue }
                let a = o + 20                                              // en-tête de ressource (20 octets)
                let n = le32(t, a)
                guard n > 0, n < 10_000, a + 4 + n * 4 <= o + l else { continue }
                for i in 0 ..< n {
                    let rel = le32(t, a + 4 + 4 * i)
                    guard rel > 0, a + rel < o + l else { continue }
                    let start = t.startIndex + a + rel
                    let end = t[start ..< (t.startIndex + o + l)].firstIndex(of: 0) ?? (t.startIndex + o + l)
                    if let s = String(data: t[start ..< end], encoding: enc) {
                        let clean = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                        if !clean.isEmpty { dict[section << 16 | i] = clean }
                    }
                }
            }
            guard !dict.isEmpty else { continue }
            let r = NLLanguageRecognizer()
            r.processString(dict.values.prefix(300).joined(separator: " "))
            let code = r.dominantLanguage?.rawValue ?? "en"
            if !sets.contains(where: { $0.0 == code }) { sets.append((code, dict)) }
        }
        guard !sets.isEmpty else { return nil }
        return (dir.appendingPathComponent(name), sets)
    }
}
