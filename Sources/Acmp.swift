// mTALKIE — Interplay ACMP (« AUDCOMP ») : voix de Star Trek: Judgment Rites, dans les archives .VCC du CD.
// Fichier : « Interplay ACMP Data » + 0x1A, fréquence (LE16), 4 octets, nombre d'échantillons (LE32), puis des blocs de
// 256 échantillons 8 bits. Chaque bloc commence par un octet : bit 7 = demi-fréquence (un échantillon sur deux, les
// autres interpolés), bits 5-6 = décalage, bits 0-4 = codage des écarts (constante, unaire, largeur fixe…).
// Deux lecteurs partagent le flux d'octets : un lecteur de bits (poids faible d'abord) et un lecteur de « séries »
// (longueur d'une suite de bits identiques). Les deux repartent à zéro à chaque bloc.
// Format décrit d'après la décompilation de TREKJR.EXE (github.com/sammiq/stjr) et wiki.multimedia.cx.
import Foundation

struct AcmpDecoder {
    private let src: [UInt8]
    private var pos: Int
    private var bits: UInt32 = 0, nbits = 0                // lecteur de bits
    private var rbyte = 0, rbits = 0, rlast = 0           // lecteur de séries

    static let magic = Array("Interplay ACMP Data".utf8) + [0x1A]
    static let headerSize = 26

    init(_ data: [UInt8], start: Int = AcmpDecoder.headerSize) { src = data; pos = start }

    static func isAcmp(_ b: [UInt8]) -> Bool { b.count > headerSize + 4 && Array(b.prefix(20)) == magic }
    static func rate(_ b: [UInt8]) -> Int { Int(b[20]) | Int(b[21]) << 8 }

    private mutating func byte() -> Int {
        defer { pos += 1 }
        return pos < src.count ? Int(src[pos]) : 0
    }

    private mutating func read(_ n: Int) -> Int {
        while nbits < n { bits |= UInt32(byte()) << UInt32(nbits); nbits += 8 }
        let v = Int(bits & ((1 << UInt32(n)) - 1))
        bits >>= UInt32(n); nbits -= n
        return v
    }

    /// Longueur de la série suivante (bits alternés d'une série à l'autre) ; 10 = la valeur suit sur 6 bits.
    private mutating func run() -> Int {
        var n = 1
        rlast = rlast == 0 ? 1 : 0
        while true {
            if rbits == 0 { rbyte = byte(); rbits = 8 }
            rbits -= 1
            if (rbyte ^ rlast) & 1 != 0 { break }
            n += 1
            rbyte >>= 1
        }
        rbyte >>= 1
        return n == 10 ? read(6) : n
    }

    @inline(__always) private func signed(_ d: Int) -> Int { d & 1 != 0 ? -(d >> 1) : d >> 1 }

    private mutating func block(prev: Int, count n: Int) -> [UInt8] {
        bits = 0; nbits = 0; rbyte = 0; rbits = 0; rlast = 0
        let hdr = read(8)
        let shift = (hdr & 0x60) >> 5
        let half = hdr & 0x80 != 0
        let len = half ? (n + 1) >> 1 : n
        var out = [Int](repeating: 0x80, count: n)
        var v = 0x80
        switch hdr & 0x1F {
        case 0:
            let c = read(8)
            for i in 0 ..< len { out[i] = c }
        case 1:
            for i in 0 ..< len {
                let k = run() - 1
                if k != 0 { v += signed(read(k) | 1 << k) << shift }
                out[i] = v
            }
        case 2:
            for i in 0 ..< len {
                var d = read(4)
                d = d != 0 ? d - 8 : read(8 - shift)
                v += d << shift
                out[i] = v
            }
        case 3, 4:
            let w = (hdr & 0x1F) == 3 ? 3 : 4
            for i in 0 ..< len {
                let k = run() - 1
                v += signed(read(w) + (k << w)) << shift
                out[i] = v
            }
        case 5:
            for i in 0 ..< len {
                var d = read(2)
                if d == 3 { d = -1 } else if d == 2 { let k = run(); d = signed(read(k + 1) | 2 << k) }
                v += d << shift
                out[i] = v
            }
        case 6:
            for i in 0 ..< len { out[i] = read(8 - shift) << shift }
        default:
            break
        }
        for i in 0 ..< len { out[i] &= 0xFF }
        if half {                                         // demi-fréquence : intercaler les échantillons manquants
            var i = n - 1
            while i >= 0 {
                let j = i >> 1
                if i & 1 != 0 {
                    out[i] = out[j]
                } else {
                    var a = j > 0 ? out[j - 1] : prev
                    if j > 1, j < len - 1 {
                        let b = out[j - 2]
                        let s = out[j] + a
                        var t = s - out[j + 1] - b
                        t = (t + t * 2 + ((s + 1) << 5)) >> 6
                        out[i] = max(0, min(255, t))
                    } else {
                        a = (a + 1) & ~1
                        out[i] = (a + out[j]) >> 1
                    }
                }
                i -= 1
            }
        }
        return out.map { UInt8(truncatingIfNeeded: $0) }
    }

    /// Échantillons 8 bits non signés.
    mutating func decode() -> [UInt8] {
        let total = byte() | byte() << 8 | byte() << 16 | byte() << 24
        guard total > 0, total < 50_000_000 else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(total)
        var prev = 0x80
        while out.count < total, pos < src.count {
            let b = block(prev: prev, count: min(256, total - out.count))
            out += b
            prev = Int(b.last ?? 0x80)
        }
        return out
    }
}
