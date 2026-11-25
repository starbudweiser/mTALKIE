// mTALKIE — tests du moteur (lancer tests/run_tests.sh).
// 1. Faux MONSTER.SOU construit à partir de VOC de synthèse : découpe, références VCTL, durées, WAV 8 bits octet par octet.
// 2. Mêmes répliques en .SO3 / .SOG / .SOF (mise en page de compress_scumm_sou, encodage ffmpeg) : index et décodage.
// 3. Vrai MONSTER.SOU s'il est présent (chemin en argument) : nombre de répliques, décodage et export de toutes.
// 4. Tables de traduction : mêmes clés dans les 4 langues.
import AVFoundation
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: String) { print(ok ? "  ✓ \(msg)" : "  ✗ \(msg)"); if !ok { failures += 1 } }

let work = FileManager.default.temporaryDirectory.appendingPathComponent("mtalkie-tests-\(getpid())")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
func le(_ v: Int, _ n: Int) -> [UInt8] { (0 ..< n).map { UInt8(v >> (8 * $0) & 255) } }

/// VOC : en-tête 26 octets, bloc 1 (diviseur, codec 0), éventuellement bloc 3 (silence) et bloc 2 (suite), bloc 0.
func makeVoc(samples: [UInt8], divisor: UInt8, silence: Int = 0, split: Bool = false) -> [UInt8] {
    var v = Array("Creative Voice File\u{1a}".utf8) + le(26, 2) + le(0x010A, 2) + le(0x1129, 2)
    let a = split ? Array(samples[..<(samples.count / 2)]) : samples
    v += [1] + le(a.count + 2, 3) + [divisor, 0] + a
    if silence > 0 { v += [3] + le(3, 3) + le(silence - 1, 2) + [divisor] }
    if split { let b = Array(samples[(samples.count / 2)...]); v += [2] + le(b.count, 3) + b }
    return v + [0]
}

func tone(_ n: Int, freq: Double, rate: Double) -> [UInt8] {
    (0 ..< n).map { UInt8(clamping: Int(128 + 90 * sin(2 * .pi * freq * Double($0) / rate))) }
}

// MARK: 1. SOU de synthèse
print("1. MONSTER.SOU de synthèse")
let specs: [(Int, UInt8, Int, Bool)] = [(11111, 166, 0, false), (5555, 166, 1000, false), (22222, 211, 0, true), (800, 166, 0, false)]
var sou = Array("SOU ".utf8) + [0, 0, 0, 0]
var expected: [(offset: Int, samples: [UInt8], rate: Double, frames: Int)] = []
for (i, s) in specs.enumerated() {
    let rate = VocDecoder.rate(divisor: s.1)
    let smp = tone(s.0, freq: 220 + Double(i) * 110, rate: rate)
    let tags = (0 ..< 3 + i).flatMap { be32($0 * 7)[2...] }        // synchro labiale : uint16 BE
    let off = sou.count
    sou += Array("VCTL".utf8) + be32(8 + tags.count) + tags
    sou += makeVoc(samples: smp, divisor: s.1, silence: s.2, split: s.3)
    expected.append((off, smp, rate, s.0 + s.2))
}
let souURL = work.appendingPathComponent("MONSTER.SOU")
try Data(sou).write(to: souURL)
let bank = try SoundBank(url: souURL)
check(bank.lines.count == specs.count, "\(bank.lines.count) répliques trouvées (attendu \(specs.count))")
for (l, e) in zip(bank.lines, expected) {
    check(l.offset == e.offset, "réplique \(l.id) : référence VCTL 0x\(String(l.offset, radix: 16)) = 0x\(String(e.offset, radix: 16))")
    check(abs(l.rate - e.rate) < 0.01, "réplique \(l.id) : fréquence \(Int(l.rate)) Hz")
    check(abs(l.duration - Double(e.frames) / e.rate) < 1e-6, "réplique \(l.id) : durée \(String(format: "%.3f", l.duration)) s")
    let pcm = try bank.decode(l)
    let wav = WavWriter.data(pcm)
    let body = Array(wav[44...])
    let ref = e.samples + (l.id == 2 ? [UInt8](repeating: 128, count: 1000) : [])
    check(body == ref && wav.count == 44 + ref.count, "réplique \(l.id) : WAV 8 bits identique aux échantillons d'origine (\(ref.count) octets)")
}
for fmt in [ExportFormat.aiff, .flac] {
    let url = work.appendingPathComponent("t.\(fmt == .aiff ? "aif" : "flac")")
    do { try Encoder.write(try bank.decode(bank.lines[0]), to: url, format: fmt)
        let back = try CompressedDecoder.decode(Data(contentsOf: url), ext: fmt == .aiff ? "aif" : "flac")
        check(back.frames == expected[0].frames && abs(back.rate - expected[0].rate) < 1, "export \(fmt.label) relu : \(back.frames) échantillons à \(Int(back.rate)) Hz")
    } catch { check(false, "export \(fmt.label) : \(error)") }
}
check(Encoder.name(pattern: "{file}_{n}_{offset}", source: souURL, line: bank.lines[1], format: .wav) == String(format: "MONSTER_0002_%08X.wav", expected[1].offset), "modèle de nom de fichier")

