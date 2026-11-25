// mTALKIE — état de l'appli : fichier ouvert, sélection, récents, export.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var bank: SoundBank?
    @Published private(set) var lines: [Line] = [] { didSet { refreshRows() } }
    /// Lignes affichées (filtrées puis triées), recalculées seulement quand les répliques, le filtre ou le tri changent.
    @Published private(set) var rows: [Line] = []
    @Published var selection = Set<Line.ID>()
    @Published var filter = "" { didSet { refreshRows() } }
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    /// Formes d'onde déjà calculées (hors publication : les remplir ne redessine pas la liste).
    let peakCache = PeakCache()
    @Published private(set) var texts: ScriptTexts?          // textes des répliques (scripts du jeu)
    @Published private(set) var textsLoading = false
    @Published private(set) var hasNames = false              // éditions spéciales : répliques nommées
    @Published var showSettings = false

    // Export
    @Published private(set) var exporting = false
    @Published private(set) var exportDone = 0
    @Published private(set) var exportTotal = 0
    @Published private(set) var exportReport: ExportReport?
    private var exportTask: Task<Void, Never>?
    private var started = Date()

    @AppStorage("format") var formatRaw = ExportFormat.wav.rawValue
    @AppStorage("pattern") var pattern = "{file}_{n}"
    @AppStorage("subfolder") var subfolder = true
    @AppStorage("exportFolder") var exportFolder = ""
    @AppStorage("recents") private var recentsRaw = ""
    /// Fichier de textes choisi à la main pour un fichier de voix (autre langue) : chemin des voix → chemin des scripts.
    @AppStorage("textsChoice") private var textsChoiceRaw = ""
    /// Langue des textes choisie quand le jeu en propose plusieurs (vide : celle de l'interface).
    @AppStorage("xwbLang") private var textLang = ""

    let player = Player()
    private var completeTask: Task<Void, Never>?

    var format: ExportFormat {
        get { ExportFormat(rawValue: formatRaw) ?? .wav }
        set { formatRaw = newValue.rawValue }
    }

    var recents: [URL] { recentsRaw.split(separator: "\n").map { URL(fileURLWithPath: String($0)) } }

    /// Tri choisi en cliquant sur l'en-tête d'une colonne (N°, Durée, Décalage).
    @Published var sortOrder = [KeyPathComparator(\Line.id)] { didSet { sortGeneration &+= 1; refreshRows() } }

    var visibleLines: [Line] { rows }

    private func refreshRows() {
        let t0 = CFAbsoluteTimeGetCurrent()
        rows = Self.sorted(filteredLines, by: sortOrder.first)
        lastSortMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }
    private(set) var lastSortMs = 0.0
    /// Change à chaque nouveau tri : la liste est alors reconstruite d'un bloc au lieu de chercher le déplacement de chaque ligne.
    @Published private(set) var sortGeneration = 0

    /// Tri direct sur la colonne cliquée (le tri générique de Foundation, par chemins de clés, est des dizaines de fois plus lent).
    /// À égalité, l'ordre du fichier départage : le tri reste stable d'un clic à l'autre.
    static func sorted(_ list: [Line], by c: KeyPathComparator<Line>?) -> [Line] {
        guard let c else { return list }
        let asc = c.order == .forward
        func by<T: Comparable>(_ f: (Line) -> T) -> [Line] {
            list.sorted { a, b in
                let x = f(a), y = f(b)
                if x == y { return a.id < b.id }
                return asc ? x < y : x > y
            }
        }
        switch c.keyPath {
        case \Line.id: return asc ? list.sorted { $0.id < $1.id } : list.sorted { $0.id > $1.id }
        case \Line.duration: return by { $0.duration }
        case \Line.offset: return by { $0.offset }
        case \Line.name: return by { $0.name }
        case \Line.text: return by { $0.text }
        default: return list.sorted(using: c)
        }
    }

    private var filteredLines: [Line] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return lines }
        if f.hasPrefix(">"), let s = Double(f.dropFirst().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) {
            return lines.filter { $0.duration > s }
        }
        let low = f.lowercased()
        return lines.filter {
            String(format: "%04d", $0.id).contains(low) || String(format: "%08x", $0.offset).contains(low)
                || $0.text.range(of: f, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.name.range(of: f, options: .caseInsensitive) != nil
        }
    }

    var destination: URL {
        if !exportFolder.isEmpty { return URL(fileURLWithPath: exportFolder) }
        return FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
    }

    /// Dossier où l'export écrira : dossier choisi, plus le sous-dossier du jeu si l'option est cochée.
    var finalFolder: URL {
        guard subfolder, let b = bank else { return destination }
        return destination.appendingPathComponent(Self.folderName(b))
    }

    /// Chemin affiché comme le Finder (noms de dossiers dans la langue du système, « ~ » pour le dossier personnel).
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var path = url.standardizedFileURL.path
        var prefix = ""
        if path.hasPrefix(home) { prefix = "~"; path = String(path.dropFirst(home.count)) }
        var built = prefix.isEmpty ? "" : home
        var parts: [String] = []
        for c in path.split(separator: "/") {
            built += "/" + c
            parts.append(FileManager.default.fileExists(atPath: built) ? FileManager.default.displayName(atPath: built) : String(c))
        }
        return prefix + "/" + parts.joined(separator: "/")
    }

    /// Modèle de nom affiché avec les balises de la langue de l'interface ({fichier}, {n°}, {décalage} en français).
    var localPattern: String {
        get { Pattern.localize(pattern) }
        set { pattern = Pattern.canonical(newValue) }
    }

    // MARK: Ouverture

    /// Fichier de voix, ou dossier de jeu où MONSTER.* (ou tout .SOU/.SO3/.SOG/.SOF) est cherché.
    func open(_ url: URL) {
        let target: URL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            guard let found = Self.findBank(in: url) else { error = L("err.nofolder"); return }
            target = found
        } else { target = url }
        player.stop()
        completeTask?.cancel()
        loading = true; error = nil
        Task.detached(priority: .userInitiated) {
            do {
                let b = try SoundBank(url: target)
                await MainActor.run { self.loaded(b) }
            } catch {
                await MainActor.run { self.loading = false; self.error = "\(target.lastPathComponent) : \(error.localizedDescription)" }
            }
        }
    }

    private func loaded(_ b: SoundBank) {
        peakCache.clear()
        bank = b; lines = b.lines; selection = []; loading = false; texts = nil
        hasNames = b.lines.contains { !$0.name.isEmpty }
        addRecent(b.url)
        if b.lines.contains(where: { $0.rate == 0 }) { completeDurations(b) }
        if b.codec == .xwb || b.codec == .bun || b.codec == .aud || b.codec == .lab || b.codec == .gg || b.codec == .sword1 || b.codec == .aufs { namedSets = [:]; namedOrder = []; namedURL = nil; loadNamedTexts(b); return }
        let chosen = textsChoice[b.url.path].map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        if let t = chosen ?? ScriptTexts.find(near: b.url) { loadTexts(t, for: b, report: chosen != nil) }
    }

    func close() { player.stop(); bank = nil; lines = []; selection = []; peakCache.clear(); texts = nil; hasNames = false }

    // MARK: Textes

    private var textsChoice: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(textsChoiceRaw.utf8))) ?? [:] }
        set { textsChoiceRaw = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    }

    /// Lit les textes en arrière-plan ; `report` : signaler un échec (fichier choisi à la main).
    private func loadTexts(_ url: URL, for b: SoundBank, report: Bool) {
        let offsets = Set(b.lines.map(\.offset))
        textsLoading = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try ScriptTexts.load(url, offsets: offsets) }
            await MainActor.run {
                guard self.bank === b else { return }
                self.textsLoading = false
                switch result {
                case .success(let t):
                    self.texts = t
                    var copy = self.lines
                    for i in copy.indices { copy[i].text = t.texts[copy[i].offset] ?? "" }
                    self.lines = copy
                case .failure(let e):
                    if report { self.error = "\(url.lastPathComponent) : \(e.localizedDescription)" }
                }
            }
        }
    }

    /// Textes liés aux répliques par leur nom, dans plusieurs langues :
    /// éditions spéciales (speech.info, 5 langues) et archives .BUN (scripts du jeu + LANGUAGE.BND).
    private func loadNamedTexts(_ b: SoundBank) {
        let lines = b.lines
        textsLoading = true
        Task.detached(priority: .userInitiated) {
            var url: URL?
            var sets: [(String, [Int: String])] = []
            if b.codec == .xwb, let info = Xact.infoFile(for: b.url) {
                let dict = Xact.infoTexts(info)
                var names: [Int: String] = [:]
                for l in lines where !l.name.isEmpty { names[l.offset] = l.name }
                if !dict.isEmpty {
                    url = info
                    sets = Xact.infoLanguages.map { ($0, Xact.texts(names: names, info: dict, language: $0)) }
                }
            } else if b.codec == .aud {
                let dict = Sierra.texts(dir: b.url.deletingLastPathComponent())
                var t: [Int: String] = [:]
                for l in lines { if let x = dict[l.name] { t[l.offset] = x } }
                if !t.isEmpty { url = b.url.deletingLastPathComponent().appendingPathComponent("RESOURCE.000"); sets = [(Sierra.detect(dict), t)] }
            } else if b.codec == .lab {
                let dict = Grime.texts(dir: b.url.deletingLastPathComponent())
                var t: [Int: String] = [:]
                for l in lines { if let x = dict[l.name.lowercased()] { t[l.offset] = x } }
                if !t.isEmpty { url = b.url.deletingLastPathComponent().appendingPathComponent("artAll.m4b"); sets = [(Grime.detect(dict), t)] }
            } else if b.codec == .aufs, let found = Aufs.textSets(near: b.url) {
                url = found.url
                sets = found.sets.map { lang, dict in
                    var t: [Int: String] = [:]
                    for l in lines { if let x = dict[l.offset] { t[l.offset] = x } }
                    return (lang, t)
                }.filter { !$0.1.isEmpty }
            } else if b.codec == .sword1, let found = Sword1.textSets(near: b.url) {
                url = found.url
                sets = found.sets.map { lang, dict in
                    var t: [Int: String] = [:]
                    for l in lines { if let x = dict[l.offset] { t[l.offset] = x } }
                    return (lang, t)
                }.filter { !$0.1.isEmpty }
            } else if b.codec == .gg, let found = GGPack.textSets(near: b.url) {
                url = found.url
                sets = found.sets.map { lang, dict in
                    var t: [Int: String] = [:]
                    for l in lines { if let id = GGPack.id(l.name), let x = dict[String(id)] { t[l.offset] = x } }
                    return (lang, t)
                }.filter { !$0.1.isEmpty }
            } else if b.codec == .bun, let found = BunArchive.textSets(near: b.url) {
                url = found.url
                sets = found.sets.map { lang, dict in
                    var t: [Int: String] = [:]
                    for l in lines { if let x = dict[l.name.uppercased()] { t[l.offset] = x } }
                    return (lang, t)
                }.filter { !$0.1.isEmpty }
            }
            let found = url, all = sets
            await MainActor.run {
                guard self.bank === b else { return }
                self.textsLoading = false
                guard let found, !all.isEmpty else { return }
                self.namedURL = found
                self.namedSets = Dictionary(all, uniquingKeysWith: { a, _ in a })
                self.namedOrder = all.map(\.0)
                self.applyNamedTexts()
            }
        }
    }

    private var namedSets: [String: [Int: String]] = [:]
    private var namedOrder: [String] = []
    private var namedURL: URL?

    private func applyNamedTexts() {
        guard let url = namedURL, let first = namedOrder.first else { return }
        let lang = namedOrder.contains(textLang) ? textLang : (namedOrder.contains(Loc.lang) ? Loc.lang : first)
        let t = namedSets[lang] ?? [:]
        texts = ScriptTexts(url: url, texts: t, language: lang, languages: namedOrder.count > 1 ? namedOrder : [])
        var copy = lines
        for i in copy.indices { copy[i].text = t[copy[i].offset] ?? "" }
        lines = copy
    }

    /// Autre langue des textes (même fichier ou fichier voisin), retenue pour les prochaines ouvertures.
    func setTextLanguage(_ code: String) {
        textLang = code
        applyNamedTexts()
    }

    /// Textes d'une autre édition du jeu (autre langue) : son fichier de scripts, à garder pour ce fichier de voix.
    func chooseTexts() {
        guard let b = bank else { return }
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false; p.canChooseDirectories = false
        p.message = L("open.texts")
        p.directoryURL = texts?.url.deletingLastPathComponent() ?? b.url.deletingLastPathComponent()
        guard p.runModal() == .OK, let u = p.url else { return }
        var c = textsChoice; c[b.url.path] = u.path; textsChoice = c
        loadTexts(u, for: b, report: true)
    }

    static let extensions = ["sou", "so3", "sog", "sof", "xwb", "bun", "aud", "m4b", "ggpack1", "ggpack2", "ggpack3", "ggpack4", "ggpack5", "clv", "clf", "cl3", "osa"]

    static func findBank(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [URL] = []
        for case let u as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            if extensions.contains(u.pathExtension.lowercased()) || Aufs.isSpeech(u) { candidates.append(u) }
        }
        // MONSTER.* (versions CD), puis Speech.xwb (éditions spéciales), sinon le premier fichier trouvé
        let stem = { (u: URL) in u.deletingPathExtension().lastPathComponent.uppercased() }
        return candidates.first { stem($0) == "MONSTER" } ?? candidates.first { stem($0) == "SPEECH" } ?? candidates.first { stem($0) == "VOICEALL" }
            ?? candidates.first { stem($0).contains("VOICE") || stem($0).hasPrefix("VOX") }
            ?? candidates.first { $0.pathExtension.lowercased() == "ggpack2" } ?? candidates.first { stem($0) == "SPEECH1" }
            ?? candidates.first { stem($0) == "ENGLISH" && Aufs.isSpeech($0) } ?? candidates.first { stem($0) == "SPEECH_ENGLISH" }
            ?? candidates.first { $0.lastPathComponent.lowercased() != "sfx.osa" }
    }

    private func addRecent(_ url: URL) {
        var r = recents.map(\.path).filter { $0 != url.path }
        r.insert(url.path, at: 0)
        recentsRaw = r.prefix(8).joined(separator: "\n")
    }

    func chooseFile() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.allowsMultipleSelection = false
        p.message = L("open.message")
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    /// Formats compressés : durée et fréquence connues seulement après décodage, fait en arrière-plan.
    /// Mises à jour groupées (toutes les 300 répliques) : la liste n'est redessinée que quelques fois.
    private func completeDurations(_ b: SoundBank) {
        let pending = b.lines
        let cache = peakCache
        completeTask = Task.detached(priority: .utility) {
            var batch: [(Int, Double, Double)] = []
            func flush() async {
                let done = batch; batch = []
                await MainActor.run {
                    guard self.bank === b else { return }
                    var copy = self.lines
                    var index: [Int: Int] = [:]
                    for (i, l) in copy.enumerated() { index[l.id] = i }
                    for (id, rate, duration) in done {
                        b.update(id, rate: rate, duration: duration)
                        if let i = index[id] { copy[i].rate = rate; copy[i].duration = duration }
                    }
                    self.lines = copy
                }
            }
            for line in pending {
                if Task.isCancelled { return }
                guard let pcm = try? b.decode(line) else { continue }
                cache.set(line.id, Peaks.compute(pcm, count: 64))
                batch.append((line.id, pcm.rate, pcm.duration))
                if batch.count >= 300 { await flush() }
            }
            if !batch.isEmpty { await flush() }
        }
    }

    // MARK: Écoute

    func play(_ id: Line.ID) {
        guard let b = bank, let line = lines.first(where: { $0.id == id }) else { return }
        if player.playing == id { player.toggle(); return }
        do { player.play(line, pcm: try b.decode(line)) } catch { self.error = error.localizedDescription }
    }

    func playSelection() {
        if let id = selection.sorted().first { play(id) } else if player.playing != nil { player.toggle() }
    }

    /// Forme d'onde d'une ligne, calculée à la demande (VOC : immédiat ; compressé : rempli par le décodage de fond).
    /// Forme d'onde d'une réplique, calculée hors du fil principal puis gardée en cache.
    func peaks(for line: Line) async -> [Float] {
        if let p = peakCache.get(line.id) { return p }
        guard let b = bank else { return [] }
        let cache = peakCache
        return await Task.detached(priority: .userInitiated) {
            let p = (try? b.decode(line)).map { Peaks.compute($0, count: 64) } ?? []
            cache.set(line.id, p)
            return p
        }.value
    }

    // MARK: Export

    struct ExportReport { var ok: Int; var skipped: [(Line, String)]; var folder: URL; var cancelled: Bool }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = destination
        if p.runModal() == .OK, let u = p.url { exportFolder = u.path }
    }

    var remaining: String {
        guard exportDone > 0 else { return "" }
        let per = Date().timeIntervalSince(started) / Double(exportDone)
        return L("export.remaining", Int((per * Double(exportTotal - exportDone)).rounded(.up)))
    }

    func export(selectionOnly: Bool) {
        guard let b = bank, !exporting else { return }
        let todo = selectionOnly ? lines.filter { selection.contains($0.id) } : lines
        guard !todo.isEmpty else { return }
        let folder = finalFolder
        let fmt = format, pat = pattern
        exporting = true; exportDone = 0; exportTotal = todo.count; exportReport = nil; started = Date()
        BusyFlag.set(true)
        exportTask = Task.detached(priority: .userInitiated) {
            var skipped: [(Line, String)] = []
            var ok = 0
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            catch {
                await MainActor.run { self.finish(ExportReport(ok: 0, skipped: [(todo[0], error.localizedDescription)], folder: folder, cancelled: false)) }
                return
            }
            await withTaskGroup(of: (Line, String?).self) { group in
                var it = todo.makeIterator()
                func add() -> Bool {
                    guard let line = it.next() else { return false }
                    group.addTask {
                        do {
                            let pcm = try b.decode(line)
                            try Encoder.write(pcm, to: folder.appendingPathComponent(Encoder.name(pattern: pat, source: b.url, line: line, format: fmt)), format: fmt)
                            return (line, nil)
                        } catch { return (line, error.localizedDescription) }
                    }
                    return true
                }
                for _ in 0 ..< 4 { _ = add() }
                while let (line, err) = await group.next() {
                    if let err { skipped.append((line, err)) } else { ok += 1 }
                    let done = ok + skipped.count
                    if done % 25 == 0 || done == todo.count { await MainActor.run { self.exportDone = done } }
                    if Task.isCancelled { group.cancelAll(); break }
                    _ = add()
                }
            }
            let report = ExportReport(ok: ok, skipped: skipped.sorted { $0.0.id < $1.0.id }, folder: folder, cancelled: Task.isCancelled)
            await MainActor.run { self.finish(report) }
        }
    }

    private func finish(_ r: ExportReport) {
        exporting = false; exportReport = r; exportTask = nil
        BusyFlag.set(false)
    }

    func cancelExport() { exportTask?.cancel() }
    func dismissReport() { exportReport = nil }

    static func folderName(_ b: SoundBank) -> String {
        if let g = SoundBank.game(for: b.url)?.short { return g.replacingOccurrences(of: ":", with: " -") }   // « ~/Musique/DOTT », comme la maquette
        return b.url.deletingLastPathComponent().lastPathComponent
    }

    /// Fichier temporaire pour glisser une ligne vers le Finder.
    func dragFile(_ id: Line.ID) -> URL? {
        guard let b = bank, let line = lines.first(where: { $0.id == id }), let pcm = try? b.decode(line) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mTALKIE-drag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Encoder.name(pattern: pattern, source: b.url, line: line, format: .wav))
        do { try WavWriter.data(pcm).write(to: url); return url } catch { return nil }
    }

    func clearError() { error = nil }
}

/// Fichier témoin d'un export en cours : ni la mise à jour automatique ni le script de build n'interrompent un export.
enum BusyFlag {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".mtalkie-busy")
    static func set(_ on: Bool) {
        if on { FileManager.default.createFile(atPath: url.path, contents: nil) } else { try? FileManager.default.removeItem(at: url) }
    }
}


/// Cache des formes d'onde, partagé entre le fil principal et les calculs en arrière-plan.
final class PeakCache: @unchecked Sendable {
    private var store: [Int: [Float]] = [:]
    private let lock = NSLock()
    func get(_ id: Int) -> [Float]? { lock.lock(); defer { lock.unlock() }; return store[id] }
    func set(_ id: Int, _ p: [Float]) { lock.lock(); store[id] = p; lock.unlock() }
    func clear() { lock.lock(); store = [:]; lock.unlock() }
}
