// mTALKIE — textes des répliques, lus dans les scripts du jeu (ATLANTIS.001, MONKEY2.001, TENTACLE.001, SAMNMAX.001…).
// Chaque phrase parlée commence par le code « FF 0A » suivi de la position de sa réplique (bloc VCTL) dans MONSTER.SOU :
// FF 0A a0 a1 FF 0A a2 a3 FF 0A b0 b1 FF 0A b2 b3, puis le texte jusqu'à l'octet nul. Fichiers chiffrés par XOR 0x69.
import Foundation
import NaturalLanguage

struct ScriptTexts {
    let url: URL
    let texts: [Int: String]      // position VCTL → texte
    let language: String?         // code ISO détecté (« en », « fr »…)
    var languages: [String] = []  // éditions spéciales : langues proposées (toutes dans le même fichier)

    enum Failure: LocalizedError {
        case unreadable, noMatch
        var errorDescription: String? { self == .unreadable ? L("err.texts.read") : L("err.texts.nomatch") }
    }

    /// Fichier de scripts posé à côté des voix : .001 (Indy 4, MI2, DOTT, Sam & Max CD), .LA1 ou .SM1 (autres éditions).
    static func find(near sou: URL) -> URL? {
        let dir = sou.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let candidates = items.filter { ["001", "LA1", "SM1"].contains($0.pathExtension.uppercased()) }
        return candidates.max { size($0) < size($1) }
    }

    private static func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    /// Lit les textes des positions demandées. Essaie d'abord le chiffrement XOR 0x69, puis le fichier en clair.
    static func load(_ url: URL, offsets: Set<Int>) throws -> ScriptTexts {
        guard let raw = try? Data(contentsOf: url, options: .alwaysMapped) else { throw Failure.unreadable }
        for key: UInt8 in [0x69, 0x00] {
            let texts = raw.withUnsafeBytes { scan($0.bindMemory(to: UInt8.self), key: key, offsets: offsets) }
            if !texts.isEmpty { return ScriptTexts(url: url, texts: texts, language: detect(texts)) }
        }
        throw Failure.noMatch
    }

    static func scan(_ p: UnsafeBufferPointer<UInt8>, key: UInt8, offsets: Set<Int>) -> [Int: String] {
        let n = p.count
        @inline(__always) func at(_ i: Int) -> UInt8 { p[i] ^ key }
        var out: [Int: String] = [:]
        var i = 0
        while i + 16 <= n {
            if at(i) == 0xFF, at(i + 1) == 0x0A, at(i + 4) == 0xFF, at(i + 5) == 0x0A, at(i + 8) == 0xFF, at(i + 9) == 0x0A, at(i + 12) == 0xFF, at(i + 13) == 0x0A {
                let a = Int(at(i + 2)) | Int(at(i + 3)) << 8 | Int(at(i + 6)) << 16 | Int(at(i + 7)) << 24
                if offsets.contains(a), out[a] == nil, let t = text(p, from: i + 16, key: key), !t.isEmpty { out[a] = t }
                i += 16
            } else { i += 1 }
        }
        return out
    }

    /// Texte jusqu'à l'octet nul ou au code de réplique suivant ; codes de contrôle SCUMM retirés, page de code DOS 437.
    private static func text(_ p: UnsafeBufferPointer<UInt8>, from start: Int, key: UInt8) -> String? {
        var bytes: [UInt8] = []
        var j = start
        let end = min(p.count, start + 600)
        loop: while j < end {
            let c = p[j] ^ key
            if c == 0 { break }
            if c == 0xFF, j + 1 < end {
                switch p[j + 1] ^ key {
                case 0x01, 0x03: bytes.append(0x20); j += 2          // retour à la ligne, attente
                case 0x02, 0x0A: break loop                          // suite de phrase, réplique suivante
                case 0x04 ... 0x09, 0x0C, 0x0E: j += 4               // variable, verbe, nom, couleur, police
                default: j += 2
                }
                continue
            }
            bytes.append(c < 0x20 ? 0x20 : c)
            j += 1
        }
        guard let s = String(bytes: bytes, encoding: dos437) else { return nil }
        // « ^ » : points de suspension dans la police des jeux LucasArts (« Mr. uhh^ ^what… »).
        let t = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return t.replacingOccurrences(of: "^ ^", with: "… ").replacingOccurrences(of: "^", with: "…")
    }

    private static let dos437 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))

    private static func detect(_ texts: [Int: String]) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(texts.values.prefix(400).joined(separator: " "))
        return r.dominantLanguage?.rawValue
    }

    /// Nom de la langue dans celle de l'interface (« anglais », « English »…).
    var languageName: String? { language.flatMap { Loc.locale.localizedString(forLanguageCode: $0) } }
}