// MARK: 2. Formats compressés (mise en page compress_scumm_sou)
print("2. .SO3 / .SOG / .SOF")
func ffmpeg(_ input: URL, _ output: URL, _ args: [String]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    p.arguments = ["-loglevel", "error", "-y", "-i", input.path] + args + [output.path]
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}
if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
    for (ext, args, codec) in [("so3", ["-c:a", "libmp3lame", "-b:a", "64k", "-ar", "22050"], "mp3"),
                               ("sog", ["-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-ar", "22050"], "ogg"),
                               ("sof", ["-c:a", "flac", "-ar", "22050"], "flac")] {
        var index: [UInt8] = [], snd: [UInt8] = []
        for (i, l) in bank.lines.enumerated() {
            let wav = work.appendingPathComponent("in\(i).wav"), enc = work.appendingPathComponent("out\(i).\(codec)")
            try WavWriter.data(try bank.decode(l)).write(to: wav)
            guard ffmpeg(wav, enc, args) else { check(false, "ffmpeg \(codec)"); break }
            let audio = [UInt8](try Data(contentsOf: enc))
            let tags = [UInt8](repeating: 0x11, count: 6 + 2 * i)
            index += be32(l.offset) + be32(snd.count) + be32(tags.count) + be32(audio.count)
            snd += tags + audio
        }
        let url = work.appendingPathComponent("MONSTER.\(ext.uppercased())")
        try Data(be32(index.count) + index + snd).write(to: url)
        do {
            let b = try SoundBank(url: url)
            check(b.lines.count == bank.lines.count, ".\(ext.uppercased()) : \(b.lines.count) répliques dans l'index")
            check(zip(b.lines, bank.lines).allSatisfy { $0.offset == $1.offset }, ".\(ext.uppercased()) : références VCTL conservées")
            var ok = true
            for (l, o) in zip(b.lines, bank.lines) {
                let p = try b.decode(l)
                if abs(p.duration - o.duration) > 0.08 { ok = false; print("    réplique \(l.id) : \(p.duration) s au lieu de \(o.duration)") }
            }
            check(ok, ".\(ext.uppercased()) : toutes les répliques décodées, durées à ±80 ms près")
        } catch { check(false, ".\(ext.uppercased()) : \(error)") }
    }
} else { print("  (ffmpeg absent : formats compressés non testés)") }

// MARK: 3. Vrai fichier
if CommandLine.arguments.count > 1 {
    let real = URL(fileURLWithPath: CommandLine.arguments[1])
    print("3. Fichier réel : \(real.path)")
    let t0 = Date()
    do {
        let b = try SoundBank(url: real)
        print(String(format: "    ouverture : %.2f s, %d répliques, %.0f min, %@", Date().timeIntervalSince(t0), b.lines.count, b.totalDuration / 60, b.gameName ?? "jeu non reconnu"))
        check(b.lines.count > 0, "répliques trouvées")
        check(b.lines.allSatisfy { $0.offset < $0.start }, "chaque réplique a sa référence VCTL")
        let t1 = Date(); var bad = 0
        for l in b.lines { do { _ = WavWriter.data(try b.decode(l)) } catch { bad += 1 } }
        print(String(format: "    décodage + WAV de toutes les répliques : %.2f s", Date().timeIntervalSince(t1)))
        check(bad == 0, "\(b.lines.count - bad) répliques décodées sans erreur (\(bad) en échec)")
        let out = work.appendingPathComponent("real.wav")
        try WavWriter.data(try b.decode(b.lines[0])).write(to: out)
        let back = try CompressedDecoder.decode(Data(contentsOf: out), ext: "wav")
        check(abs(back.duration - b.lines[0].duration) < 0.001, "le WAV exporté se relit avec le décodeur du système (\(String(format: "%.2f", back.duration)) s)")
    } catch { check(false, "\(error)") }
}

