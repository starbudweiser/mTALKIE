// mTALKIE — Broken Sword 2 Remastered : qui dit chaque réplique.
// Les scripts (Game/Scripts.clu) font parler les personnages par deux fonctions :
//   « je parle » (le joueur) : 22 00000000 22 …… 22 0C000000 22 14000000 06 <texte> 06 <voix> <animation>
//   « tu parles » (un autre) : 22 0C000000 02 <cible> 06 01000000 06 <texte> 06 <voix> <animation>
// L'animation est un numéro de ressource (souvent une variable locale posée par 06 <valeur> 03 <variable>) ; la table
// numéro → (rang, fichier .clu) est dans l'exécutable du jeu (16 octets par numéro). Son nom dit qui parle et où :
// « eJap71LH » = touriste japonais, salle 71. Le joueur sans animation est George ou Nico : on le déduit de la salle
// (salles où existent des animations de George seul ou de Nico seul), sinon des autres répliques du script.
import Foundation

enum Bs2 {
    /// Fichiers .clu dans l'ordre de l'exécutable (numéro de fichier de la table).
    static let clusters = ["Scripts", "Pyramid2", "General", "Carib1", "Carib2", "Pyramid1", "Carib3", "Players", "Warehous",
                           "Paris", "Jungle", "Quaramon", "Docks"]

    /// Codes des animations → nom du personnage (les autres gardent leur code, à nommer dans mCASTING).
    static let names: [String: String] = [
        "geo": "George", "nic": "Nico", "rio": "Rio", "dne": "Duane", "prl": "Pearl", "oub": "Oubier", "gls": "Glease",
        "pab": "Pablo", "mig": "Miguel", "tit": "Titipoco", "lob": "Lobineau", "hwk": "Hawks", "hku": "Haiku", "fos": "Foster",
        "shm": "Shaman", "wtr": "Waiter", "grd": "Guard", "jap": "Tourist", "gnl": "General", "brt": "Bert", "cam": "Cameraman",
    ]

    static func le32(_ d: Data, _ p: Int) -> Int {
        let s = d.startIndex + p
        return Int(d[s]) | Int(d[s + 1]) << 8 | Int(d[s + 2]) << 16 | Int(d[s + 3]) << 24
    }
    static func le16(_ d: Data, _ p: Int) -> Int { Int(d[d.startIndex + p]) | Int(d[d.startIndex + p + 1]) << 8 }

