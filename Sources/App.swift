// mTALKIE — extrait, écoute et exporte les voix des jeux LucasArts SCUMM en version CD (fichiers .SOU, .SO3, .SOG, .SOF).
// Point d'entrée AppKit : fenêtre principale ouverte sans prendre le focus (lancement discret), menus dans les 4 langues.
import AppKit
import SwiftUI

@main
@MainActor
enum Main {
    static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var window: NSWindow?
    private var settings: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Socle.brand("mTALKIE", color: Color(nsColor: BrandStyle.color))
        Socle.apply()
        BusyFlag.set(false)
        buildMenu()
        showMain()
        // Mise à jour : une recherche par jour, jamais d'installation pendant un export.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in Updater.shared.tick(busy: Store.shared.exporting) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { Updater.shared.tick(busy: Store.shared.exporting) }
        // Fichier passé en argument (essais)
        if let path = CommandLine.arguments.dropFirst().first(where: { Store.extensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
            Store.shared.open(URL(fileURLWithPath: path))
        }
        debugLaunch()
    }

    /// Aides d'essai, actives seulement dans la version de développement (identifiant …dev) :
    /// -debugSelect 3 (sélectionne les n premières répliques et lit la première), -debugExport <dossier> (exporte la sélection).
    private func debugLaunch() {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true else { return }
        let d = UserDefaults.standard
        if d.bool(forKey: "debugSettings") { showSettings() }
        let n = d.integer(forKey: "debugSelect")
        guard n > 0 else { return }
        Task { @MainActor in
            while Store.shared.bank == nil { try? await Task.sleep(for: .milliseconds(200)) }
            Store.shared.selection = Set(Store.shared.lines.prefix(n).map(\.id))
            Store.shared.playSelection()
            if let dir = d.string(forKey: "debugExport") {
                try? await Task.sleep(for: .seconds(1))
                Store.shared.exportFolder = dir
                Store.shared.export(selectionOnly: !d.bool(forKey: "debugAll"))
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let u = urls.first { Store.shared.open(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { BusyFlag.set(false) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// Fenêtre principale : posée à l'écran sans activer l'appli (elle ne passe pas devant le travail en cours).
    private func showMain() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "mTALKIE"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 980, height: 620)
        w.backgroundColor = NSColor(Socle.C.bg)
        w.contentViewController = NSHostingController(rootView: ContentView())
        w.setContentSize(NSSize(width: 1180, height: 760))
        w.setFrameAutosaveName("mTALKIE.main")
        if !w.setFrameUsingName("mTALKIE.main") { w.socleCenter() }
        w.isReleasedWhenClosed = false
        window = w
        if NSApp.isActive { w.makeKeyAndOrderFront(nil) } else { w.orderFrontRegardless() }
    }

    @objc func showSettings() {
        if settings == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = L("set.title")
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(Socle.C.bg)
            w.setContentSize(w.contentViewController?.view.fittingSize ?? .zero)
            settings = w
        }
        if let w = settings, let main = window {
            w.setFrameOrigin(NSPoint(x: main.frame.midX - w.frame.width / 2, y: main.frame.midY - w.frame.height / 2))
        }
        settings?.present()
    }

    @objc func about() { About.show() }
    @objc func openFile() { Store.shared.chooseFile() }
    @objc func closeFile() { Store.shared.close() }
    @objc func exportSelection() { Store.shared.export(selectionOnly: true) }
    @objc func exportAll() { Store.shared.export(selectionOnly: false) }
    @objc func playPause() { Store.shared.playSelection() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let s = Store.shared
        switch item.action {
        case #selector(closeFile), #selector(playPause): return s.bank != nil
        case #selector(exportSelection): return s.bank != nil && !s.selection.isEmpty && !s.exporting
        case #selector(exportAll): return s.bank != nil && !s.exporting
        default: return true
        }
    }

    /// Sous-menu « Fichiers récents », rempli à chaque ouverture (la colonne de gauche ne les montre que sans fichier ouvert).
    private func recentItem() -> NSMenuItem {
        let i = NSMenuItem(title: L("menu.recent"), action: nil, keyEquivalent: "")
        let m = NSMenu(title: L("menu.recent")); m.delegate = self
        i.submenu = m
        return i
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == L("menu.recent") else { return }
        menu.removeAllItems()
        for u in Store.shared.recents {
            let i = NSMenuItem(title: u.lastPathComponent + " — " + u.deletingLastPathComponent().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = u
            menu.addItem(i)
        }
        if menu.items.isEmpty { menu.addItem(NSMenuItem(title: L("side.none"), action: nil, keyEquivalent: "")) }
    }

    @objc func openRecent(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { Store.shared.open(u) } }

    // MARK: Menus (pas de couleur dans le nom de l'appli à l'intérieur d'un menu)

    private func buildMenu() {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target ?? (action.map { _ in self as AnyObject })
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let top = NSMenuItem(); let m = NSMenu(title: title)
            items.forEach(m.addItem); top.submenu = m; main.addItem(top)
        }
        submenu("mTALKIE", [
            item(L("menu.about"), #selector(about)), .separator(),
            item(L("menu.settings"), #selector(showSettings), ","), .separator(),
            item(L("menu.hide"), #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item(L("menu.hideOthers"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item(L("menu.showAll"), #selector(NSApplication.unhideAllApplications(_:)), target: NSApp), .separator(),
            item(L("menu.quit"), #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
        submenu(L("menu.file"), [
            item(L("menu.open"), #selector(openFile), "o"),
            recentItem(),
            item(L("menu.close"), #selector(closeFile), "w", [.command, .shift]), .separator(),
            item(L("menu.exportSel"), #selector(exportSelection), "e"),
            item(L("menu.exportAll"), #selector(exportAll), "e", [.command, .shift]), .separator(),
            item(L("menu.closeWindow"), #selector(NSWindow.performClose(_:)), "w", target: nil),
        ])
        let edit: [NSMenuItem] = [
            item(L("menu.undo"), Selector(("undo:")), "z", target: nil),
            item(L("menu.redo"), Selector(("redo:")), "z", [.command, .shift], target: nil), .separator(),
            item(L("menu.cut"), #selector(NSText.cut(_:)), "x", target: nil),
            item(L("menu.copy"), #selector(NSText.copy(_:)), "c", target: nil),
            item(L("menu.paste"), #selector(NSText.paste(_:)), "v", target: nil),
            item(L("menu.selectAll"), #selector(NSText.selectAll(_:)), "a", target: nil),
        ]
        submenu(L("menu.edit"), edit)
        submenu(L("menu.window"), [
            item(L("menu.minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item(L("menu.zoom"), #selector(NSWindow.performZoom(_:)), target: nil),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }
}