// MARK: 3 bis. Textes des répliques (scripts du jeu)
print("3 bis. Textes")
do {
    func code(_ a: Int) -> [UInt8] { [0xFF, 0x0A, UInt8(a & 255), UInt8(a >> 8 & 255), 0xFF, 0x0A, UInt8(a >> 16 & 255), UInt8(a >> 24 & 255), 0xFF, 0x0A, 0, 0, 0xFF, 0x0A, 0, 0] }
    let o1 = bank.lines[0].offset, o2 = bank.lines[1].offset
    var plain: [UInt8] = [1, 2, 3, 0x14, 0x00]
    plain += code(o1) + Array("Voil".utf8) + [0x85] + Array("  un\u{10}idol".utf8) + [0xFF, 0x03] + Array("e^ ^ok^".utf8) + [0]
    plain += [7, 7] + code(o2) + Array("Deux".utf8) + [0xFF, 0x0A] + Array("ignoré".utf8) + [0]
    plain += code(0x7FFFFF) + Array("hors fichier".utf8) + [0]
    let script = work.appendingPathComponent("ATLANTIS.001")
    try Data(plain.map { $0 ^ 0x69 }).write(to: script)
    check(ScriptTexts.find(near: souURL)?.lastPathComponent == script.lastPathComponent, "fichier de scripts trouvé à côté des voix")
    let st = try ScriptTexts.load(script, offsets: Set(bank.lines.map(\.offset)))
    check(st.texts[o1] == "Voilà un idol e… ok…", "texte décodé (DOS 437, codes SCUMM retirés) : \(st.texts[o1] ?? "—")")
    check(st.texts[o2] == "Deux" && st.texts.count == 2, "texte arrêté au code suivant, position inconnue ignorée")
    var l = bank.lines[0]; l.text = "I'm: a/very \"long\" line, that goes on and on, far beyond sixty characters for sure."
    let n = Encoder.name(pattern: "{n°}_{texte}", source: souURL, line: l, format: .wav)
    check(n == "0001_I'm avery long line, that goes on and on, far beyond sixty.wav", "balise {texte} : \(n)")
    l.text = ""
    check(Encoder.name(pattern: "{n}_{text}_{offset}", source: souURL, line: l, format: .flac) == String(format: "0001_%08X.flac", l.offset), "réplique sans texte : séparateur retiré")
    try? FileManager.default.removeItem(at: script)
} catch { check(false, "textes : \(error)") }
if CommandLine.arguments.count > 1 {
    let real = URL(fileURLWithPath: CommandLine.arguments[1])
    if let b = try? SoundBank(url: real), let sc = ScriptTexts.find(near: real) {
        let t0 = Date()
        do {
            let st = try ScriptTexts.load(sc, offsets: Set(b.lines.map(\.offset)))
            print(String(format: "    %@ : %d textes sur %d répliques en %.2f s, langue %@", sc.lastPathComponent, st.texts.count, b.lines.count, Date().timeIntervalSince(t0), st.language ?? "?"))
            check(st.texts.count * 10 > b.lines.count * 9, "plus de 90 % des répliques ont leur texte")
            print("    ex. : « \(st.texts[b.lines[0].offset] ?? "—") »")
        } catch { check(false, "textes du vrai jeu : \(error)") }
    }
}

