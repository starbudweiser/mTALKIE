// mTALKIE — lecture des fichiers de voix des jeux LucasArts SCUMM « talkie » : .SOU (suite de fichiers Creative Voice)
// et .SO3 / .SOG / .SOF (mêmes répliques compressées en MP3 / Ogg Vorbis / FLAC par les outils ScummVM).
// Aucun fichier d'origine n'est jamais modifié : lecture seule, mappée en mémoire.
import AVFoundation
import Foundation

/// Échantillons décodés d'une réplique : flottants entrelacés dans [-1, 1].
struct PCM {
    var rate: Double
    var channels: Int
    var samples: [Float]
    /// Profondeur d'origine (8 pour les VOC 8 bits) : un export WAV 8 bits la restitue sans aucune perte.
    var bits: Int
    var frames: Int { channels > 0 ? samples.count / channels : 0 }
    var duration: Double { rate > 0 ? Double(frames) / rate : 0 }
}

enum Codec: String { case voc, mp3, ogg, flac, xwb, bun, aud, lab, gg, sword1, aufs, queen }

/// Une réplique du fichier.
struct Line: Identifiable, Hashable {
    let id: Int              // numéro, à partir de 1, dans l'ordre du fichier
    let offset: Int          // position du bloc VCTL dans le .SOU d'origine : référence stable utilisée par les scripts du jeu et par ScummVM
    let start: Int           // début des données audio (fichier VOC ou flux compressé)
    let length: Int
    var rate: Double         // 0 tant qu'inconnu (formats compressés avant décodage)
    var duration: Double     // idem
    var supported = true     // false : codage VOC non pris en charge (ADPCM rare)
    var text = ""            // phrase prononcée, lue dans les scripts du jeu (vide si inconnue)
    var name = ""            // nom de la réplique (éditions spéciales : « GUY_4_shore_11_1 »)
}

enum FormatError: LocalizedError {
    case unreadable, notSoundBank, empty, unsupportedXwb, unsupportedCodec
    var errorDescription: String? {
        switch self {
        case .unsupportedXwb: return L("err.xwb")
        case .unsupportedCodec: return L("err.codec")
        case .unreadable: return L("err.unreadable")
        case .notSoundBank: return L("err.notsou")
        case .empty: return L("err.empty")
        }
    }
}

/// Fichier de voix ouvert.
final class SoundBank: @unchecked Sendable {
    let url: URL
    let data: Data
    let codec: Codec
    private(set) var lines: [Line] = []
    private var xact: [Xact.Entry] = []
    private var queenCompression = 2        // queen.1c : 1 MP3, 2 Ogg Vorbis, 3 FLAC     // .xwb : format de chaque son, dans l'ordre des répliques

    init(url requested: URL) throws {
        let url = GGPack.isPack(requested) ? GGPack.voicePack(for: requested) : requested     // Thimbleweed Park : voix dans ggpack2
        self.url = url
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { throw FormatError.unreadable }
        data = d
        switch Aufs.isSpeech(url) ? "aufs" : Queen.isQueen(url) ? "queen" : url.pathExtension.lowercased() {
        case "aufs": codec = .aufs
        case "queen": codec = .queen
        case "so3": codec = .mp3
        case "sog": codec = .ogg
        case "sof": codec = .flac
        case "xwb": codec = .xwb
        case "bun": codec = .bun
        case "aud": codec = .aud
        case "m4b": codec = .lab
        case let e where e.hasPrefix("ggpack"): codec = .gg
        case "clv", "clf", "cl3": codec = .sword1
        default: codec = .voc
        }
        switch codec {
        case .voc: try parseSou()
        case .xwb: try parseXwb()
        case .bun: lines = try BunArchive.parse(data)
        case .aud: lines = try Sierra.parse(data, url: url)
        case .lab: lines = try Grime.parse(data)
        case .gg: lines = try GGPack.parse(data)
        case .sword1: lines = try Sword1.parse(data)
        case .aufs: lines = try Aufs.parse(data, url: url)
        case .queen: lines = try Queen.parse(data); queenCompression = (try? Queen.table(data).compression) ?? 2
        default: try parseCompressed()
        }
        guard !lines.isEmpty else { throw FormatError.empty }
    }

