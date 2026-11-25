// mTALKIE — éditions modernes de Revolution : Broken Sword – Shadow of the Templars : Reforged (english.osa…) et
// Broken Sword 2 Remastered (Audio/Speech_english.dat…). Archive « AUFS » : nombre (LE32) puis, par son, numéro,
// position et taille (LE32) ; chaque son est un flux Ogg Opus.
// Reforged : le numéro est celui du texte de Broken Sword 1 (section × 65536 + n) ; textes dans text.vt7a
// (archive « VT7A » : une entrée zlib par langue, chacune « TEXT » + (numéro, position) + chaînes UTF-8).
// Broken Sword 2 Remastered : textes dans Text/Text_<langue>.clu (position du sommaire en tête, puis par ressource
// position et taille) ; une ressource = nom sur 32, nombre de lignes, positions (en mots de 16 bits), puis un numéro
// LE16 par ligne : celui de la voix dans Speech_<langue>.dat ; chaînes UTF-16 LE terminées par un zéro.
import Foundation
import Compression
import NaturalLanguage

enum Aufs {
    static func le32(_ d: Data, _ p: Int) -> Int {
        let s = d.startIndex + p
        return Int(d[s]) | Int(d[s + 1]) << 8 | Int(d[s + 2]) << 16 | Int(d[s + 3]) << 24
    }

    /// Fichier de voix : english.osa (Reforged) ou Speech_english.dat (BS2 Remastered) ; sfx.osa (bruitages) est exclu.
    static func isSpeech(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased(), e = url.pathExtension.lowercased()
        return (e == "osa" && n != "sfx.osa") || (e == "dat" && n.hasPrefix("speech_"))
    }
    static func isReforged(_ url: URL) -> Bool { url.pathExtension.lowercased() == "osa" }

    static func parse(_ d: Data, url: URL) throws -> [Line] {
        guard d.count > 20, d.prefix(4).elementsEqual("AUFS".utf8) else { throw FormatError.notSoundBank }
        let n = le32(d, 4)
        guard n > 0, 8 + n * 12 <= d.count else { throw FormatError.notSoundBank }
        var out: [Line] = []
        out.reserveCapacity(n)
        let reforged = isReforged(url)
        var entries: [(id: Int, off: Int, size: Int)] = []
        for i in 0 ..< n {
            let e = 8 + i * 12
            let id = le32(d, e), off = le32(d, e + 4), size = le32(d, e + 8)
            if size > 0, off + size <= d.count { entries.append((id, off, size)) }
        }
        for e in entries.sorted(by: { $0.id < $1.id }) {
            var l = Line(id: out.count + 1, offset: e.id, start: e.off, length: e.size, rate: 0, duration: 0)
            l.name = reforged ? String(format: "%03d-%04d", e.id >> 16, e.id & 0xFFFF) : String(format: "%05d", e.id)
            out.append(l)
        }
        return out
    }

    static func decode(_ d: Data, line: Line) throws -> PCM {
        try CompressedDecoder.decode(d.subdata(in: d.startIndex + line.start ..< d.startIndex + line.start + line.length), ext: "ogg")
    }

    // MARK: Textes (Reforged)

    /// Langue des voix d'après le nom du fichier (french.osa, Speech_german.dat…).
    static func voiceLanguage(_ url: URL) -> String? {
        let n = url.deletingPathExtension().lastPathComponent.lowercased()
        let map = ["english": "en", "american": "en", "french": "fr", "german": "de", "italian": "it", "spanish": "es", "russian": "ru", "brazilian": "pt"]
        return map.first { n.contains($0.key) }?.value
    }