// MARK: 3 ter. Édition spéciale (banque XACT .xwb)
let seURL = URL(fileURLWithPath: "/Volumes/SAMSUNG T7/JEUX/SCUMMVM/Monkey Island 2 SE/audio/Speech.xwb")
if FileManager.default.fileExists(atPath: seURL.path) {
    print("3 ter. Édition spéciale : \(seURL.path)")
    do {
        let t0 = Date()
        let b = try SoundBank(url: seURL)
        print(String(format: "    ouverture : %.2f s, %d répliques, %.0f min, %@ (%@)", Date().timeIntervalSince(t0), b.lines.count, b.totalDuration / 60, b.gameName ?? "?", b.xwbFormat))
        check(b.lines.count == 7157 && b.gameName == "Monkey Island 2: Special Edition", "banque lue, jeu reconnu")
        check(b.lines[0].name == "POT_55_entryway_17_1" && b.lines.filter { $0.name.isEmpty }.isEmpty, "chaque son a son nom (.xsb)")
        let pcm = try b.decode(b.lines[0])
        check(abs(pcm.duration - b.lines[0].duration) < 0.01, String(format: "MS ADPCM décodé : %.2f s à %.0f Hz", pcm.duration, pcm.rate))
        // Comparaison avec le décodeur MS ADPCM de ffmpeg (fichier WAV enveloppant les mêmes octets)
        let l = b.lines[0], raw = b.data.subdata(in: b.data.startIndex + l.start ..< b.data.startIndex + l.start + l.length)
        var h = Data()
        func w32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func w16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) { h.append(contentsOf: $0) } }
        let coefs = [(256, 0), (512, -256), (0, 0), (192, 64), (240, 0), (460, -208), (392, -232)]
        h.append(contentsOf: Array("RIFF".utf8)); w32(UInt32(4 + 8 + 50 + 8 + raw.count)); h.append(contentsOf: Array("WAVEfmt ".utf8)); w32(50)
        w16(2); w16(1); w32(UInt32(l.rate)); w32(UInt32(l.rate) * 70 / 128); w16(70); w16(4); w16(32); w16(128); w16(7)
        for (a, c) in coefs { w16(a); w16(c) }
        h.append(contentsOf: Array("data".utf8)); w32(UInt32(raw.count)); h.append(raw)
        let inWav = work.appendingPathComponent("adpcm.wav"), outRaw = work.appendingPathComponent("adpcm.raw")
        try h.write(to: inWav)
        if ffmpeg(inWav, outRaw, ["-f", "s16le"]), let ref = try? Data(contentsOf: outRaw) {
            let refS = ref.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let mine = pcm.samples.map { Int16(($0 * 32768).rounded()) }
            let n = min(refS.count, mine.count)
            let diff = (0 ..< n).first { refS[$0] != mine[$0] }
            check(n > 0 && diff == nil && refS.count == mine.count, "identique au décodeur de ffmpeg (\(n) échantillons)" + (diff.map { " — écart à \($0) : \(refS[$0]) / \(mine[$0]), tailles \(refS.count) / \(mine.count)" } ?? ""))
        }
        let names = Dictionary(uniqueKeysWithValues: b.lines.map { ($0.offset, $0.name) })
        let info = Xact.infoTexts(Xact.infoFile(for: seURL)!)
        let fr = Xact.texts(names: names, info: info, language: "fr")
        check(fr[0] == "A la santé d'Elaine Marley!", "texte français : \(fr[0] ?? "—")")
        check(fr.count * 10 > b.lines.count * 9, "\(fr.count) répliques sur \(b.lines.count) ont leur texte")
        var line = b.lines[0]; line.text = fr[0] ?? ""
        check(Encoder.name(pattern: "{nom}_{texte}", source: seURL, line: line, format: .wav) == "POT_55_entryway_17_1_A la santé d'Elaine Marley.wav", "balise {nom}")
    } catch { check(false, "édition spéciale : \(error)") }
}