    var totalDuration: Double { lines.reduce(0) { $0 + $1.duration } }
    var commonRate: Double? {
        var counts: [Double: Int] = [:]
        for l in lines where l.rate > 0 { counts[l.rate, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key
    }

    // MARK: .SOU

    private static let vocSig = Array("Creative Voice File\u{1a}".utf8)

    /// Découpe sur la signature « Creative Voice File\x1a ». Le bloc VCTL (synchro labiale) qui précède donne la référence.
    private func parseSou() throws {
        let sig = Self.vocSig
        var found: [Int] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var pos = 0
            let n = raw.count
            while pos < n, let hit = memmem(base + pos, n - pos, sig, sig.count) {
                let at = base.distance(to: UnsafeRawPointer(hit))
                found.append(at)
                pos = at + sig.count
            }
        }
        guard !found.isEmpty else {
            // Variante VTLK (démo et disquettes de Sam & Max) : bloc de 26 octets puis blocs VOC
            try parseVtlk()
            return
        }
        for (i, at) in found.enumerated() {
            let end = i + 1 < found.count ? found[i + 1] : data.count
            let ref = vctlOffset(before: at) ?? at
            var line = Line(id: i + 1, offset: ref, start: at, length: end - at, rate: 0, duration: 0)
            let info = VocDecoder.scan(data, start: at, end: end)
            line.rate = info.rate; line.duration = info.duration; line.supported = info.supported
            lines.append(line)
        }
    }

    /// Cherche « VCTL » ou « VTTL » juste avant la signature, dont la taille (big-endian, en-tête compris) aboutit à `at`.
    private func vctlOffset(before at: Int) -> Int? {
        let lo = max(0, at - 4096)
        var p = at - 8
        while p >= lo {
            let tag = data[data.startIndex + p ..< data.startIndex + p + 4]
            if tag.elementsEqual("VCTL".utf8) || tag.elementsEqual("VTTL".utf8) {
                let size = Int(be32(p + 4))
                return p + size == at ? p : nil
            }
            p -= 1
        }
        return nil
    }

    private func parseVtlk() throws {
        let tag = Array("VTLK".utf8)
        var starts: [Int] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var pos = 0
            while pos < raw.count, let hit = memmem(base + pos, raw.count - pos, tag, 4) {
                let at = base.distance(to: UnsafeRawPointer(hit)); starts.append(at); pos = at + 4
            }
        }
        guard !starts.isEmpty else { throw FormatError.notSoundBank }
        for (i, at) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : data.count
            let ref = vctlOffset(before: at) ?? at
            var line = Line(id: i + 1, offset: ref, start: at, length: end - at, rate: 0, duration: 0)
            let info = VocDecoder.scan(data, start: at, end: end, headerSize: 26)
            line.rate = info.rate; line.duration = info.duration; line.supported = info.supported
            lines.append(line)
        }
    }

    // MARK: .SO3 / .SOG / .SOF (compress_scumm_sou de scummvm-tools)
    // [taille de l'index, BE32] [index : 16 octets par réplique] [données]
    // entrée : position VCTL d'origine, position dans les données, octets de synchro labiale, taille compressée (BE32).
    private func parseCompressed() throws {
        guard data.count > 4 else { throw FormatError.notSoundBank }
        let idx = Int(be32(0))
        guard idx > 0, idx % 16 == 0, 4 + idx <= data.count else { throw FormatError.notSoundBank }
        let base = 4 + idx
        for i in 0 ..< idx / 16 {
            let e = 4 + i * 16
            let org = Int(be32(e)), newOff = Int(be32(e + 4)), tags = Int(be32(e + 8)), size = Int(be32(e + 12))
            let start = base + newOff + tags
            guard start >= base, size > 0, start + size <= data.count else { throw FormatError.notSoundBank }
            lines.append(Line(id: i + 1, offset: org, start: start, length: size, rate: 0, duration: 0))
        }
    }

    // MARK: .xwb (éditions spéciales)

    private func parseXwb() throws {
        let parsed = try Xact.parse(data)
        lines = parsed.map(\.0); xact = parsed.map(\.1)
        if let cues = Xact.cueFile(for: url) {
            let names = Xact.cueNames(cues)
            for i in lines.indices { lines[i].name = names[lines[i].offset] ?? "" }
        }
    }

    /// Codage dominant d'une banque .xwb (« MS ADPCM », « PCM 16 bits »…).
    var xwbFormat: String {
        guard let e = xact.first else { return "" }
        switch e.tag { case 0: return "PCM \(e.bits) bits"; case 1: return "XMA"; case 2: return "MS ADPCM"; default: return "xWMA" }
    }

    private func be32(_ p: Int) -> UInt32 {
        let s = data.startIndex + p
        return UInt32(data[s]) << 24 | UInt32(data[s + 1]) << 16 | UInt32(data[s + 2]) << 8 | UInt32(data[s + 3])
    }

    // MARK: Décodage

    func decode(_ line: Line) throws -> PCM {
        switch codec {
        case .voc:
            return try VocDecoder.decode(data, start: line.start, end: line.start + line.length,
                                         headerSize: data[data.startIndex + line.start] == UInt8(ascii: "V") ? 26 : nil)
        case .xwb:
            return try Xact.decode(data, line: line, entry: xact[line.id - 1])
        case .bun:
            return try BunArchive.decode(data, line: line)
        case .aud:
            return try Sierra.decode(data, line: line)
        case .lab:
            return try Grime.decode(data, line: line)
        case .gg:
            return try GGPack.decode(data, line: line)
        case .sword1:
            return try Sword1.decode(data, line: line, ext: Sword1.ext(url))
        case .aufs:
            return try Aufs.decode(data, line: line)
        case .queen:
            return try Queen.decode(data, line: line, compression: queenCompression)
        case .mp3, .ogg, .flac:
            return try CompressedDecoder.decode(data.subdata(in: data.startIndex + line.start ..< data.startIndex + line.start + line.length),
                                                ext: codec.rawValue)
        }
    }

    /// Complète durée et fréquence d'une réplique compressée (une fois décodée).
    func update(_ id: Int, rate: Double, duration: Double) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].rate = rate; lines[i].duration = duration
    }

    /// Jeu reconnu d'après les fichiers voisins.
    var gameName: String? { Self.game(for: url)?.name }

    /// Nom complet et nom court (liste des récents) du jeu d'après les fichiers voisins.
    static func game(for url: URL) -> (name: String, short: String)? {
        let shorts = ["Indiana Jones and the Fate of Atlantis": "Indy 4", "Day of the Tentacle": "DOTT", "Sam & Max Hit the Road": "Sam & Max",
                      "Monkey Island 2": "MI2", "The Secret of Monkey Island": "MI1", "Loom": "Loom",
                      "The Dig": "The Dig", "Full Throttle": "Full Throttle", "The Curse of Monkey Island": "MI3",
                      "Monkey Island 2: Special Edition": "MI2 SE", "Escape from Monkey Island": "EMI", "The Secret of Monkey Island: Special Edition": "MI1 SE",
                      "Thimbleweed Park": "TWP", "Broken Sword: The Shadow of the Templars": "BS1",
                      "Broken Sword: Shadow of the Templars – Reforged": "BS1 Reforged", "Broken Sword 2: Remastered": "BS2R",
                      "Flight of the Amazon Queen": "FOTAQ"]
        guard let n = gameFullName(url) else { return nil }
        return (n, shorts[n] ?? n)
    }

    private static func gameFullName(_ url: URL) -> String? {
        let dir = url.deletingLastPathComponent()
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.uppercased() })
        // Éditions spéciales : la banque de sons est dans « audio », le jeu (monkey2.pak) dans le dossier parent.
        let parent = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.deletingLastPathComponent().path)) ?? []).map { $0.uppercased() })
        if url.pathExtension.lowercased() == "aud", let n = Sierra.gameName(dir: dir) { return n }
        if GGPack.isPack(url) { return "Thimbleweed Park" }
        if Sword1.isSpeech(url) { return "Broken Sword: The Shadow of the Templars" }
        if Queen.isQueen(url) { return "Flight of the Amazon Queen" }
        if Aufs.isSpeech(url) { return Aufs.isReforged(url) ? "Broken Sword: Shadow of the Templars – Reforged" : "Broken Sword 2: Remastered" }
        if url.pathExtension.lowercased() == "m4b", Grime.isGame(names: names) { return "Escape from Monkey Island" }
        if url.pathExtension.lowercased() == "xwb" {
            if parent.contains("MONKEY2.PAK") || names.contains("MONKEY2.PAK") { return "Monkey Island 2: Special Edition" }
            if parent.contains("MONKEY1.PAK") || names.contains("MONKEY1.PAK") { return "The Secret of Monkey Island: Special Edition" }
        }
        let known: [(String, String)] = [("ATLANTIS.000", "Indiana Jones and the Fate of Atlantis"), ("TENTACLE.000", "Day of the Tentacle"),
                                         ("SAMNMAX.000", "Sam & Max Hit the Road"), ("SAMNMAX.SM0", "Sam & Max Hit the Road"),
                                         ("MONKEY2.000", "Monkey Island 2"), ("MONKEY.000", "The Secret of Monkey Island"),
                                         ("LOOM.000", "Loom"), ("MONKEY1.000", "The Secret of Monkey Island"),
                                         ("DIG.LA0", "The Dig"), ("FT.LA0", "Full Throttle"), ("COMI.LA0", "The Curse of Monkey Island")]
        return known.first { names.contains($0.0) }?.1
    }
}

