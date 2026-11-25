// mTALKIE — Star Trek: Judgment Rites (Interplay, CD) : image du CD (STJR1.dat / STJR2.dat, ISO 9660) ou fichiers .VCC.
// .VCC : « VOCFILES », taille des données (LE32), nombre (LE32), sons ACMP les uns après les autres, puis le sommaire
// à la fin (par son : nom sur 8, position et taille LE32).
// Textes : fichiers des épisodes (TREK2/*.DIR + *.001 + *.RUN, ressources compressées en LZSS) ; les scripts des salles
// (.RDF) contiennent « #MUS-2#About twenty-three hours… » : nom de la voix entre dièses puis le texte.
import Foundation

enum Trek {
    struct Entry { let name: String, offset: Int, size: Int }

    static func isImage(_ url: URL, _ d: Data) -> Bool {
        url.pathExtension.lowercased() == "dat" && d.count > 0x8010 && d[(d.startIndex + 0x8001) ..< (d.startIndex + 0x8006)].elementsEqual("CD001".utf8)
    }
    static func isVcc(_ url: URL) -> Bool { url.pathExtension.lowercased() == "vcc" }
    /// Image du CD de Star Trek (nom STJR*.dat) : à reconnaître avant de lire le fichier.
    static func looksLikeImage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "dat" && url.lastPathComponent.uppercased().hasPrefix("STJR")
    }

    static func le32(_ d: Data, _ p: Int) -> Int {
        let s = d.startIndex + p
        return Int(d[s]) | Int(d[s + 1]) << 8 | Int(d[s + 2]) << 16 | Int(d[s + 3]) << 24
    }

    /// Fichiers .VCC de l'image ISO 9660 (secteurs de 2048 octets) : nom, position et taille.
    static func isoFiles(_ d: Data) -> [Entry] {
        var out: [Entry] = []
        func walk(_ sector: Int, _ size: Int, _ path: String, depth: Int) {
            guard depth < 6 else { return }
            let start = sector * 2048, end = min(d.count, start + size)
            var o = start
            while o < end {
                let len = Int(d[d.startIndex + o])
                if len == 0 { o = (o / 2048 + 1) * 2048; continue }
                guard o + 33 < end else { break }
                let ext = le32(d, o + 2), sz = le32(d, o + 10), flags = d[d.startIndex + o + 25], nl = Int(d[d.startIndex + o + 32])
                let raw = d[(d.startIndex + o + 33) ..< (d.startIndex + o + 33 + nl)]
                let name = String(decoding: raw, as: UTF8.self).components(separatedBy: ";")[0]
                o += len
                if nl == 1, raw.first ?? 2 < 2 { continue }                  // « . » et « .. »
                if flags & 2 != 0 { walk(ext, sz, path + name + "/", depth: depth + 1) }
                else if ext * 2048 + sz <= d.count { out.append(Entry(name: path + name, offset: ext * 2048, size: sz)) }
            }
        }
        let pvd = 16 * 2048
        guard d.count > pvd + 190 else { return [] }
        walk(le32(d, pvd + 156 + 2), le32(d, pvd + 156 + 10), "/", depth: 0)
        return out
    }

    /// Sons d'un .VCC situé à `base` dans `d`.
    static func vccEntries(_ d: Data, base: Int, size: Int) -> [Entry] {
        guard size > 16, base + 16 <= d.count, d[(d.startIndex + base) ..< (d.startIndex + base + 8)].elementsEqual("VOCFILES".utf8) else { return [] }
        let dataSize = le32(d, base + 8), n = le32(d, base + 12)
        guard n > 0, n < 100_000, dataSize + n * 16 <= size, base + size <= d.count else { return [] }
        var out: [Entry] = []
        for i in 0 ..< n {
            let e = base + dataSize + i * 16
            let name = String(decoding: d[(d.startIndex + e) ..< (d.startIndex + e + 8)].prefix { $0 != 0 }, as: UTF8.self)
            let off = le32(d, e + 8), len = le32(d, e + 12)
            if len > 30, off + len <= size { out.append(Entry(name: name, offset: base + off, size: len)) }
        }
        return out
    }

    /// Répliques : `name` = nom de la voix (« MUS-2 »), `start` = position absolue dans le fichier ouvert.
    static func parse(_ d: Data, url: URL) throws -> [Line] {
        var entries: [Entry] = []
        if isVcc(url) {
            entries = vccEntries(d, base: 0, size: d.count)
        } else {
            for f in isoFiles(d) where f.name.uppercased().hasSuffix(".VCC") { entries += vccEntries(d, base: f.offset, size: f.size) }
        }
        guard !entries.isEmpty else { throw FormatError.notSoundBank }
        return entries.enumerated().map { i, e in
            var l = Line(id: i + 1, offset: i, start: e.offset, length: e.size, rate: 0, duration: 0)
            l.name = e.name
            return l
        }
    }

    static func decode(_ d: Data, line: Line) throws -> PCM {
        let b = [UInt8](d[(d.startIndex + line.start) ..< (d.startIndex + line.start + line.length)])
        guard AcmpDecoder.isAcmp(b) else { throw FormatError.unsupportedCodec }
        var dec = AcmpDecoder(b)
        let s = dec.decode()
        guard !s.isEmpty else { throw FormatError.unsupportedCodec }
        return PCM(rate: Double(AcmpDecoder.rate(b)), channels: 1, samples: s.map { (Float($0) - 128) / 128 }, bits: 8)
    }

    // MARK: Textes

    static func lzss(_ b: [UInt8], size: Int) -> [UInt8] {
        let n = 0x1000
        var hist = [UInt8](repeating: 0, count: n), out: [UInt8] = []
        out.reserveCapacity(size)
        var bp = 0, i = 0
        while i < b.count, out.count < size {
            let flags = b[i]; i += 1
            for k in 0 ..< 8 {
                guard i < b.count, out.count < size else { break }
                if flags & (1 << k) == 0 {
                    guard i + 1 < b.count else { i = b.count; break }
                    let ol = Int(b[i]) | Int(b[i + 1]) << 8; i += 2
                    let len = (ol & 15) + 3, off = (bp - (ol >> 4)) & (n - 1)
                    for j in 0 ..< len { let t = hist[(off + j) & (n - 1)]; out.append(t); hist[bp] = t; bp = (bp + 1) & (n - 1) }
                } else {
                    let t = b[i]; i += 1
                    out.append(t); hist[bp] = t; bp = (bp + 1) & (n - 1)
                }
            }
        }
        return out
    }

    /// Dossier des épisodes (TREK2) : à côté du fichier ouvert, ou dans le dossier parent.
    static func episodesDir(near url: URL) -> URL? {
        let dir = url.deletingLastPathComponent()
        for d in [dir.appendingPathComponent("TREK2"), dir, dir.deletingLastPathComponent().appendingPathComponent("TREK2")] {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: d.path), items.contains(where: { $0.uppercased().hasSuffix(".DIR") }) { return d }
        }
        return nil
    }

    /// « #NOM#texte\0 » dans toutes les ressources des épisodes.
    static func texts(near url: URL) -> [String: String] {
        guard let dir = episodesDir(near: url),
              let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [:] }
        var out: [String: String] = [:]
        for d in items where d.pathExtension.uppercased() == "DIR" {
            let base = d.deletingPathExtension()
            func sibling(_ ext: String) -> URL? { items.first { $0.deletingPathExtension().lastPathComponent == base.lastPathComponent && $0.pathExtension.uppercased() == ext } }
            guard let dirb = try? Data(contentsOf: d), let dataURL = sibling("001"), let data = try? Data(contentsOf: dataURL) else { continue }
            let run = sibling("RUN").flatMap { try? Data(contentsOf: $0) } ?? Data()
            for k in 0 ..< dirb.count / 14 {
                let e = k * 14
                let off = Int(dirb[e + 11]) | Int(dirb[e + 12]) << 8 | Int(dirb[e + 13]) << 16
                var offsets = [off]
                if off & (1 << 23) != 0 {                                      // plusieurs fichiers à la suite (.RUN)
                    let count = (off >> 16) & 0x7F, ro = off & 0xFFFF
                    guard count > 0, ro + 3 + (count - 1) * 2 <= run.count else { continue }
                    var o = Int(run[ro]) | Int(run[ro + 1]) << 8 | Int(run[ro + 2]) << 16     // position du premier, puis
                    offsets = []                                                                // les tailles des count − 1 premiers
                    for i in 0 ..< count {
                        offsets.append(o)
                        if i < count - 1 { o += Int(run[ro + 3 + 2 * i]) | Int(run[ro + 4 + 2 * i]) << 8 }
                    }
                }
                for o in offsets where o + 4 <= data.count {
                    let usz = Int(data[o]) | Int(data[o + 1]) << 8, csz = Int(data[o + 2]) | Int(data[o + 3]) << 8
                    guard o + 4 + csz <= data.count else { continue }
                    scan(lzss([UInt8](data[(o + 4) ..< (o + 4 + csz)]), size: usz), into: &out)
                }
            }
        }
        return out
    }

    private static let dos437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    static func scan(_ b: [UInt8], into out: inout [String: String]) {
        func isName(_ c: UInt8) -> Bool { (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || c == 0x2D }
        var i = 0
        while i < b.count - 4 {
            guard b[i] == 0x23 else { i += 1; continue }
            var j = i + 1
            while j < b.count, isName(b[j]), j - i <= 12 { j += 1 }
            guard j < b.count, b[j] == 0x23, j - i >= 3, b[(i + 1) ..< j].contains(0x2D) else { i += 1; continue }
            var e = j + 1
            while e < b.count, b[e] != 0, e - j < 600 { e += 1 }
            guard e < b.count, b[e] == 0, e > j + 1 else { i = j; continue }
            let name = String(decoding: b[(i + 1) ..< j], as: UTF8.self)
            if out[name] == nil, let t = String(bytes: b[(j + 1) ..< e], encoding: dos437) {
                let clean = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !clean.isEmpty { out[name] = clean }
            }
            i = e
        }
    }
}