// MARK: 3 quater. Archive .BUN (The Dig)
let digURL = URL(fileURLWithPath: "/Volumes/SAMSUNG T7/JEUX/SCUMMVM/The Dig/DIGVOICE.BUN")
if FileManager.default.fileExists(atPath: digURL.path) {
    print("3 quater. Archive iMUSE : \(digURL.path)")
    do {
        var t0 = Date()
        let b = try SoundBank(url: digURL)
        print(String(format: "    ouverture : %.2f s, %d fichiers, %@", Date().timeIntervalSince(t0), b.lines.count, b.gameName ?? "?"))
        check(b.lines.count == 4008 && b.gameName == "The Dig" && b.lines[0].name == "LIFEDIAL001", "archive lue, jeu reconnu, noms des fichiers")
        let pcm = try b.decode(b.lines[0])
        check(pcm.rate == 22050 && pcm.bits == 8 && pcm.duration > 1, String(format: "LIFEDIAL001 décompressé : %.2f s à %.0f Hz, %d bits", pcm.duration, pcm.rate, pcm.bits))
        t0 = Date(); var bad = 0, total = 0.0
        for l in b.lines { if let p = try? b.decode(l) { total += p.duration } else { bad += 1 } }
        print(String(format: "    décodage de toute l'archive : %.2f s, %.0f min", Date().timeIntervalSince(t0), total / 60))
        check(bad == 0, "\(b.lines.count - bad) fichiers décodés (\(bad) en échec)")
        t0 = Date()
        if let found = BunArchive.textSets(near: digURL) {
            for (lang, dict) in found.sets {
                let n = b.lines.filter { dict[$0.name] != nil }.count
                print(String(format: "    textes %@ : %d répliques sur %d (%.2f s)", lang, n, b.lines.count, Date().timeIntervalSince(t0)))
            }
            check(found.sets.first?.1["LIFEDIAL001"] == "Do you think it's possible to raise the dead?", "texte anglais (DIG.LA1)")
            check(found.sets.count == 2 && found.sets[1].0 == "fr" && found.sets[1].1["AIRLOCK003"] == "Venez de ce côté.", "texte français (LANGUAGE.BND)")
        } else { check(false, "textes de The Dig introuvables") }
    } catch { check(false, "The Dig : \(error)") }
}

// MARK: 3 quinquies. Sierra SCI32 (Space Quest 6)
let sq6URL = URL(fileURLWithPath: "/Volumes/SAMSUNG T7/JEUX/SCUMMVM/SpaceQ6/RESOURCE.AUD")
if FileManager.default.fileExists(atPath: sq6URL.path) {
    print("3 quinquies. Sierra : \(sq6URL.path)")
    do {
        var t0 = Date()
        let b = try SoundBank(url: sq6URL)
        print(String(format: "    ouverture : %.2f s, %d répliques, %.0f min, %@", Date().timeIntervalSince(t0), b.lines.count, b.totalDuration / 60, b.gameName ?? "?"))
        check(b.lines.count > 1000 && b.gameName == "Space Quest 6" && b.lines[0].name == "0_6_17_0_1", "répliques lues d'après les cartes du jeu, jeu reconnu")
        t0 = Date(); var bad = 0
        for l in b.lines { if let p = try? b.decode(l) { if abs(p.duration - l.duration) > 0.01 { bad += 1 } } else { bad += 1 } }
        print(String(format: "    décodage de toutes les répliques : %.2f s", Date().timeIntervalSince(t0)))
        check(bad == 0, "\(b.lines.count - bad) répliques décodées (\(bad) en échec)")
        // Comparaison avec le décodeur SOL de ffmpeg
        let l = b.lines[0]
        let sol = work.appendingPathComponent("c0.sol"), out = work.appendingPathComponent("c0.raw")
        try b.data.subdata(in: b.data.startIndex + l.start ..< b.data.startIndex + l.start + l.length).write(to: sol)
        if ffmpeg(sol, out, ["-f", "s16le"]), let ref = try? Data(contentsOf: out) {
            let r = ref.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            let mine = try b.decode(l).samples.map { Int16(($0 * 32768).rounded()) }
            check(r == mine, "DPCM 16 bits identique au décodeur de ffmpeg (\(mine.count) échantillons)")
        }
        t0 = Date()
        let tx = Sierra.texts(dir: sq6URL.deletingLastPathComponent())
        let n = b.lines.filter { tx[$0.name] != nil }.count
        print(String(format: "    textes : %d répliques sur %d (%.2f s), langue %@", n, b.lines.count, Date().timeIntervalSince(t0), Sierra.detect(tx)))
        check(tx["0_0_4_0_1"] == "Ne touche pas à ça! Tu ne sais pas où tu as traîné!", "texte des messages (STACpack)")
        check(n * 10 > b.lines.count * 8, "plus de 80 % des répliques ont leur texte")
    } catch { check(false, "Space Quest 6 : \(error)") }
}

