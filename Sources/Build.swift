// mTALKIE — jeux de tir des années 90 : Doom (archives .WAD) et moteur Build (Duke Nukem 3D, Redneck Rampage,
// Shadow Warrior, Blood : archives .GRP).
// WAD : « IWAD » / « PWAD », nombre de fichiers et position du répertoire (LE32) ; par fichier : position, taille, nom
// sur 8. Sons « DS… » au format DMX : 3 (LE16), fréquence (LE16), nombre d'octets (LE32, 16 octets de remplissage de
// part et d'autre), échantillons 8 bits non signés.
// GRP : « KenSilverman », nombre de fichiers (LE32), puis par fichier un nom sur 12 et une taille ; les données suivent
// le répertoire dans le même ordre. Sons .VOC (Creative) et .WAV.
import Foundation

enum Build {
    enum Kind { case wad, grp }

    static func kind(_ d: Data) -> Kind? {
        if d.count > 12, d.prefix(4).elementsEqual("IWAD".utf8) || d.prefix(4).elementsEqual("PWAD".utf8) { return .wad }
        if d.count > 16, d.prefix(12).elementsEqual("KenSilverman".utf8) { return .grp }
        return nil
    }
    static func isArchive(_ url: URL) -> Bool { ["wad", "grp"].contains(url.pathExtension.lowercased()) }

    static func le32(_ d: Data, _ p: Int) -> Int {
        let s = d.startIndex + p
        return Int(d[s]) | Int(d[s + 1]) << 8 | Int(d[s + 2]) << 16 | Int(d[s + 3]) << 24
    }
    static func le16(_ d: Data, _ p: Int) -> Int { Int(d[d.startIndex + p]) | Int(d[d.startIndex + p + 1]) << 8 }

    /// Sons de l'archive : `name` = nom du fichier (« DSPOSIT1 », « LAUGH01.VOC »).
    static func parse(_ d: Data) throws -> [Line] {
        guard let k = kind(d) else { throw FormatError.notSoundBank }
        var out: [Line] = []
        func add(_ name: String, _ off: Int, _ size: Int) {
            var l = Line(id: out.count + 1, offset: out.count, start: off, length: size, rate: 0, duration: 0)
            l.name = name
            out.append(l)
        }
        switch k {
        case .wad:
            let n = le32(d, 4), dir = le32(d, 8)
            guard n > 0, n < 100_000, dir + n * 16 <= d.count else { throw FormatError.notSoundBank }
            for i in 0 ..< n {
                let e = dir + i * 16
                let off = le32(d, e), size = le32(d, e + 4)
                let name = String(decoding: d[(d.startIndex + e + 8) ..< (d.startIndex + e + 16)].prefix { $0 != 0 }, as: UTF8.self)
                guard size > 8 + 32, off + size <= d.count, le16(d, off) == 3 else { continue }        // son DMX
                let rate = le16(d, off + 2), count = le32(d, off + 4)
                guard rate >= 4000, rate <= 48000, count > 32, count <= size - 8 else { continue }
                add(name, off, size)
            }
        case .grp:
            let n = le32(d, 12)
            guard n > 0, n < 100_000, 16 + n * 16 <= d.count else { throw FormatError.notSoundBank }
            var off = 16 + n * 16
            for i in 0 ..< n {
                let e = 16 + i * 16
                let name = String(decoding: d[(d.startIndex + e) ..< (d.startIndex + e + 12)].prefix { $0 != 0 }, as: UTF8.self)
                let size = le32(d, e + 12)
                defer { off += size }
                guard off + size <= d.count else { break }
                let ext = (name as NSString).pathExtension.uppercased()
                if ext == "VOC" || ext == "WAV" { add(name, off, size) }
            }
        }
        guard !out.isEmpty else { throw FormatError.empty }
        return out
    }