    static func textSets(near url: URL) -> (url: URL, sets: [(String, [Int: String])])? {
        guard isReforged(url) else { return remasteredTextSets(near: url) }
        let dir = url.deletingLastPathComponent()
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.lowercased() == "text.vt7a" }),
              let d = try? Data(contentsOf: dir.appendingPathComponent(name), options: .alwaysMapped),
              d.count > 16, d.prefix(4).elementsEqual("VT7A".utf8) else { return nil }
        let n = le32(d, 12)
        guard n > 0, n < 64, 16 + n * 16 <= d.count else { return nil }
        var sets: [(String, [Int: String])] = []
        for i in 0 ..< n {
            let e = 16 + i * 16
            let off = le32(d, e + 4), full = le32(d, e + 8), packed = le32(d, e + 12)
            guard off + packed <= d.count, packed > 2, full > 0, full < 50_000_000,
                  let b = inflate(d.subdata(in: (d.startIndex + off + 2) ..< (d.startIndex + off + packed)), size: full) else { continue }
            let t = texts(b)
            guard !t.isEmpty else { continue }
            let r = NLLanguageRecognizer()
            r.processString(t.values.prefix(300).joined(separator: " "))
            let code = r.dominantLanguage?.rawValue ?? "en"
            if !sets.contains(where: { $0.0 == code }) { sets.append((code, t)) }
        }
        if let lang = voiceLanguage(url), let k = sets.firstIndex(where: { $0.0 == lang }) { sets.insert(sets.remove(at: k), at: 0) }
        guard !sets.isEmpty else { return nil }
        return (dir.appendingPathComponent(name), sets)
    }

    /// BS2 Remastered : Text/Text_<langue>.clu à côté du dossier Audio.
    static func remasteredTextSets(near url: URL) -> (url: URL, sets: [(String, [Int: String])])? {
        let dir = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Text")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let langs = [("english", "en"), ("french", "fr"), ("german", "de"), ("italian", "it"), ("spanish", "es"), ("russian", "ru"), ("brazilian", "pt")]
        var sets: [(String, [Int: String])] = []
        for (name, code) in langs {
            guard let f = items.first(where: { $0.lowercased() == "text_\(name).clu" }),
                  let d = try? Data(contentsOf: dir.appendingPathComponent(f), options: .alwaysMapped) else { continue }
            let t = remasteredTexts(d)
            if !t.isEmpty { sets.append((code, t)) }
        }
        if let lang = voiceLanguage(url), let k = sets.firstIndex(where: { $0.0 == lang }) { sets.insert(sets.remove(at: k), at: 0) }
        guard !sets.isEmpty else { return nil }
        return (dir, sets)
    }

    /// Numéro de voix → texte, pour un fichier Text_<langue>.clu.
    static func remasteredTexts(_ d: Data) -> [Int: String] {
        guard d.count > 16 else { return [:] }
        func u16(_ p: Int) -> Int { Int(d[d.startIndex + p]) | Int(d[d.startIndex + p + 1]) << 8 }
        let index = le32(d, 0)
        guard index > 8, index < d.count else { return [:] }
        var out: [Int: String] = [:]
        for k in 0 ..< (d.count - index) / 8 {
            let off = le32(d, index + k * 8), size = le32(d, index + k * 8 + 4)
            guard size > 36, off + size <= d.count else { continue }
            let n = le32(d, off + 32)
            guard n > 0, 36 + n * 6 <= size else { continue }
            for i in 0 ..< n {
                let id = u16(off + 36 + n * 4 + i * 2)
                guard id != 0, out[id] == nil else { continue }
                let p = off + le32(d, off + 36 + i * 4) * 2
                guard p >= off, p < off + size else { continue }
                var e = p
                while e + 1 < off + size, d[d.startIndex + e] != 0 || d[d.startIndex + e + 1] != 0 { e += 2 }
                guard let s = String(bytes: d[(d.startIndex + p) ..< (d.startIndex + e)], encoding: .utf16LittleEndian) else { continue }
                let clean = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !clean.isEmpty { out[id] = clean }
            }
        }
        return out
    }

    /// Flux deflate brut (sans les 2 octets d'en-tête zlib).
    static func inflate(_ src: Data, size: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: size)
        let n = src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
            guard let base = s.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&out, size, base, src.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 ? Array(out.prefix(n)) : nil
    }

    /// « TEXT », 0, nombre, puis (numéro, position) ; chaînes UTF-8 terminées par un zéro.
    static func texts(_ b: [UInt8]) -> [Int: String] {
        guard b.count > 12, b.prefix(4).elementsEqual("TEXT".utf8) else { return [:] }
        func u(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }
        let n = u(8)
        guard n > 0, 12 + n * 8 <= b.count else { return [:] }
        var out: [Int: String] = [:]
        for i in 0 ..< n {
            let id = u(12 + i * 8), off = u(16 + i * 8)
            guard off < b.count else { continue }
            let end = b[off...].firstIndex(of: 0) ?? b.count
            let s = String(decoding: b[off ..< end], as: UTF8.self).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !s.isEmpty { out[id] = s }
        }
        return out
    }
}