// MARK: 3 sexies. Escape from Monkey Island (GrimE, VIMA)
let emiURL = URL(fileURLWithPath: "/Volumes/SAMSUNG T7/JEUX/SCUMMVM/Escape from Monkey Island/voiceAll.m4b")
if FileManager.default.fileExists(atPath: emiURL.path) {
    print("3 sexies. GrimE : \(emiURL.path)")
    do {
        var t0 = Date()
        let b = try SoundBank(url: emiURL)
        print(String(format: "    ouverture : %.2f s, %d répliques, %.0f min, %@", Date().timeIntervalSince(t0), b.lines.count, b.totalDuration / 60, b.gameName ?? "?"))
        check(b.lines.count == 735 && b.gameName == "Escape from Monkey Island" && b.lines[0].name == "clatri001", "archive LABN lue, jeu reconnu")
        t0 = Date(); var bad = 0, peak: Float = 0
        for l in b.lines {
            if let p = try? b.decode(l), abs(p.duration - l.duration) < 0.01 { peak = max(peak, p.samples.map(abs).max() ?? 0) } else { bad += 1 }
        }
        print(String(format: "    décodage de toutes les répliques : %.2f s, crête %.2f", Date().timeIntervalSince(t0), peak))
        check(bad == 0 && peak > 0.1 && peak <= 1, "\(b.lines.count - bad) répliques décodées (\(bad) en échec)")
        // Empreinte des échantillons, calculée par un portage Python indépendant du décodeur VIMA de ScummVM
        let s = try b.decode(b.lines[0]).samples.map { Int16(($0 * 32768).rounded()) }
        let sum = s.reduce(0) { ($0 &* 31 &+ Int(UInt16(bitPattern: $1))) & 0xFFFF_FFFF }
        print("    clatri001 : \(s.count) échantillons, empreinte \(sum)")
        check(s.count == 20865 && sum == 2_989_267_807, "VIMA identique au portage de référence")
        let tx = Grime.texts(dir: emiURL.deletingLastPathComponent())
        let n = b.lines.filter { tx[$0.name.lowercased()] != nil }.count
        print("    textes : \(n) répliques sur \(b.lines.count), langue \(Grime.detect(tx))")
        check(tx["clatri001"] == "Whoaaaaaa!" && n * 10 > b.lines.count * 9, "textes de script.tab (RCNE)")
    } catch { check(false, "Escape from Monkey Island : \(error)") }
}

// MARK: 3 sexies bis. Curse of Monkey Island : codec 13 (ADPCM IMA à taille variable)
print("3 sexies bis. Codec 13 (COMI)")
do {
    let hdr = BunArchive.imaDecode([0, 4, 0x69, 0x4D, 0x55, 0x53] + [UInt8](repeating: 0, count: 64), channels: 1, outputSize: 32)
    check(Array(hdr.prefix(4)) == Array("iMUS".utf8) && hdr.count == 32, "en-tête recopié tel quel")
    // état initial : index 0, mot 1000 ; paquets nuls (2 bits, signe 0) → le signal monte doucement
    let seed: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0x03, 0xE8]
    let out = BunArchive.imaDecode(seed + [UInt8](repeating: 0, count: 16), channels: 1, outputSize: 8)
    let s0 = Int(Int16(bitPattern: UInt16(out[0]) << 8 | UInt16(out[1])))
    check(BunArchive.imcBits[0] == 2 && BunArchive.imcBits[88] == 7 && s0 > 1000 && s0 < 1020, "état initial et premier pas")
}

