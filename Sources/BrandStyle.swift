// mTALKIE — coloration de la lettre minuscule du nom (modèle Socle BrandStyle.swift).
import AppKit

/// Couleur de la lettre minuscule du nom : le vert du logo (#22c55e), assombri en thème clair
/// pour rester lisible (3:1 minimum sur `bg`).
enum BrandStyle {
    static let color = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x22 / 255, green: 0xc5 / 255, blue: 0x5e / 255, alpha: 1)
            : NSColor(srgbRed: 0x15 / 255, green: 0x80 / 255, blue: 0x3d / 255, alpha: 1)
    }

    /// Texte dont la lettre minuscule de chaque occurrence du nom est colorée ; le reste garde ses attributs.
    static func colored(_ base: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: base)
        for range in Brand.lowercaseRanges(in: base.string) {
            out.addAttribute(.foregroundColor, value: color, range: range)
        }
        return out
    }

    static func colored(_ text: String, font: NSFont) -> NSAttributedString {
        colored(NSAttributedString(string: text, attributes: [.font: font]))
    }

    /// Colore le nom dans tous les textes d'une fenêtre (dialogues compris).
    @MainActor
    static func apply(to window: NSWindow) {
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.isEditable, field.stringValue.contains(Brand.name) {
                field.attributedStringValue = colored(field.attributedStringValue)
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
    }
}
