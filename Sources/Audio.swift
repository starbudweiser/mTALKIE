// mTALKIE — écoute et export (WAV écrit à la main, AIFF et FLAC par AudioToolbox).
import AVFoundation
import Foundation

enum ExportFormat: String, CaseIterable, Identifiable {
    case wav, aiff, flac
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum WavWriter {
    /// WAV PCM : 8 bits non signé si la source est en 8 bits (restitution exacte), 16 bits signé sinon.
    static func data(_ pcm: PCM) -> Data {
        let bits = pcm.bits == 8 ? 8 : 16
        let bytesPerSample = bits / 8
        let dataSize = pcm.samples.count * bytesPerSample
        let rate = UInt32(pcm.rate.rounded())
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataSize)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(UInt16(pcm.channels)); u32(rate)
        u32(rate * UInt32(pcm.channels * bytesPerSample)); u16(UInt16(pcm.channels * bytesPerSample)); u16(UInt16(bits))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataSize))
        if bits == 8 {
            d.append(contentsOf: pcm.samples.map { UInt8(clamping: Int(($0 * 128 + 128).rounded())) })
        } else {
            for s in pcm.samples { u16(UInt16(bitPattern: Int16(clamping: Int((s * 32767).rounded())))) }
        }
        return d
    }
}

enum Encoder {
    static func write(_ pcm: PCM, to url: URL, format: ExportFormat) throws {
        switch format {
        case .wav:
            try WavWriter.data(pcm).write(to: url, options: .atomic)
        case .aiff, .flac:
            var settings: [String: Any] = [AVSampleRateKey: pcm.rate, AVNumberOfChannelsKey: pcm.channels]
            if format == .aiff {
                settings[AVFormatIDKey] = kAudioFormatLinearPCM
                settings[AVLinearPCMBitDepthKey] = 16
                settings[AVLinearPCMIsBigEndianKey] = true
                settings[AVLinearPCMIsFloatKey] = false
            } else {
                settings[AVFormatIDKey] = kAudioFormatFLAC
                settings[AVEncoderBitDepthHintKey] = 16
            }
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.rate, channels: AVAudioChannelCount(pcm.channels), interleaved: false),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(pcm.frames)) else { throw CocoaError(.fileWriteUnknown) }
            buf.frameLength = AVAudioFrameCount(pcm.frames)
            let ch = pcm.channels
            if let out = buf.floatChannelData {
                for c in 0 ..< ch { for i in 0 ..< pcm.frames { out[c][i] = pcm.samples[i * ch + c] } }
            }
            try file.write(from: buf)
        }
    }

    /// Nom de fichier d'après le modèle : {file} nom du fichier source, {n} numéro sur 4 chiffres, {offset} décalage hexadécimal,
    /// {text} début de la phrase prononcée (retiré, avec son séparateur, quand la réplique n'a pas de texte).
    static func name(pattern: String, source: URL, line: Line, format: ExportFormat) -> String {
        var s = pattern.isEmpty ? "{file}_{n}" : Pattern.canonical(pattern)
        s = s.replacingOccurrences(of: "{file}", with: source.deletingPathExtension().lastPathComponent)
        s = s.replacingOccurrences(of: "{n}", with: String(format: "%04d", line.id))
        s = s.replacingOccurrences(of: "{offset}", with: String(format: "%08X", line.offset))
        s = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        s = s.replacingOccurrences(of: "{text}", with: textPart(line.text))
        while let r = s.range(of: "__") { s.replaceSubrange(r, with: "_") }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "_- ."))
        if s.isEmpty { s = String(format: "%04d", line.id) }
        return s + "." + (format == .aiff ? "aif" : format.rawValue)
    }

    /// Phrase utilisable dans un nom de fichier : caractères interdits retirés, 60 caractères au plus, coupée entre deux mots.
    static func textPart(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var t = String(text.unicodeScalars.filter { !banned.contains($0) }).trimmingCharacters(in: .whitespaces)
        if t.count > 60 {
            t = String(t.prefix(60))
            if let sp = t.lastIndex(of: " "), t.distance(from: t.startIndex, to: sp) > 30 { t = String(t[..<sp]) }
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " .,;!-…"))
    }
}

/// Lecture d'une réplique (WAV en mémoire, AVAudioPlayer).
@MainActor
final class Player: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing: Int?        // numéro de la réplique en cours
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var peaks: [Float] = []
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func play(_ line: Line, pcm: PCM) {
        stop()
        guard let p = try? AVAudioPlayer(data: WavWriter.data(pcm)) else { return }
        p.delegate = self
        player = p
        duration = pcm.duration
        peaks = Peaks.compute(pcm, count: 240)
        playing = line.id
        p.play()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.position = self?.player?.currentTime ?? 0 }
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { p.pause() } else { p.play() }
        objectWillChange.send()
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    func seek(_ fraction: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(1, fraction)) * p.duration
        position = p.currentTime
    }

    func stop() {
        player?.stop(); player = nil
        timer?.invalidate(); timer = nil
        playing = nil; position = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.timer?.invalidate(); self.timer = nil
            self.position = self.duration
            self.objectWillChange.send()
        }
    }
}

enum Peaks {
    /// Crêtes (0…1) pour dessiner la forme d'onde.
    static func compute(_ pcm: PCM, count: Int) -> [Float] {
        let n = pcm.samples.count
        guard n > 0, count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        let step = max(1, n / count)
        for b in 0 ..< count {
            let lo = b * n / count, hi = min(n, lo + step)
            var m: Float = 0
            var i = lo
            while i < hi { m = max(m, abs(pcm.samples[i])); i += 1 }
            out[b] = min(1, m)
        }
        return out
    }
}

/// Balises du modèle de nom : forme interne {file} {n} {offset}, affichées dans la langue de l'interface.
enum Pattern {
    static let tokens: [String: [String]] = [
        "fr": ["{fichier}", "{n°}", "{décalage}", "{texte}"], "en": ["{file}", "{n}", "{offset}", "{text}"],
        "es": ["{archivo}", "{n.º}", "{posición}", "{texto}"], "it": ["{file}", "{n.}", "{posizione}", "{testo}"],
    ]
    static let canonicalTokens = ["{file}", "{n}", "{offset}", "{text}"]
    static var local: [String] { tokens[Loc.lang] ?? canonicalTokens }

    static func localize(_ s: String) -> String {
        var out = s
        for (c, l) in zip(canonicalTokens, local) { out = out.replacingOccurrences(of: c, with: l) }
        return out
    }

    /// Toutes les langues sont acceptées : un modèle tapé en français fonctionne aussi en anglais.
    static func canonical(_ s: String) -> String {
        var out = s
        for (_, list) in tokens { for (l, c) in zip(list, canonicalTokens) where l != c { out = out.replacingOccurrences(of: l, with: c) } }
        return out
    }
}