// MARK: 3 sexies ter. Thimbleweed Park (.ggpack)
print("3 sexies ter. Thimbleweed Park")
do {
    // XOR inverse : chiffrer = x_i = clair_i ^ prev, puis octet = x_i ^ clé ^ (i × mult)
    let clear: [UInt8] = Array("OggS and some voice data".utf8)
    let key = GGPack.keys[0]
    var enc = [UInt8](repeating: 0, count: clear.count), prev = UInt8(truncatingIfNeeded: clear.count)
    for i in 0 ..< clear.count { let x = clear[i] ^ prev; enc[i] = x ^ key.bytes[i & 15] ^ UInt8(truncatingIfNeeded: i &* key.mult); prev = x }
    var dec = enc
    GGPack.unxor(&dec, key: key)
    check(dec == clear, "déchiffrement XOR")
    check(GGPack.isVoice("BANKMANAGER_20204.ogg") && !GGPack.isVoice("Ending_4416.ogg") && GGPack.id("RAY_20002") == 20002, "noms des voix")
    let t = GGPack.tsv(Array("text_id\ten\n20001\tAgent Ray! {laugh} Hi.\n".utf8))
    check(t == ["20001": "Agent Ray! Hi."], "textes .tsv")
    check(CastingLink.prefix("RAY_20002") == "ray" && CastingLink.speakers(game: "test-twp")["ray"] == "Agent Ray", "personnages")
}

// MARK: 3 sexies quater. Broken Sword (speech1.clv)
print("3 sexies quater. Broken Sword")
do {
    // en-tête de 24 octets : taille, scène 0 → mot 2 ; répliques : (24, 4) puis (28, 4) ; données « OggSOggS »
    var w: [UInt32] = [24, 8, 24, 4, 28, 4]
    var d = Data(bytes: &w, count: 24)
    d.append(contentsOf: Array("OggSOggS".utf8))
    let lines = try Sword1.parse(d)
    check(lines.count == 2 && lines[1].name == "000-0001" && lines[1].offset == 1 && lines[1].start == 28, "table des scènes et des répliques")
    check(Sword1.sections.count == 68 && Sword1.sections.last == 146, "sections de text.clu")
} catch { check(false, "Broken Sword : \(error)") }

// MARK: 3 sexies quinquies. Broken Sword Reforged / BS2 Remastered (AUFS)
print("3 sexies quinquies. Archives AUFS")
do {
    var w: [UInt32] = [0x5346_5541, 2, 0x20001, 32, 4, 0x20000, 36, 4]      // « AUFS », 2 sons
    var d = Data(bytes: &w, count: 32)
    d.append(contentsOf: Array("OggSOggS".utf8))
    let lines = try Aufs.parse(d, url: URL(fileURLWithPath: "/tmp/english.osa"))
    check(lines.count == 2 && lines[0].name == "002-0000" && lines[0].start == 36 && lines[1].offset == 0x20001, "sommaire, tri par numéro")
    check(Aufs.isSpeech(URL(fileURLWithPath: "/x/Speech_french.dat")) && !Aufs.isSpeech(URL(fileURLWithPath: "/x/sfx.osa"))
          && Aufs.voiceLanguage(URL(fileURLWithPath: "/x/german.osa")) == "de", "fichiers de voix et langue")
    var t: [UInt8] = Array("TEXT".utf8) + [0, 0, 0, 0, 1, 0, 0, 0, 5, 0, 0, 0, 20, 0, 0, 0] + Array("Hello\u{0}".utf8)
    t[8] = 1
    check(Aufs.texts(t) == [5: "Hello"], "textes TEXT")
} catch { check(false, "AUFS : \(error)") }

// MARK: 3 sexies sexies. Flight of the Amazon Queen (queen.1c)
print("3 sexies sexies. Flight of the Amazon Queen")
do {
    var t: [String: String] = [:]
    Queen.segments(" 2   6J", "Bonjour.*AOEt adieu.*XY00(237,112)Fin", into: &t)
    check(t == ["020006J1": "Bonjour.", "020006J2": "Et adieu.", "020006J3": "Fin"], "segments et noms des voix")
    check(Queen.code("BUD_020006P1") == "020006P1" && Queen.code("C18A_151") == "C18A_151" && Queen.code("JOE_JOE00241") == "JOE00241", "code d'origine")
    check(CastingLink.prefix("JOE_020006J1") == "joe" && CastingLink.knownSpeakers["joe"] == "Joe King", "personnages")
}

