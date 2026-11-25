// mTALKIE — jeux Unity de CrazyBunch : Leisure Suit Larry – Wet Dreams Don't Dry et Wet Dreams Dry Twice.
// Voix : StreamingAssets/localisation/englishvo (ou germanvo), archive « UnityFS » (blocs LZ4) : un fichier sérialisé
// (objets AudioClip : nom, puis source, position et taille dans le nœud « .resource ») et ce nœud, qui contient un son
// FMOD « FSB5 » par réplique, en Vorbis sans en-têtes : on reconstitue un vrai fichier Ogg (en-têtes d'identification,
// de commentaire et « setup », celui-ci repéré par son CRC32, puis les paquets avec leur position).
// Textes : StreamingAssets/databases (nom de la réplique → identifiant) et localisation/<langue> (identifiant → texte).
import Foundation
import Compression

enum Unity {
    // MARK: Archive UnityFS

    struct Bundle {
        let data: Data
        let blocks: [(packed: Int, size: Int, flags: Int, offset: Int, start: Int)]   // position compressée, position décompressée
        let nodes: [(name: String, offset: Int, size: Int)]

        func block(_ i: Int) -> [UInt8]? {
            let b = blocks[i]
            guard b.offset + b.packed <= data.count else { return nil }
            let raw = [UInt8](data[(data.startIndex + b.offset) ..< (data.startIndex + b.offset + b.packed)])
            switch b.flags & 0x3F {
            case 0: return raw
            case 2, 3: return Unity.lz4(raw, size: b.size)
            default: return nil                                         // LZMA : non pris en charge
            }
        }