    /// Noms (32 octets) des ressources d'un .clu : position du sommaire en tête, puis (position, taille) par ressource.
    static func resourceNames(_ d: Data) -> [String] {
        guard d.count > 8 else { return [] }
        let index = le32(d, 0)
        guard index > 0, index < d.count else { return [] }
        return (0 ..< (d.count - index) / 8).map { k in
            let off = le32(d, index + k * 8), size = le32(d, index + k * 8 + 4)
            guard size >= 32, off + 32 <= d.count else { return "" }
            return String(decoding: d[(d.startIndex + off) ..< (d.startIndex + off + 32)].prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Table numéro → (rang, fichier) : repérée dans l'exécutable grâce aux numéros des ressources de texte.
    static func resourceTable(exe: Data, texts: Data) -> Int? {
        var known: [(id: Int, k: Int)] = []
        for (k, n) in resourceNames(texts).enumerated() where n.hasPrefix("lText Resource ") {
            if let id = Int(n.dropFirst(15)) { known.append((id, k)) }
            if known.count == 6 { break }
        }
        guard known.count >= 3, let one = known.first(where: { $0.k == 1 }) else { return nil }
        return exe.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let b = raw.bindMemory(to: UInt8.self)
            func u16(_ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
            var p = 16 * one.id
            while p + 4 <= b.count {
                if b[p] == 1, b[p + 1] == 0, b[p + 3] == 0 {
                    let base = p - 16 * one.id, c = u16(p + 2)
                    if known.allSatisfy({ base + 16 * $0.id + 4 <= b.count && u16(base + 16 * $0.id) == $0.k && u16(base + 16 * $0.id + 2) == c }) { return base }
                }
                p += 2
            }
            return nil
        }
    }

    /// Numéro de voix → code du personnage (« geo », « jap »…).
    static func speakers(near url: URL) -> [Int: String] {
        let resources = url.deletingLastPathComponent().deletingLastPathComponent()          // …/Contents/Resources
        let game = resources.appendingPathComponent("Game"), macos = resources.deletingLastPathComponent().appendingPathComponent("MacOS")
        let fm = FileManager.default
        guard let exeName = (try? fm.contentsOfDirectory(atPath: macos.path))?.first,
              let exe = try? Data(contentsOf: macos.appendingPathComponent(exeName), options: .alwaysMapped),
              let textName = (try? fm.contentsOfDirectory(atPath: resources.appendingPathComponent("Text").path))?.first(where: { $0.lowercased().hasSuffix(".clu") }),
              let texts = try? Data(contentsOf: resources.appendingPathComponent("Text").appendingPathComponent(textName), options: .alwaysMapped),
              let table = resourceTable(exe: exe, texts: texts),
              let scripts = try? Data(contentsOf: game.appendingPathComponent("Scripts.clu"), options: .alwaysMapped) else { return [:] }
        var names: [[String]] = []
        var geoRooms = Set<Int>(), nicRooms = Set<Int>()
        for c in clusters {
            let d = (try? Data(contentsOf: game.appendingPathComponent(c + ".clu"), options: .alwaysMapped)) ?? Data()
            let n = resourceNames(d)
            names.append(n)
            for x in n where x.hasPrefix("eGeo") || x.hasPrefix("eNic") {
                if let r = Int(x.dropFirst(4).prefix { $0.isNumber }) { if x.hasPrefix("eGeo") { geoRooms.insert(r) } else { nicRooms.insert(r) } }
            }
        }
        func resourceName(_ id: Int) -> String? {
            guard id > 0, id < 0x10000, table + 16 * id + 4 <= exe.count else { return nil }
            let k = le16(exe, table + 16 * id), c = le16(exe, table + 16 * id + 2)
            return c < names.count && k < names[c].count ? names[c][k] : nil
        }
        /// « eJap71LH » → (« jap », 71).
        func who(_ anim: Int) -> (code: String, room: Int?)? {
            guard let n = resourceName(anim), n.hasPrefix("e") else { return nil }
            let rest = n.dropFirst(), letters = rest.prefix { $0.isLetter }
            guard !letters.isEmpty else { return nil }
            return (letters.lowercased(), Int(rest.dropFirst(letters.count).prefix { $0.isNumber }))
        }

        var out: [Int: String] = [:]
        let index = le32(scripts, 0)
        guard index > 0, index < scripts.count else { return [:] }
        for k in 0 ..< (scripts.count - index) / 8 {
            let off = le32(scripts, index + k * 8), size = le32(scripts, index + k * 8 + 4)
            guard size > 32, off + size <= scripts.count else { continue }
            let s = [UInt8](scripts[(scripts.startIndex + off) ..< (scripts.startIndex + off + size)])
            func u32(_ p: Int) -> Int { Int(s[p]) | Int(s[p + 1]) << 8 | Int(s[p + 2]) << 16 | Int(s[p + 3]) << 24 }
            func u16(_ p: Int) -> Int { Int(s[p]) | Int(s[p + 1]) << 8 }
            func match(_ p: Int, _ bytes: [UInt8]) -> Bool { p + bytes.count <= s.count && s[p ..< p + bytes.count].elementsEqual(bytes) }
            var locals: [Int: Int] = [:], rooms: [Int: Int] = [:]
            var lines: [(wav: Int, code: String?, mine: Bool)] = []
            /// Animation poussée : variable locale (01 vv) ou valeur (06 vvvvvvvv).
            func anim(_ p: Int) -> Int? {
                guard p + 3 <= s.count else { return nil }
                if s[p] == 1 { return locals[u16(p + 1)] }
                if s[p] == 6, p + 5 <= s.count { return u32(p + 1) }
                return nil
            }
            func speak(_ wav: Int, _ a: Int?, mine: Bool) {
                let w = a.flatMap(who)
                if let r = w?.room { rooms[r, default: 0] += 1 }
                if wav > 0 { lines.append((wav, w?.code, mine)) }
            }
            var i = 32
            while i + 8 < s.count {
                if s[i] == 6, s[i + 5] == 3 { locals[u16(i + 6)] = u32(i + 1); i += 8; continue }
                if s[i] == 0x22, match(i, [0x22, 0, 0, 0, 0, 0x22]), match(i + 10, [0x22, 0x0C, 0, 0, 0, 0x22, 0x14, 0, 0, 0, 6]),
                   i + 31 <= s.count, s[i + 25] == 6 {
                    speak(u32(i + 26), anim(i + 30), mine: true); i += 30; continue
                }
                if s[i] == 0x22, match(i, [0x22, 0x0C, 0, 0, 0, 2]), match(i + 8, [6, 1, 0, 0, 0, 6]), i + 24 <= s.count, s[i + 18] == 6 {
                    speak(u32(i + 19), anim(i + 23), mine: false); i += 23; continue
                }
                i += 1
            }
            guard !lines.isEmpty else { continue }
            // Le joueur : son animation dans ce script, sinon la salle, sinon les répliques des autres.
            let name = String(decoding: s.prefix(32).prefix { $0 != 0 }, as: UTF8.self)
            if let u = name.lastIndex(of: "_"), let r = Int(name[name.index(after: u)...]) { rooms = [r: 1_000] }
            let mine = Set(lines.filter { $0.mine }.compactMap(\.code).filter { $0 == "geo" || $0 == "nic" })
            let theirs = Set(lines.filter { !$0.mine }.compactMap(\.code))
            var player = "geo"
            if mine.count == 1 { player = mine.first! }
            else if let r = rooms.max(by: { $0.value < $1.value })?.key, nicRooms.contains(r) != geoRooms.contains(r) { player = nicRooms.contains(r) ? "nic" : "geo" }
            else if theirs.contains("geo") != theirs.contains("nic") { player = theirs.contains("geo") ? "nic" : "geo" }
            for l in lines where out[l.wav] == nil {
                if let c = l.code { out[l.wav] = c } else if l.mine { out[l.wav] = player }
            }
        }
        return out
    }

    /// Nom de la réplique : « George_03121 », « GNL_03122 » (code non reconnu), « 03123 » (inconnu).
    static func lineName(_ id: Int, code: String?) -> String {
        let n = String(format: "%05d", id)
        guard let c = code else { return n }
        return (names[c] ?? c.uppercased()) + "_" + n
    }
}