// MARK: 3 sexies septies. Tales of Monkey Island (.ttarch)
print("3 sexies septies. Tales of Monkey Island")
do {
    // vecteur de test officiel de Blowfish : clé nulle, bloc nul → 4EF99745 6198DD78
    var b: [UInt8] = [0x45, 0x97, 0xF9, 0x4E, 0x78, 0xDD, 0x98, 0x61]
    TelltaleBlowfish(key: [UInt8](repeating: 0, count: 8), modified: false).decrypt(&b)
    check(b == [UInt8](repeating: 0, count: 8), "Blowfish (vecteur de test)")
    check(Telltale.key(episode: 3)[14] == 0x86 && Telltale.episode(URL(fileURLWithPath: "/x/2_MonkeyIsland104_pc_voice.ttarch")) == 4, "clés et épisodes")
    func le(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
    let db = [9, 9] + le(42) + le(42) + le(16) + le(8) + Array("GUYBRUSH".utf8) + le(20) + le(12) + Array("{sad}Ahoy all".utf8).prefix(12) + [0, 0]
    let t = Telltale.langdb(db)
    check(t[42]?.speaker == "GUYBRUSH" && t[42]?.text == "Ahoy al", "base de langue (personnage, texte, indications retirées)")
}

// MARK: 3 septies. Envoi vers mCASTING (paquets de la boîte de réception)
print("3 septies. Envoi vers mCASTING")
check(CastingLink.prefix("GUY_4_shore_11_1") == "guy" && CastingLink.prefix("clatri001") == "cla" && CastingLink.prefix("") == ""
      && CastingLink.prefix("B2GT301") == "gt" && CastingLink.prefix("LIFEDIAL001") == "lif", "préfixes des répliques nommées")
check(CastingLink.tags("You fight like a cow.").contains("insult") && CastingLink.tags("Hello there?") == ["greeting", "question"]
      && CastingLink.tags("Ahhh!") == ["scream"] && CastingLink.tags("Hahaha, fool!").contains("laugh"), "étiquettes automatiques")
do {
    // Banque de synthèse : 10 répliques de 3 s, texte connu → extrait coupé à 25 s, texte de référence, paquets complets.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("mtalkie-casting-\(getpid())")
    setenv("MCASTING_HOME", home.path, 1); defer { try? FileManager.default.removeItem(at: home) }
    let tone = (0 ..< 3 * 22_050).map { Float(sin(Double($0) * 0.05) * 0.3) }
    let pcm = PCM(rate: 22_050, channels: 1, samples: tone, bits: 16)
    let sou = home.appendingPathComponent("t.wav"); try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try WavWriter.data(pcm).write(to: sou)
    let mixed = try CastingLink.mono(PCM(rate: 22_050, channels: 2, samples: tone.flatMap { [$0, $0] }, bits: 16), rate: 24_000)
    check(abs(mixed.count - 3 * 24_000) < 64, "mono 24 kHz depuis du stéréo 22,05 kHz (\(mixed.count) échantillons)")
    let aac = home.appendingPathComponent("a.aac"); try CastingLink.writeAAC(pcm, to: aac)
    let size = (try? FileManager.default.attributesOfItem(atPath: aac.path)[.size] as? Int) ?? 0
    let back = try AVAudioFile(forReading: aac)
    check(size > 4_000 && size < 3 * 6_000 && abs(Double(back.length) / back.processingFormat.sampleRate - 3) < 0.3, "AAC ADTS léger et relisible (\(size) octets)")
} catch { check(false, "envoi vers mCASTING : \(error)") }

// MARK: 4. Traductions
print("4. Traductions")
let keys = Set(Loc.fr.keys)
for (code, t) in [("en", Loc.en), ("es", Loc.es), ("it", Loc.it)] {
    let k = Set(t.keys)
    check(k == keys, "\(code) : mêmes clés que fr\(k == keys ? "" : " — manquantes \(keys.subtracting(k).sorted()), en trop \(k.subtracting(keys).sorted())")")
}

print(failures == 0 ? "\nTous les tests passent." : "\n\(failures) échec(s).")
exit(failures == 0 ? 0 : 1)