        /// Octets [from, from+count) de l'espace décompressé.
        func read(_ from: Int, _ count: Int) -> [UInt8]? {
            var out: [UInt8] = []
            out.reserveCapacity(count)
            var lo = 0, hi = blocks.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if blocks[mid].start <= from { lo = mid } else { hi = mid - 1 } }
            var i = lo
            while out.count < count, i < blocks.count {
                guard let b = block(i) else { return nil }
                let skip = max(0, from + out.count - blocks[i].start)
                if skip < b.count { out += b[skip ..< min(b.count, skip + count - out.count)] }
                i += 1
            }
            return out.count == count ? out : nil
        }
    }

    static func lz4(_ src: [UInt8], size: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: size)
        let n = compression_decode_buffer(&out, size, src, src.count, nil, COMPRESSION_LZ4_RAW)
        return n == size ? out : nil
    }

    static func be32(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3]) }
    static func le32(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 | Int(b[p + 2]) << 16 | Int(b[p + 3]) << 24 }

    static func open(_ d: Data) throws -> Bundle {
        guard d.count > 64, d.prefix(8).elementsEqual("UnityFS\0".utf8) else { throw FormatError.notSoundBank }
        let head = [UInt8](d.prefix(256))
        var p = 8
        let version = be32(head, p); p += 4
        while head[p] != 0 { p += 1 }; p += 1                          // version du moteur (« 5.x.x »)
        while head[p] != 0 { p += 1 }; p += 1                          // version d'Unity (« 2017.4.29f1 »)
        p += 8                                                          // taille totale (64 bits)
        let packed = be32(head, p), size = be32(head, p + 4), flags = be32(head, p + 8); p += 12
        if version >= 7 { p = (p + 15) & ~15 }
        let atEnd = flags & 0x80 != 0
        let infoAt = atEnd ? d.count - packed : p
        guard infoAt + packed <= d.count else { throw FormatError.notSoundBank }
        var info = [UInt8](d[(d.startIndex + infoAt) ..< (d.startIndex + infoAt + packed)])
        if flags & 0x3F == 2 || flags & 0x3F == 3 { guard let u = lz4(info, size: size) else { throw FormatError.unsupportedCodec }; info = u }
        var q = 16
        let nb = be32(info, q); q += 4
        var blocks: [(Int, Int, Int, Int, Int)] = []
        var at = atEnd ? p : p + packed, start = 0
        for _ in 0 ..< nb {
            let u = be32(info, q), c = be32(info, q + 4), f = Int(info[q + 8]) << 8 | Int(info[q + 9]); q += 10
            blocks.append((c, u, f, at, start)); at += c; start += u
        }
        let nn = be32(info, q); q += 4
        var nodes: [(String, Int, Int)] = []
        for _ in 0 ..< nn {
            let off = be32(info, q + 4), sz = be32(info, q + 12); q += 20                   // 64 bits, partie haute nulle
            var e = q
            while e < info.count, info[e] != 0 { e += 1 }
            nodes.append((String(decoding: info[q ..< e], as: UTF8.self), off, sz)); q = e + 1
        }
        return Bundle(data: d, blocks: blocks.map { (packed: $0.0, size: $0.1, flags: $0.2, offset: $0.3, start: $0.4) },
                      nodes: nodes.map { (name: $0.0, offset: $0.1, size: $0.2) })
    }

    /// Le fichier sérialisé (premier nœud) décompressé.
    static func serialized(_ b: Bundle) -> [UInt8]? {
        guard let n = b.nodes.first(where: { !$0.name.contains(".") }) ?? b.nodes.first else { return nil }
        return b.read(n.offset, n.size)
    }

    // MARK: Voix

    static func isVoiceBundle(_ url: URL) -> Bool {
        url.pathExtension.isEmpty && url.lastPathComponent.lowercased().hasSuffix("vo") && url.deletingLastPathComponent().lastPathComponent == "localisation"
    }

    /// AudioClip : [nom] puis 8 champs de 4 octets puis [source « archive:/… »], position et taille (64 bits).
    static func parse(_ d: Data) throws -> (lines: [Line], bundle: Bundle) {
        let b = try open(d)
        guard let ser = serialized(b), let res = b.nodes.first(where: { $0.name.hasSuffix(".resource") || $0.name.hasSuffix(".resS") }) else {
            throw FormatError.notSoundBank
        }
        let key = Array("archive:/".utf8)
        var clips: [(String, Int, Int)] = []
        var i = 40
        while i + 9 < ser.count {
            guard ser[i] == key[0], Array(ser[i ..< i + 9]) == key else { i += 1; continue }
            let s = i - 4, srcLen = le32(ser, s)
            let after = (i + srcLen + 3) & ~3
            guard after + 16 <= ser.count else { break }
            let off = le32(ser, after), size = le32(ser, after + 8)
            for n in 1 ..< 200 {
                let a = s - 32 - ((n + 3) & ~3) - 4
                guard a >= 0 else { break }
                if le32(ser, a) == n {
                    clips.append((String(decoding: ser[(a + 4) ..< (a + 4 + n)], as: UTF8.self), res.offset + off, size))
                    break
                }
            }
            i = after + 16
        }
        guard !clips.isEmpty else { throw FormatError.empty }
        let lines = clips.sorted { $0.0.lowercased() < $1.0.lowercased() }.enumerated().map { k, c -> Line in
            var l = Line(id: k + 1, offset: k, start: c.1, length: c.2, rate: 0, duration: 0)
            l.name = speakerName(c.0)
            return l
        }
        return (lines, b)
    }

    /// Personnage d'après le nom : « Larry_dg_Standard_L33 » → Larry ; remarques sur les objets (hs_, inv_) → Larry.
    static func speakerName(_ clip: String) -> String {
        let low = clip.lowercased()
        if low.hasPrefix("hs_") || low.hasPrefix("inv_") { return "LARRY_" + clip }
        return clip
    }
    /// Nom d'origine de la réplique (sans le personnage ajouté).
    static func clipName(_ name: String) -> String {
        let low = name.lowercased()
        return low.hasPrefix("larry_hs_") || low.hasPrefix("larry_inv_") ? String(name.dropFirst(6)) : name
    }

    static func decode(_ b: Bundle, line: Line) throws -> PCM {
        guard let fsb = b.read(line.start, line.length), let ogg = oggFromFsb(fsb) else { throw FormatError.unsupportedCodec }
        return try CompressedDecoder.decode(Data(ogg), ext: "ogg")
    }

    // MARK: FSB5 → Ogg Vorbis

    static func oggFromFsb(_ f: [UInt8]) -> [UInt8]? {
        guard f.count > 0x40, f.prefix(4).elementsEqual("FSB5".utf8) else { return nil }
        let version = le32(f, 4), shs = le32(f, 12), nts = le32(f, 16), dts = le32(f, 20), mode = le32(f, 24)
        guard mode == 15 else { return nil }                              // 15 = Vorbis
        let hs = version == 1 ? 0x3C : 0x40
        guard hs + shs + nts + dts <= f.count, shs >= 8 else { return nil }
        let v = UInt64(le32(f, hs)) | UInt64(le32(f, hs + 4)) << 32
        var extra = v & 1 != 0
        let freqs = [1: 8000, 2: 11000, 3: 11025, 4: 16000, 5: 22050, 6: 24000, 7: 32000, 8: 44100, 9: 48000]
        var rate = freqs[Int((v >> 1) & 0xF)] ?? 44100
        let channels = Int((v >> 5) & 1) + 1
        let dataOffset = Int((v >> 7) & 0x7FF_FFFF) * 16
        var q = hs + 8
        var crc: UInt32?
        while extra, q + 4 <= hs + shs {
            let c = le32(f, q); q += 4
            extra = c & 1 != 0
            let size = (c >> 1) & 0xFF_FFFF, type = c >> 25
            if type == 11, q + 4 <= f.count { crc = UInt32(le32(f, q)) }
            if type == 2, q + 4 <= f.count { rate = le32(f, q) }
            q += size
        }
        guard let crc, let setup = FsbVorbisHeaders.data(crc) else { return nil }
        // En-tête d'identification (blocs de 256 et 2048) et de commentaire.
        var ident: [UInt8] = [1] + Array("vorbis".utf8) + [0, 0, 0, 0, UInt8(channels)]
        ident += [UInt8(rate & 255), UInt8((rate >> 8) & 255), UInt8((rate >> 16) & 255), UInt8(rate >> 24)]
        ident += [UInt8](repeating: 0, count: 12) + [0xB8, 1]
        let vendor = Array("mTALKIE".utf8)
        let comment: [UInt8] = [3] + Array("vorbis".utf8) + [UInt8(vendor.count), 0, 0, 0] + vendor + [0, 0, 0, 0, 1]
        var w = OggWriter()
        w.page([ident], granule: 0, flags: 2)
        w.page([comment, setup], granule: 0, flags: 0)
        var p = hs + shs + nts + dataOffset
        let end = hs + shs + nts + dts
        var granule: Int64 = 0, prev = 0
        var packets: [[UInt8]] = []
        while p + 2 <= end {
            let n = Int(f[p]) | Int(f[p + 1]) << 8; p += 2
            guard n > 0, p + n <= end else { break }
            packets.append(Array(f[p ..< p + n])); p += n
        }
        for (k, pk) in packets.enumerated() {
            let block = (pk[0] >> 1) & 1 == 1 ? 2048 : 256              // bit 0 : paquet audio ; bit 1 : mode (court / long)
            if prev > 0 { granule += Int64((block + prev) / 4) }
            prev = block
            w.page([pk], granule: granule, flags: k == packets.count - 1 ? 4 : 0)
        }
        return w.out
    }

    struct OggWriter {
        var out: [UInt8] = []
        var seq: UInt32 = 0
        static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
            var r = UInt32(i) << 24
            for _ in 0 ..< 8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
            return r
        }
        mutating func page(_ packets: [[UInt8]], granule: Int64, flags: UInt8) {
            var lacing: [UInt8] = []
            for pk in packets {
                var n = pk.count
                while n >= 255 { lacing.append(255); n -= 255 }
                lacing.append(UInt8(n))
            }
            var h: [UInt8] = Array("OggS".utf8) + [0, flags]
            let g = UInt64(bitPattern: granule)
            for k in 0 ..< 8 { h.append(UInt8((g >> (8 * UInt64(k))) & 255)) }
            h += [0x4D, 0x54, 0x4B, 0x31]                                  // numéro de flux
            for k in 0 ..< 4 { h.append(UInt8((seq >> (8 * UInt32(k))) & 255)) }
            h += [0, 0, 0, 0, UInt8(lacing.count)] + lacing
            var page = h
            for pk in packets { page += pk }
            var crc: UInt32 = 0
            for byte in page { crc = (crc << 8) ^ Self.table[Int(((crc >> 24) ^ UInt32(byte)) & 255)] }
            for k in 0 ..< 4 { page[22 + k] = UInt8((crc >> (8 * UInt32(k))) & 255) }
            out += page
            seq += 1
        }
    }

    // MARK: Textes

    /// « [n][nom][bourrage][36][identifiant] » dans la base du jeu → nom → identifiant.
    static func guids(_ b: [UInt8]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 4
        while i + 40 <= b.count {
            guard b[i] == 0x24, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 0, b[i + 12] == 0x2D, b[i + 17] == 0x2D else { i += 1; continue }
            let g = String(decoding: b[(i + 4) ..< (i + 40)], as: UTF8.self)
            for n in 3 ..< 120 {
                let s = i - ((n + 3) & ~3) - 4
                guard s >= 0 else { break }
                if le32(b, s) == n {
                    let name = b[(s + 4) ..< (s + 4 + n)]
                    if name.allSatisfy({ $0 > 32 && $0 < 127 }) {
                        let key = String(decoding: name, as: UTF8.self)
                        if out[key] == nil { out[key] = g }
                    }
                    break
                }
            }
            i += 40
        }
        return out
    }

    /// « [36][identifiant][n][texte] » dans une langue → identifiant → texte.
    static func subtitles(_ b: [UInt8]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i + 44 <= b.count {
            guard b[i] == 0x24, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 0, b[i + 12] == 0x2D, b[i + 17] == 0x2D else { i += 1; continue }
            let g = String(decoding: b[(i + 4) ..< (i + 40)], as: UTF8.self)
            let n = le32(b, i + 40)
            guard n > 0, n < 4000, i + 44 + n <= b.count else { i += 40; continue }
            let t = String(decoding: b[(i + 44) ..< (i + 44 + n)], as: UTF8.self).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if out[g] == nil, !t.isEmpty { out[g] = t }
            i += 44 + n
        }
        return out
    }

    static let languages = ["english": "en", "german": "de", "french": "fr", "italian": "it", "spanish": "es", "polish": "pl",
                            "russian": "ru", "chinesesimplified": "zh"]

    /// Langues : (code, nom de la réplique → texte), la langue des voix d'abord.
    static func textSets(near url: URL) -> [(String, [String: String])] {
        let loc = url.deletingLastPathComponent(), assets = loc.deletingLastPathComponent()
        guard let dbData = try? Data(contentsOf: assets.appendingPathComponent("databases"), options: .alwaysMapped),
              let db = try? open(dbData), let dbSer = serialized(db) else { return [] }
        let ids = guids(dbSer)
        var out: [(String, [String: String])] = []
        for (file, code) in languages {
            guard let d = try? Data(contentsOf: loc.appendingPathComponent(file), options: .alwaysMapped),
                  let b = try? open(d), let ser = serialized(b) else { continue }
            let subs = subtitles(ser)
            var t: [String: String] = [:]
            for (name, g) in ids { if let x = subs[g] { t[name] = x } }
            if !t.isEmpty { out.append((code, t)) }
        }
        let voice = url.lastPathComponent.lowercased().hasPrefix("german") ? "de" : "en"
        let order = [voice, "en", "de", "fr", "it", "es", "pl", "ru", "zh"]
        return out.sorted { (order.firstIndex(of: $0.0) ?? 99) < (order.firstIndex(of: $1.0) ?? 99) }
    }
}