// MARK: - Creative Voice (.VOC)

enum VocDecoder {
    struct Info { var rate: Double = 0; var duration: Double = 0; var supported = true }

    /// Fréquence d'un diviseur Creative : 1 000 000 / (256 − diviseur).
    static func rate(divisor: UInt8) -> Double { 1_000_000 / Double(256 - Int(divisor)) }

    /// Parcourt les blocs sans décoder, pour la durée et la fréquence.
    static func scan(_ d: Data, start: Int, end: Int, headerSize: Int? = nil) -> Info {
        var info = Info()
        var frames = 0.0
        walk(d, start: start, end: end, headerSize: headerSize) { block in
            switch block {
            case let .pcm(rate, bits, channels, codec, range):
                if info.rate == 0 { info.rate = rate }
                if codec != 0 && codec != 4 { info.supported = false }
                frames += Double(range.count) / Double(max(1, bits / 8) * channels)
            case let .silence(rate, count):
                if info.rate == 0 { info.rate = rate }
                frames += Double(count)
            }
        }
        if info.rate > 0 { info.duration = frames / info.rate }
        return info
    }

    static func decode(_ d: Data, start: Int, end: Int, headerSize: Int? = nil) throws -> PCM {
        var out = PCM(rate: 0, channels: 1, samples: [], bits: 8)
        var failed = false
        walk(d, start: start, end: end, headerSize: headerSize) { block in
            switch block {
            case let .pcm(rate, bits, channels, codec, range):
                if out.rate == 0 { out.rate = rate; out.channels = channels; out.bits = bits }
                if codec == 0 {          // 8 bits non signé
                    out.samples.reserveCapacity(out.samples.count + range.count)
                    for i in range { out.samples.append((Float(d[d.startIndex + i]) - 128) / 128) }
                } else if codec == 4 {   // 16 bits signé petit-boutiste
                    var i = range.lowerBound
                    while i + 1 < range.upperBound {
                        let v = Int16(bitPattern: UInt16(d[d.startIndex + i]) | UInt16(d[d.startIndex + i + 1]) << 8)
                        out.samples.append(Float(v) / 32768); i += 2
                    }
                } else { failed = true }
            case let .silence(rate, count):
                if out.rate == 0 { out.rate = rate }
                out.samples.append(contentsOf: repeatElement(0, count: count * out.channels))
            }
        }
        if failed { throw VocError.unsupported }
        guard out.rate > 0, !out.samples.isEmpty else { throw VocError.empty }
        return out
    }

