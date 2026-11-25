// mTALKIE — envoi vers mCASTING : voix à cloner (extrait de 15 à 25 s assemblé à partir de répliques choisies, texte de
// référence tiré des sous-titres) et répliques (texte, personnage, étiquettes, audio AAC) pour sa base de répliques.
// Les paquets sont déposés dans la boîte de réception de mCASTING (format mcasting-inbox/1, décrit dans son README) :
// écrits sous un nom caché puis renommés, ils ne sont jamais lus à moitié. Aucun fichier du jeu n'est modifié.
import AppKit
import AVFoundation
import Foundation

enum CastingLink {
    static let bundleID = "fr.stephan.mcasting"
    static let minClip = 15.0, maxClip = 25.0, gap = 0.3, clipRate = 24_000.0

    /// Dossier de données de mCASTING : l'édition de développement de mTALKIE écrit dans celle de mCASTING si elle existe.
    static var home: URL {
        if let p = ProcessInfo.processInfo.environment["MCASTING_HOME"] { return URL(fileURLWithPath: p) }   // essais
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        if (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev"), FileManager.default.fileExists(atPath: base.appendingPathComponent("mCASTING-dev").path) {
            return base.appendingPathComponent("mCASTING-dev")
        }
        return base.appendingPathComponent("mCASTING")
    }
    static var inbox: URL { home.appendingPathComponent("Inbox") }
    /// mCASTING est-il présent (appli installée ou dossier de données déjà créé) ?
    static var available: Bool {
        FileManager.default.fileExists(atPath: home.path) || NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    // MARK: personnages
    /// Préfixe d'une réplique nommée : « GUY_4_shore_11_1 » → « guy », « clatri001 » → « cla ».
    static func prefix(_ name: String) -> String {
        guard !name.isEmpty else { return "" }
        if let u = name.firstIndex(of: "_") { return String(name[..<u]).lowercased() }
        // Curse of Monkey Island : « B2GT301 » = scène B2, personnage GT (Guybrush), réplique 301.
        if name.range(of: #"^[A-Z0-9]{2}[A-Z]{2}[0-9]{3,4}$"#, options: .regularExpression) != nil {
            return String(Array(name)[2 ..< 4]).lowercased()
        }
        return String(name.prefix { $0.isLetter }.prefix(3)).lowercased()
    }
    /// Personnages connus d'après les préfixes des éditions spéciales de Monkey Island ; les autres se nomment à la main.
    static let knownSpeakers: [String: String] = [
        "guy": "Guybrush", "lch": "LeChuck", "lec": "LeChuck", "ela": "Elaine", "el1": "Elaine", "wal": "Wally", "mur": "Murray",
        "stn": "Stan", "sta": "Stan", "lrg": "Largo", "oti": "Otis", "car": "Carla", "mea": "Meathook", "kat": "Kate Capsize",
        "rum": "Rum Rogers", "ozz": "Ozzie Mandrill", "cha": "Charles L. Charles",
        "ray": "Agent Ray", "reyes": "Agent Reyes", "delores": "Delores", "ransome": "Ransome", "franklin": "Franklin",
        "gt": "Guybrush", "lc": "LeChuck", "mr": "Murray", "wy": "Wally", "kn": "Kenny Falmouth", "hm": "Haggis McMutton",
    ]
    /// Noms donnés par l'utilisateur, par jeu (préfixe → personnage), retenus d'un envoi à l'autre.
    static func speakers(game: String) -> [String: String] {
        let saved = (UserDefaults.standard.dictionary(forKey: "speakers." + game) as? [String: String]) ?? [:]
        return knownSpeakers.merging(saved) { _, b in b }
    }
    static func saveSpeakers(_ map: [String: String], game: String) {
        UserDefaults.standard.set(map.filter { knownSpeakers[$0.key] != $0.value }, forKey: "speakers." + game)
    }

    // MARK: étiquettes automatiques (d'après le texte)
    static func tags(_ text: String) -> [String] {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        var out: [String] = []
        let words = Set(t.split { !$0.isLetter && $0 != "'" }.map(String.init))
        if t.range(of: #"\b(ha){2,}|\b(he){2,}|\b(hi){2,}|\bmwa|\bbwa|\blol\b"#, options: .regularExpression) != nil { out.append("laugh") }
        let letters = t.filter(\.isLetter)
        if letters.count <= 12, t.contains("!"), letters.count >= 1,
           t.range(of: #"^(a+h+|o+h+|a+r+g+h*|a+i+e+|ouch|ouille|aï+e|yaa+h?|no+!|n+o+n+|wa+h|e+e+k|ugh|ayy+)"#, options: .regularExpression) != nil { out.append("scream") }
        let insults = ["idiot", "fool", "stupid", "moron", "coward", "cow", "dog", "worm", "imbécile", "idiote", "crétin", "abruti", "lâche",
                       "imbecil", "estúpido", "cobarde", "stupido", "codardo", "scemo"]
        if !words.isDisjoint(with: insults) || t.contains("you fight like") || t.contains("tu te bats comme") { out.append("insult") }
        let greet = ["hello", "hi", "hey", "greetings", "howdy", "bonjour", "salut", "bonsoir", "hola", "buenas", "ciao", "salve", "buongiorno"]
        if let first = t.split(whereSeparator: { !$0.isLetter }).first, greet.contains(String(first)) { out.append("greeting") }
        if t.hasSuffix("?") || t.contains("? ") { out.append("question") }
        let threat = ["kill", "die", "destroy", "revenge", "doom", "tuer", "mourir", "détruire", "vengeance", "matar", "morir", "venganza", "uccidere", "morire", "vendetta"]
        if !words.isDisjoint(with: threat) { out.append("threat") }
        if t.hasSuffix("!") && !out.contains("scream") { out.append("exclamation") }
        return out
    }

    // MARK: audio
    /// Convertit en mono à `rate` Hz (flottants).
    static func mono(_ pcm: PCM, rate: Double) throws -> [Float] {
        let ch = max(1, pcm.channels), frames = pcm.frames
        var m = [Float](repeating: 0, count: frames)
        for i in 0 ..< frames { var s: Float = 0; for c in 0 ..< ch { s += pcm.samples[i * ch + c] }; m[i] = s / Float(ch) }
        if abs(pcm.rate - rate) < 0.5 { return m }
        guard let inF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: pcm.rate, channels: 1, interleaved: false),
              let outF = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inF, to: outF),
              let inB = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(max(frames, 1))) else { throw CocoaError(.fileWriteUnknown) }
        inB.frameLength = AVAudioFrameCount(frames)
        m.withUnsafeBufferPointer { src in inB.floatChannelData![0].update(from: src.baseAddress!, count: frames) }
        let cap = AVAudioFrameCount(Double(frames) * rate / pcm.rate + 1024)
        guard let outB = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { throw CocoaError(.fileWriteUnknown) }
        var fed = false
        var error: NSError?
        _ = conv.convert(to: outB, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return inB
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: outB.floatChannelData![0], count: Int(outB.frameLength)))
    }

    /// Extrait de clonage : répliques choisies (dans l'ordre), mises au même volume, séparées par 0,3 s de silence,
    /// coupées à 25 s ; renvoie l'audio (mono 24 kHz), le texte de référence et les répliques gardées.
    static func assemble(_ bank: SoundBank, _ lines: [Line]) throws -> (pcm: PCM, text: String, used: [Line]) {
        var out: [Float] = [], used: [Line] = [], texts: [String] = []
        let silence = [Float](repeating: 0, count: Int(gap * clipRate))
        for l in lines {
            var m = try mono(bank.decode(l), rate: clipRate)
            let peak = m.reduce(0) { max($0, abs($1)) }
            if peak > 0.001 { let k = 0.89 / peak; for i in m.indices { m[i] *= k } }      // −1 dBFS
            let add = (out.isEmpty ? 0 : silence.count) + m.count
            if !out.isEmpty, Double(out.count + add) / clipRate > maxClip { break }
            if !out.isEmpty { out += silence }
            out += m; used.append(l)
            if !l.text.isEmpty { texts.append(l.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if Double(out.count) / clipRate >= maxClip { break }
        }
        if Double(out.count) / clipRate > maxClip { out = Array(out.prefix(Int(maxClip * clipRate))) }
        return (PCM(rate: clipRate, channels: 1, samples: out, bits: 16), texts.joined(separator: " "), used)
    }

    /// Durée estimée de l'extrait (avant décodage).
    static func clipDuration(_ lines: [Line]) -> Double {
        var t = 0.0
        for l in lines { let a = (t > 0 ? gap : 0) + l.duration; if t > 0, t + a > maxClip { break }; t += a; if t >= maxClip { break } }
        return min(t, maxClip)
    }

    /// AAC mono 22,05 kHz, 32 kb/s en flux ADTS (.aac) : pas les 16 à 32 Ko de réserve d’un .m4a ou d’un .caf, ≈ 4 Ko/s.
    static func writeAAC(_ pcm: PCM, to url: URL) throws {
        let rate = 22_050.0
        var m = try mono(pcm, rate: rate)
        guard !m.isEmpty else { return }
        var dst = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                              mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var src = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var ref: ExtAudioFileRef?
        var st = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType, &dst, nil,
                                           AudioFileFlags.eraseFile.rawValue | AudioFileFlags.dontPageAlignAudioData.rawValue, &ref)
        guard st == noErr, let f = ref else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        defer { ExtAudioFileDispose(f) }
        st = ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &src)
        if st == noErr, let conv = { () -> AudioConverterRef? in
            var c: AudioConverterRef?; var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
            return ExtAudioFileGetProperty(f, kExtAudioFileProperty_AudioConverter, &size, &c) == noErr ? c : nil
        }() {
            var br: UInt32 = 32_000
            AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &br)
            var null: CFArray? = nil
            ExtAudioFileSetProperty(f, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFArray?>.size), &null)
        }
        guard st == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        let frames = UInt32(m.count)
        st = m.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return ExtAudioFileWrite(f, frames, &list)
        }
        guard st == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }
    static let aacBytesPerSecond = 4_200.0

    // MARK: paquets
    struct Source: Encodable { var kind = "game"; var title: String; var id: String }
    struct VoicePart: Encodable { var name, lang, audio, text: String; var gender: String?; var description: String?; var character: String? }
    struct LinePart: Encodable {
        var key: String; var text: String; var character: String?; var lang: String?
        var duration: Double; var tags: [String]?; var audio: String?
    }
    struct Manifest: Encodable {
        var format = "mcasting-inbox/1"; var kind: String
        var origin: [String: String]; var source: Source
        var voice: VoicePart? = nil; var lines: [LinePart]? = nil
    }
    static var origin: [String: String] { ["app": "mTALKIE", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"] }

    /// Identifiant de source stable : nom court du jeu, sinon nom du fichier.
    static func sourceID(_ bank: SoundBank) -> String {
        let base = SoundBank.game(for: bank.url)?.short ?? bank.url.deletingPathExtension().lastPathComponent
        return base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
    }
    static func sourceTitle(_ bank: SoundBank) -> String { bank.gameName ?? bank.url.deletingPathExtension().lastPathComponent }

    /// Crée un paquet caché, le remplit puis le publie (renommage atomique).
    static func publish(_ name: String, fill: (URL) throws -> Manifest) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let tmp = inbox.appendingPathComponent(".\(name)-\(stamp).tmp")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        do {
            let m = try fill(tmp)
            let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try e.encode(m).write(to: tmp.appendingPathComponent("manifest.json"))
            try fm.moveItem(at: tmp, to: inbox.appendingPathComponent("\(name)-\(stamp)"))
        } catch { try? fm.removeItem(at: tmp); throw error }
    }

    static func sendVoice(_ bank: SoundBank, lines: [Line], name: String, lang: String, gender: String, description: String, character: String = "") throws {
        let a = try assemble(bank, lines)
        try publish("voice") { dir in
            try WavWriter.data(a.pcm).write(to: dir.appendingPathComponent("voice.wav"))
            return Manifest(kind: "voice", origin: origin, source: Source(title: sourceTitle(bank), id: sourceID(bank)),
                            voice: VoicePart(name: name, lang: lang, audio: "voice.wav", text: a.text, gender: gender,
                                             description: description.isEmpty ? nil : description, character: character.isEmpty ? nil : character))
        }
    }

    /// Envoie des répliques ; `progress` reçoit le nombre traité. Les répliques sans texte ni audio sont ignorées.
    static func sendLines(_ bank: SoundBank, lines: [Line], lang: String, speakers: [String: String], audio: Bool, autoTags: Bool,
                          cancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (Int) -> Void) throws -> Int {
        let todo = lines.filter { !$0.text.isEmpty || audio }
        var parts = [LinePart?](repeating: nil, count: todo.count)
        try publish("lines") { dir in
            if audio { try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio"), withIntermediateDirectories: true) }
            let box = PartsBox(count: todo.count)
            let group = DispatchGroup(), queue = DispatchQueue(label: "mtalkie.casting", attributes: .concurrent)
            let sem = DispatchSemaphore(value: 4)
            let counter = Counter()
            for (i, l) in todo.enumerated() {
                if cancelled() { break }
                sem.wait(); group.enter()
                queue.async {
                    defer { sem.signal(); group.leave() }
                    let key = l.name.isEmpty ? String(format: "%05d", l.id) : l.name
                    var dur = l.duration, file: String?
                    if audio, let pcm = try? bank.decode(l) {
                        dur = pcm.duration
                        let rel = "audio/" + key.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" }.reduce(into: "") { $0.append($1) } + ".aac"
                        if (try? writeAAC(pcm, to: dir.appendingPathComponent(rel))) != nil { file = rel }
                    }
                    let sp = speakers[prefix(l.name)].flatMap { $0.isEmpty ? nil : $0 }
                    let tg = autoTags ? tags(l.text) : []
                    box.set(i, LinePart(key: key, text: l.text, character: sp, lang: lang.isEmpty ? nil : lang, duration: (dur * 100).rounded() / 100,
                                        tags: tg.isEmpty ? nil : tg, audio: file))
                    progress(counter.next())
                }
            }
            group.wait()
            if cancelled() { throw CancellationError() }
            parts = box.parts
            return Manifest(kind: "lines", origin: origin, source: Source(title: sourceTitle(bank), id: sourceID(bank)), lines: parts.compactMap { $0 })
        }
        return parts.compactMap { $0 }.count
    }

    final class PartsBox: @unchecked Sendable {
        private let lock = NSLock(); var parts: [LinePart?]
        init(count: Int) { parts = .init(repeating: nil, count: count) }
        func set(_ i: Int, _ p: LinePart) { lock.lock(); parts[i] = p; lock.unlock() }
    }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }
}

