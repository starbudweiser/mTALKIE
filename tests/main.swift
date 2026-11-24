// mTALKIE — tests du moteur (lancer tests/run_tests.sh).
// 1. Faux MONSTER.SOU construit à partir de VOC de synthèse : découpe, références VCTL, durées, WAV 8 bits octet par octet.
// 2. Mêmes répliques en .SO3 / .SOG / .SOF (mise en page de compress_scumm_sou, encodage ffmpeg) : index et décodage.
// 3. Vrai MONSTER.SOU s'il est présent (chemin en argument) : nombre de répliques, décodage et export de toutes.
// 4. Tables de traduction : mêmes clés dans les 4 langues.
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

// MARK: 4. Traductions
print("4. Traductions")
let keys = Set(Loc.fr.keys)
for (code, t) in [("en", Loc.en), ("es", Loc.es), ("it", Loc.it)] {
    let k = Set(t.keys)
    check(k == keys, "\(code) : mêmes clés que fr\(k == keys ? "" : " — manquantes \(keys.subtracting(k).sorted()), en trop \(k.subtracting(keys).sorted())")")
}

print(failures == 0 ? "\nTous les tests passent." : "\n\(failures) échec(s).")
exit(failures == 0 ? 0 : 1)