    enum VocError: LocalizedError {
        case unsupported, empty
        var errorDescription: String? { self == .unsupported ? L("err.adpcm") : L("err.nosound") }
    }

    enum Block {
        case pcm(rate: Double, bits: Int, channels: Int, codec: Int, range: Range<Int>)
        case silence(rate: Double, count: Int)
    }

    /// Blocs : 1 données, 2 suite, 3 silence, 8 format étendu, 9 nouveau format, 0 fin ; les autres sont ignorés.
    static func walk(_ d: Data, start: Int, end: Int, headerSize: Int? = nil, _ visit: (Block) -> Void) {
        let s = d.startIndex
        func u8(_ p: Int) -> Int { Int(d[s + p]) }
        func le16(_ p: Int) -> Int { u8(p) | u8(p + 1) << 8 }
        func le24(_ p: Int) -> Int { u8(p) | u8(p + 1) << 8 | u8(p + 2) << 16 }
        func le32(_ p: Int) -> Int { le24(p) | u8(p + 3) << 24 }
        guard end - start > 26 else { return }
        var p = start + (headerSize ?? le16(start + 20))
        var last: (rate: Double, bits: Int, channels: Int, codec: Int)? = nil
        var extended: (rate: Double, channels: Int)? = nil
        while p < end {
            let type = u8(p)
            if type == 0 { break }
            guard p + 4 <= end else { break }
            let size = le24(p + 1)
            let body = p + 4
            let stop = min(end, body + size)
            switch type {
            case 1 where stop - body >= 2:
                var rate = rate(divisor: UInt8(u8(body)))
                var channels = 1
                if let e = extended { rate = e.rate; channels = e.channels; extended = nil }
                let codec = u8(body + 1)
                last = (rate, 8, channels, codec)
                visit(.pcm(rate: rate, bits: 8, channels: channels, codec: codec, range: body + 2 ..< stop))
            case 2:
                if let l = last { visit(.pcm(rate: l.rate, bits: l.bits, channels: l.channels, codec: l.codec, range: body ..< stop)) }
            case 3 where stop - body >= 3:
                visit(.silence(rate: rate(divisor: UInt8(u8(body + 2))), count: le16(body) + 1))
            case 8 where stop - body >= 4:
                let tc = le16(body)
                let channels = u8(body + 3) + 1
                extended = (256_000_000 / Double(65536 - tc) / Double(channels), channels)
            case 9 where stop - body >= 12:
                let r = Double(le32(body)), bits = u8(body + 4), ch = max(1, u8(body + 5)), fmt = le16(body + 6)
                let codec = (fmt == 0 && bits == 8) ? 0 : (fmt == 4 || bits == 16) ? 4 : fmt + 100
                last = (r, bits, ch, codec)
                visit(.pcm(rate: r, bits: bits, channels: ch, codec: codec, range: body + 12 ..< stop))
            default: break
            }
            p = body + size
        }
    }
}

// MARK: - MP3 / Ogg Vorbis / FLAC (décodeurs du système)

enum CompressedDecoder {
    static func decode(_ chunk: Data, ext: String) throws -> PCM {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mtalkie-\(UUID().uuidString).\(ext)")
        try chunk.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try AVAudioFile(forReading: tmp, commonFormat: .pcmFormatFloat32, interleaved: false)
        let fmt = file.processingFormat
        let cap = AVAudioFrameCount(max(1, file.length))
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { throw VocDecoder.VocError.empty }
        try file.read(into: buf)
        let ch = Int(fmt.channelCount), n = Int(buf.frameLength)
        var out = [Float](repeating: 0, count: n * ch)
        if let data = buf.floatChannelData {
            for c in 0 ..< ch { for i in 0 ..< n { out[i * ch + c] = data[c][i] } }
        }
        return PCM(rate: fmt.sampleRate, channels: ch, samples: out, bits: 16)
    }
}