    /// Doom : description des sons connus (nom sans « DS »), pour la recherche et l'envoi vers mCASTING.
    static let doomSounds: [String: String] = [
        "PISTOL": "Pistol shot", "SHOTGN": "Shotgun shot", "SGCOCK": "Shotgun reload", "DSHTGN": "Super shotgun shot",
        "DBOPN": "Super shotgun open", "DBCLS": "Super shotgun close", "DBLOAD": "Super shotgun load", "PLASMA": "Plasma rifle shot",
        "BFG": "BFG 9000 shot", "SAWUP": "Chainsaw start", "SAWIDL": "Chainsaw idle", "SAWFUL": "Chainsaw rev", "SAWHIT": "Chainsaw hit",
        "RLAUNC": "Rocket launch", "RXPLOD": "Rocket explosion", "FIRSHT": "Fireball shot", "FIRXPL": "Fireball explosion",
        "PSTART": "Lift start", "PSTOP": "Lift stop", "DOROPN": "Door opens", "DORCLS": "Door closes", "BDOPN": "Fast door opens",
        "BDCLS": "Fast door closes", "STNMOV": "Moving stone", "SWTCHN": "Switch on", "SWTCHX": "Switch off",
        "PLPAIN": "Doomguy: pain", "DMPAIN": "Demon: pain", "POPAIN": "Zombie: pain", "VIPAIN": "Arch-vile: pain", "MNPAIN": "Mancubus: pain",
        "PEPAIN": "Pain elemental: pain", "SLOP": "Gibbing", "ITEMUP": "Item pickup", "WPNUP": "Weapon pickup", "GETPOW": "Power-up pickup",
        "ITMBK": "Item respawn", "OOF": "Doomguy: oof", "NOWAY": "Doomguy: grunt (no way)", "TELEPT": "Teleport",
        "POSIT1": "Zombieman: sight 1", "POSIT2": "Zombieman: sight 2", "POSIT3": "Zombieman: sight 3", "BGSIT1": "Imp: sight 1",
        "BGSIT2": "Imp: sight 2", "SGTSIT": "Demon: sight", "CACSIT": "Cacodemon: sight", "BRSSIT": "Baron of Hell: sight",
        "CYBSIT": "Cyberdemon: sight", "SPISIT": "Spider Mastermind: sight", "BSPSIT": "Arachnotron: sight", "KNTSIT": "Hell knight: sight",
        "VILSIT": "Arch-vile: sight", "MANSIT": "Mancubus: sight", "PESIT": "Pain elemental: sight", "SKESIT": "Revenant: sight",
        "SSSIT": "SS guard: sight", "SKLATK": "Lost soul: attack", "SGTATK": "Demon: attack", "SKEPCH": "Revenant: punch",
        "VILATK": "Arch-vile: attack", "CLAW": "Claw attack", "SKESWG": "Revenant: swing", "PLDETH": "Doomguy: death",
        "PDIEHI": "Doomguy: gory death", "PODTH1": "Zombieman: death 1", "PODTH2": "Zombieman: death 2", "PODTH3": "Zombieman: death 3",
        "BGDTH1": "Imp: death 1", "BGDTH2": "Imp: death 2", "SGTDTH": "Demon: death", "CACDTH": "Cacodemon: death",
        "BRSDTH": "Baron of Hell: death", "CYBDTH": "Cyberdemon: death", "SPIDTH": "Spider Mastermind: death", "BSPDTH": "Arachnotron: death",
        "VILDTH": "Arch-vile: death", "KNTDTH": "Hell knight: death", "PEDTH": "Pain elemental: death", "SKEDTH": "Revenant: death",
        "MANDTH": "Mancubus: death", "SSDTH": "SS guard: death", "KEENDT": "Commander Keen: death", "POSACT": "Zombie: active",
        "BGACT": "Imp: active", "DMACT": "Demon: active", "BSPACT": "Arachnotron: active", "BSPWLK": "Arachnotron: walk",
        "VILACT": "Arch-vile: active", "SKEACT": "Revenant: active", "BAREXP": "Barrel explosion", "PUNCH": "Punch", "HOOF": "Cyberdemon: hoof",
        "METAL": "Metal step", "TINK": "Tink", "CHGUN": "Chaingun", "RADIO": "Radio", "FIRXPL2": "Fireball explosion",
        "BOSPIT": "Icon of Sin: spit", "BOSCUB": "Icon of Sin: cube", "BOSSIT": "Icon of Sin: sight", "BOSPN": "Icon of Sin: pain",
        "BOSDTH": "Icon of Sin: death", "MANATK": "Mancubus: attack", "FLAMST": "Arch-vile: flames start", "FLAME": "Arch-vile: flames",
        "SKESIT2": "Revenant: sight 2", "PDIEHI2": "Doomguy: gory death 2", "SKLDTH": "Lost soul: death", "SGTSIT2": "Demon: sight 2",
    ]

    static func doomText(_ name: String) -> String? {
        let n = name.uppercased()
        guard n.hasPrefix("DS") else { return nil }
        return doomSounds[String(n.dropFirst(2))]
    }

    static func decode(_ d: Data, line: Line) throws -> PCM {
        let s = d.startIndex + line.start
        if le16(d, line.start) == 3, !line.name.contains(".") {                                // DMX (Doom)
            let rate = le16(d, line.start + 2), count = le32(d, line.start + 4)
            let a = s + 8 + 16, b = s + 8 + count - 16
            guard b > a, b <= d.endIndex else { throw FormatError.unsupportedCodec }
            return PCM(rate: Double(rate), channels: 1, samples: d[a ..< b].map { (Float($0) - 128) / 128 }, bits: 8)
        }
        if line.name.uppercased().hasSuffix(".VOC") {
            return try VocDecoder.decode(d, start: line.start, end: line.start + line.length, headerSize: 26)
        }
        return try CompressedDecoder.decode(d.subdata(in: s ..< s + line.length), ext: "wav")
    }
}
