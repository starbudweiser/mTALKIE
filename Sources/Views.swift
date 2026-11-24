// mTALKIE — interface (Socle standard : sombre, plat, dense), fidèle aux maquettes validées (maquettes/detail.html).
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var store = Store.shared
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            HStack(spacing: 0) {
                Sidebar().frame(width: 270)
                Rectangle().fill(Socle.C.border).frame(width: 1)
                MainArea(dropHover: dropHover)
            }
            FooterBar()
        }
        .background(Socle.C.bg)
        .foregroundStyle(Socle.C.text)
        .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in Store.shared.open(url) } }
            }
            return true
        }
        .sheet(isPresented: Binding(get: { store.exporting || store.exportReport != nil }, set: { if !$0 { store.dismissReport() } })) {
            ExportSheet()
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

// MARK: - En-tête (A : Ouvrir seul ; B : jeu · CD + Ouvrir)

struct HeaderBar: View {
    @ObservedObject private var store = Store.shared
    var body: some View {
        HStack(spacing: Socle.M.space3) {
            Text(branded: "mTALKIE").socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            Spacer()
            if let b = store.bank {
                Text(b.codec == .xwb ? (b.gameName ?? b.url.deletingLastPathComponent().lastPathComponent)
                     : L("game.cd", b.gameName ?? b.url.deletingLastPathComponent().lastPathComponent))
                    .socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1)
            }
            Button(L("btn.open")) { store.chooseFile() }.buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
        }
        .padding(.leading, 84).padding(.trailing, Socle.M.space3)
        .frame(height: Socle.M.sizeBar)
        .background(Socle.C.surfaceRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(Socle.C.border).frame(height: 1) }
    }
}

// MARK: - Colonne de gauche (A : Récents ; B : Fichier + Export)

struct Sidebar: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Socle.M.space4) {
                if let b = store.bank {
                    FileCard(bank: b)
                    ExportCard()
                } else {
                    VStack(alignment: .leading, spacing: Socle.M.space1) {
                        SectionTitle(L("side.recent"))
                        if store.recents.isEmpty { Text(L("side.none")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted) }
                        ForEach(store.recents, id: \.self) { u in RecentRow(url: u) }
                    }
                }
            }
            .padding(Socle.M.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .socleWatermark { TalkieMark() }
        .background(Socle.C.surfaceRaised)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).socle(Socle.T.caption).fontWeight(.semibold).tracking(0.6).foregroundStyle(Socle.C.textMuted)
    }
}

struct KV: View {
    let k: String; let v: String; var color: Color = Socle.C.text
    var body: some View {
        HStack { Text(k).foregroundStyle(Socle.C.textMuted); Spacer(minLength: 8); Text(v).foregroundStyle(color).fontWeight(.semibold).lineLimit(1).monospacedDigit() }
            .socle(Socle.T.body)
    }
}

struct FileCard: View {
    let bank: SoundBank
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space1_5) {
            SectionTitle(L("side.file"))
            Text(bank.url.lastPathComponent).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).lineLimit(1).truncationMode(.middle)
                .help(bank.url.path)
            KV(k: L("info.format"), v: bank.codec == .voc ? L("info.voc") : bank.codec == .xwb ? bank.xwbFormat : bank.codec.rawValue.uppercased())
            KV(k: L("info.lines"), v: store.lines.count.formatted(.number.locale(Loc.locale)))
            KV(k: L("info.duration"), v: pending ? L("info.pending") : Fmt.long(store.lines.reduce(0) { $0 + $1.duration }))
            KV(k: L("info.rate"), v: rate)
            let bad = store.lines.filter { !$0.supported }.count
            KV(k: L("info.decode"), v: bad == 0 ? L("info.complete") : L("info.partial", bad), color: bad == 0 ? Socle.C.success : Socle.C.warning)
            KV(k: L("info.texts"), v: textsValue, color: store.texts == nil ? Socle.C.textMuted : Socle.C.text)
                .help(store.texts.map { L("info.texts.help", $0.url.lastPathComponent, $0.texts.count) } ?? L("info.texts.none.help"))
            if let t = store.texts, !t.languages.isEmpty {
                // Éditions spéciales : toutes les langues sont dans le même fichier
                Menu {
                    ForEach(t.languages, id: \.self) { code in
                        Button { store.setTextLanguage(code) } label: {
                            let name = Loc.locale.localizedString(forLanguageCode: code)?.capitalized(with: Loc.locale) ?? code
                            if code == t.language { Label(name, systemImage: "checkmark") } else { Text(name) }
                        }
                    }
                } label: { Text(L("btn.textsLang")).socle(Socle.T.meta).foregroundStyle(Socle.C.accentText) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Button(L("btn.texts")) { store.chooseTexts() }
                    .buttonStyle(.plain).socle(Socle.T.meta).foregroundStyle(Socle.C.accentText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(L("btn.texts.help"))
            }
        }
    }

    private var textsValue: String {
        if store.textsLoading { return L("info.pending") }
        guard let t = store.texts else { return L("info.texts.none") }
        let n = t.texts.count.formatted(.number.locale(Loc.locale))
        return [t.languageName, n].compactMap { $0 }.joined(separator: " · ")
    }

    private var pending: Bool { store.lines.contains { $0.rate == 0 } }
    private var rate: String {
        var counts: [Double: Int] = [:]
        for l in store.lines where l.rate > 0 { counts[l.rate, default: 0] += 1 }
        guard let r = counts.max(by: { $0.value < $1.value })?.key else { return L("info.pending") }
        return Fmt.hz(r)
    }
}

struct ExportCard: View {
    @ObservedObject private var store = Store.shared
    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space1_5) {
            SectionTitle(L("side.export"))
            Text(L("info.format")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            SocleSegmented(options: ExportFormat.allCases, selection: store.format, label: { $0.label }) { store.format = $0 }
            HStack {
                Text(L("info.dest")).foregroundStyle(Socle.C.textMuted)
                Spacer(minLength: 8)
                // Le chemin lui-même ouvre le choix du dossier
                Button { store.chooseFolder() } label: {
                    Text(Store.displayPath(store.finalFolder)).fontWeight(.semibold).foregroundStyle(Socle.C.accentText)
                        .lineLimit(1).truncationMode(.head)
                }.buttonStyle(.plain).help(store.finalFolder.path)
            }
            .socle(Socle.T.body).padding(.top, Socle.M.space1)
        }
    }
}

struct RecentRow: View {
    let url: URL
    @State private var hover = false
    var body: some View {
        Button { Store.shared.open(url) } label: {
            HStack {
                Text(url.lastPathComponent).foregroundStyle(Socle.C.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(SoundBank.game(for: url)?.short ?? url.deletingLastPathComponent().lastPathComponent).foregroundStyle(Socle.C.textMuted).lineLimit(1).truncationMode(.middle)
            }
            .socle(Socle.T.body)
            .padding(.vertical, 3)
            .background(hover ? Socle.C.surfaceHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(url.path)
    }
}

// MARK: - Zone principale

struct MainArea: View {
    @ObservedObject private var store = Store.shared
    let dropHover: Bool

    var body: some View {
        VStack(spacing: Socle.M.space2) {
            if let e = store.error { ErrorBanner(text: e) }
            if store.loading {
                Spacer(); ProgressView().controlSize(.small); Spacer()
            } else if store.bank == nil {
                DropZone(hover: dropHover)
            } else {
                LinesToolbar()
                LinesTable()
            }
        }
        .padding(Socle.M.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: Socle.M.space2) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Socle.C.danger)
            Text(text).socle(Socle.T.body).foregroundStyle(Socle.C.textStrong)
            Spacer()
            Button { Store.shared.clearError() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Socle.C.textMuted)
        }
        .padding(Socle.M.space2_5)
        .background(Socle.C.dangerBg, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.dangerBorder))
    }
}

struct DropZone: View {
    let hover: Bool
    var body: some View {
        VStack(spacing: Socle.M.space2) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 34, weight: .medium)).foregroundStyle(Socle.C.accentText)
            Text(L("drop.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            Text(L("drop.formats")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            Text(L("drop.folder")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            Button(L("btn.choose")) { Store.shared.chooseFile() }.buttonStyle(SocleButtonStyle(.primary)).fixedSize().padding(.top, Socle.M.space2)
        }
        .padding(Socle.M.space6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hover ? Socle.C.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Socle.M.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusLg).strokeBorder(hover ? Socle.C.accent : Socle.C.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
    }
}

struct LinesToolbar: View {
    @ObservedObject private var store = Store.shared
    var body: some View {
        HStack(spacing: Socle.M.space2) {
            HStack(spacing: Socle.M.space2) {
                Image(systemName: "magnifyingglass").foregroundStyle(Socle.C.textMuted)
                TextField(L("filter.placeholder"), text: $store.filter).textFieldStyle(.plain).socle(Socle.T.body)
            }
            .padding(.horizontal, Socle.M.space3).frame(height: 30)
            .background(Socle.C.bgSunken)
            .help(L("filter.help"))
            let all = !store.selection.isEmpty && store.selection.count == store.visibleLines.count
            Button(all ? L("btn.selectNone") : L("btn.selectAll")) {
                store.selection = all ? [] : Set(store.visibleLines.map(\.id))
            }.buttonStyle(SocleButtonStyle(.secondary, height: 30)).fixedSize()
        }
    }
}

/// Liste des répliques : case, lecture, N°, forme d'onde, durée, décalage (maquette B).
struct LinesTable: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var player = Store.shared.player

    var body: some View {
        Table(of: Line.self, selection: $store.selection, sortOrder: $store.sortOrder) {
            TableColumn("") { line in
                let on = store.selection.contains(line.id)
                Button { if on { store.selection.remove(line.id) } else { store.selection.insert(line.id) } } label: {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(on ? Socle.C.onAccentFill : .clear)
                        .frame(width: 14, height: 14)
                        .background(on ? Socle.C.accentFill : .clear, in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? Socle.C.accentFill : Socle.C.borderControl, lineWidth: 1.2))
                }.buttonStyle(.plain)
            }.width(20)
            TableColumn("") { line in
                let current = player.playing == line.id
                Button { store.play(line.id) } label: {
                    Image(systemName: current && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 9)).frame(width: 18, height: 18)
                        .foregroundStyle(current ? Socle.C.accentText : Socle.C.text)
                }.buttonStyle(.plain)
            }.width(20)
            TableColumn(L("col.n"), value: \.id) { line in Text(String(format: "%04d", line.id)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted) }.width(48)
            if store.texts != nil {
                TableColumn(L("col.text"), value: \.text) { line in
                    Text(line.text.isEmpty ? "—" : line.text).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(line.text.isEmpty ? Socle.C.textMuted : Socle.C.text)
                        .help(line.text)
                }.width(min: 160, ideal: store.hasNames ? 280 : 360)
            }
            TableColumn(L("col.wave")) { line in
                WaveView(peaks: store.peaks[line.id] ?? [], highlight: player.playing == line.id)
                    .frame(height: 18)
                    .onAppear { store.requestPeaks(line.id) }
            }.width(min: 80, ideal: store.texts != nil ? 120 : 400, max: store.texts != nil ? 160 : .infinity)
            TableColumn(L("col.duration"), value: \.duration) { line in
                Text(line.rate > 0 ? Fmt.short(line.duration) : "…").monospacedDigit()
                    .foregroundStyle(line.supported ? Socle.C.text : Socle.C.warning)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(64)
            if store.hasNames {
                TableColumn(L("col.name"), value: \.name) { line in
                    Text(line.name).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted).lineLimit(1).textSelection(.enabled).help(line.name)
                }.width(min: 110, ideal: 170)
            }
            if !store.hasNames {
                TableColumn(L("col.offset"), value: \.offset) { line in
                    Text(String(format: "0x%06X", line.offset)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                        .frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
                }.width(86)
            }
        } rows: {
            ForEach(store.visibleLines) { line in
                TableRow(line).itemProvider { DragExport.provider(for: line.id) }
            }
        }
        .contextMenu(forSelectionType: Line.ID.self) { ids in
            Button(L("menu.play")) { if let id = ids.sorted().first { store.play(id) } }
            Button(L("menu.exportSel")) { store.selection = ids; store.export(selectionOnly: true) }
        } primaryAction: { ids in
            if let id = ids.sorted().first { store.play(id) }
        }
        .onKeyPress(.space) { store.playSelection(); return .handled }
        .scrollContentBackground(.hidden)
        .background(Socle.C.surface)
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border))
        .socle(Socle.T.body)
    }
}

enum DragExport {
    /// Glisser une ligne vers le Finder : fichier WAV écrit à la demande.
    static func provider(for id: Line.ID) -> NSItemProvider {
        let p = NSItemProvider()
        p.suggestedName = String(format: "%04d", id)
        p.registerFileRepresentation(forTypeIdentifier: UTType.wav.identifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                if let url = Store.shared.dragFile(id) { done(url, false, nil) } else { done(nil, false, CocoaError(.fileWriteUnknown)) }
            }
            return nil
        }
        return p
    }
}

struct WaveView: View {
    let peaks: [Float]
    var highlight = false

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let w = size.width / CGFloat(peaks.count)
            for (i, p) in peaks.enumerated() {
                let h = max(1.5, CGFloat(p.squareRoot()) * size.height)
                let rect = CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(1, w * 0.6), height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(highlight ? Socle.C.accentText : Socle.C.textMuted.opacity(0.55)))
            }
        }
    }
}

// MARK: - Barre du bas (A : mention « aucun fichier modifié » ; B : lecteur + export)

struct FooterBar: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var player = Store.shared.player

    var body: some View {
        HStack(spacing: Socle.M.space2) {
            if store.bank == nil {
                Text(L("safe")).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                Spacer()
            } else {
                Button { if player.playing != nil { player.toggle() } else { store.playSelection() } } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 11))
                        .foregroundStyle(Socle.C.accentText).frame(width: 18, height: 18)
                }.buttonStyle(.plain)
                if let id = player.playing {
                    Text("\(String(format: "%04d", id)) · \(Fmt.short(player.position)) / \(Fmt.short(player.duration))")
                        .socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                } else {
                    Text(L("player.none")).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted).lineLimit(1)
                }
                Spacer()
                Text(store.selection.isEmpty ? L("count.lines", store.lines.count) : L("count.selected", store.selection.count))
                    .socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).fixedSize()
                Button(L("btn.exportSel")) { store.export(selectionOnly: true) }
                    .buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                    .disabled(store.selection.isEmpty || store.exporting)
                Button(L("btn.exportAll")) { store.export(selectionOnly: false) }
                    .buttonStyle(SocleButtonStyle(.action, height: 28)).fixedSize()
                    .disabled(store.exporting)
            }
        }
        .padding(.horizontal, Socle.M.space3).frame(height: 44)
        .background(Socle.C.surfaceRaised)
        .overlay(alignment: .top) { Rectangle().fill(Socle.C.border).frame(height: 1) }
    }
}

// MARK: - Feuille d'export (maquette C : progression, puis ligne « Fin »)

struct ExportSheet: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        let r = store.exportReport
        let done = r.map { $0.ok + $0.skipped.count } ?? store.exportDone
        VStack(alignment: .leading, spacing: Socle.M.space2_5) {
            Text(r == nil ? L("export.title") : (r!.cancelled ? L("export.cancelled") : L("export.done")))
                .socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            (Text(L("export.sub", store.exportTotal, store.format.label) + " ").foregroundStyle(Socle.C.textMuted)
             + Text(Store.displayPath(r?.folder ?? store.finalFolder)).foregroundStyle(Socle.C.accentText))
                .socle(Socle.T.body).lineLimit(2)
            ProgressView(value: Double(done), total: Double(max(1, store.exportTotal)))
                .progressViewStyle(.linear).tint(Socle.C.accentText)
            HStack {
                Text("\(done.formatted(.number.locale(Loc.locale))) / \(store.exportTotal.formatted(.number.locale(Loc.locale)))")
                    .foregroundStyle(Socle.C.textMuted).monospacedDigit()
                Spacer()
                if r == nil { Text(store.remaining).fontWeight(.semibold).foregroundStyle(Socle.C.textStrong) }
            }.socle(Socle.T.body)
            HStack {
                Text(L("export.names")).foregroundStyle(Socle.C.textMuted)
                Spacer()
                Text(sampleName).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
            }.socle(Socle.T.body)
            HStack {
                Spacer()
                if r == nil {
                    Button(L("btn.cancel")) { store.cancelExport() }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                } else {
                    Button(L("btn.close")) { store.dismissReport() }.buttonStyle(SocleButtonStyle(.primary, height: 28)).fixedSize()
                        .keyboardShortcut(.defaultAction)
                }
                Spacer()
            }
            if let r {
                Rectangle().fill(Socle.C.border).frame(height: 1)
                HStack(spacing: 4) {
                    Text(L("export.end")).foregroundStyle(Socle.C.textMuted)
                    Text(L("export.ok", r.ok)).foregroundStyle(Socle.C.success)
                    if !r.skipped.isEmpty {
                        Text("·").foregroundStyle(Socle.C.textMuted)
                        Text(L("export.skipped", r.skipped.count)).foregroundStyle(Socle.C.warning)
                            .help(r.skipped.map { String(format: "%04d · 0x%06X — ", $0.0.id, $0.0.offset) + $0.1 }.joined(separator: "\n"))
                    }
                    Text("·").foregroundStyle(Socle.C.textMuted)
                    Button(L("btn.finder")) { NSWorkspace.shared.activateFileViewerSelecting([r.folder]) }
                        .buttonStyle(.plain).foregroundStyle(Socle.C.accentText)
                }.socle(Socle.T.body)
            }
        }
        .padding(Socle.M.space6)
        .frame(width: 440)
        .background(Socle.C.surface)
    }

    private var sampleName: String {
        guard let b = Store.shared.bank, let first = Store.shared.lines.first else { return "" }
        return Encoder.name(pattern: Store.shared.pattern, source: b.url, line: first, format: Store.shared.format) + "…"
    }
}

// MARK: - Réglages (maquette D)

struct SettingsView: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Socle.M.space3) {
                SettingsCard(title: L("set.export")) {
                    row(L("set.format")) {
                        SocleSegmented(options: ExportFormat.allCases, selection: store.format, label: { $0.label }) { store.format = $0 }
                    }
                    row(L("set.pattern")) {
                        TextField("", text: Binding(get: { store.localPattern }, set: { store.localPattern = $0 }))
                            .textFieldStyle(.plain).socle(Socle.T.mono).foregroundStyle(Socle.C.accentText)
                            .padding(.horizontal, Socle.M.space3).frame(width: 220, height: 28).background(Socle.C.bgSunken)
                            .help(Pattern.localize(L("set.pattern.help")))
                    }
                    row(L("set.variant")) {
                        let t = Pattern.local
                        Button { store.localPattern = "\(t[1])_\(t[2])" } label: {
                            Text(L("set.variant.value", t[1], t[2])).foregroundStyle(Socle.C.textMuted)
                        }.buttonStyle(.plain).socle(Socle.T.body).help(L("set.variant.help"))
                    }
                    row(L("set.subfolder")) { Toggle("", isOn: $store.subfolder).toggleStyle(.switch).tint(Socle.C.success).labelsHidden().controlSize(.small) }
                }
                SettingsCard(title: L("upd.title")) { UpdateSection() }
            }
            .padding(Socle.M.space6)
            HStack {
                Text(L("set.lang")).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                Spacer()
            }
            .padding(.horizontal, Socle.M.space4).frame(height: 36)
            .background(Socle.C.surfaceRaised)
            .overlay(alignment: .top) { Rectangle().fill(Socle.C.border).frame(height: 1) }
        }
        .frame(width: 600)
        .background(Socle.C.bg)
        .foregroundStyle(Socle.C.text)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(label).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted); Spacer(); c() }.padding(.vertical, 3)
    }
}

struct SettingsCard<C: View>: View {
    let title: String
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space1) {
            SectionTitle(title).padding(.bottom, 2)
            content
        }
        .padding(.horizontal, Socle.M.space4).padding(.vertical, Socle.M.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border))
    }
}

struct UpdateSection: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject private var store = Store.shared
    @AppStorage("autoUpdate") private var auto = true

    private var status: String {
        switch updater.state {
        case .idle: return L("upd.version.short", updater.currentVersion)
        case .checking: return L("upd.checking")
        case .upToDate: return L("upd.uptodate.short", updater.currentVersion)
        case .available(let v): return L("upd.available", v)
        case .downloading: return L("upd.downloading")
        case .failed(let e): return L("upd.failed", e)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space1) {
            HStack {
                Text(L("upd.auto")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                Spacer()
                Toggle("", isOn: $auto).toggleStyle(.switch).tint(Socle.C.success).labelsHidden().controlSize(.small)
            }.padding(.vertical, 3)
            HStack {
                Text(status).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).lineLimit(2)
                Spacer()
                if case .available(let v) = updater.state {
                    Button(L("upd.install", v)) { Task { await updater.install() } }
                        .buttonStyle(SocleButtonStyle(.primary, height: 26)).fixedSize().disabled(store.exporting)
                } else {
                    Button(L("upd.check")) { Task { await updater.check() } }
                        .buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
                        .disabled(updater.state == .checking || updater.state == .downloading)
                }
            }.padding(.vertical, 3)
            if case .available = updater.state, store.exporting { Text(L("upd.busy")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle) }
        }
    }
}

// MARK: - Motif de l'icône (filigrane)

/// Bulle de dialogue traversée d'une forme d'onde : motif de l'icône de mTALKIE.
struct TalkieMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height)
            let r = CGRect(x: s * 0.1, y: s * 0.14, width: s * 0.8, height: s * 0.58)
            ctx.fill(Path(roundedRect: r, cornerRadius: s * 0.16), with: .foreground)
            var tail = Path()
            tail.move(to: CGPoint(x: s * 0.3, y: r.maxY - s * 0.05))
            tail.addLine(to: CGPoint(x: s * 0.24, y: s * 0.88))
            tail.addLine(to: CGPoint(x: s * 0.46, y: r.maxY - s * 0.05))
            tail.closeSubpath()
            ctx.fill(tail, with: .foreground)
            let bars: [CGFloat] = [0.18, 0.34, 0.5, 0.3, 0.44, 0.22, 0.12]
            let bw = s * 0.06, gap = s * 0.035
            let total = CGFloat(bars.count) * bw + CGFloat(bars.count - 1) * gap
            var x = s / 2 - total / 2
            ctx.blendMode = .destinationOut
            for b in bars {
                let h = b * s
                ctx.fill(Path(roundedRect: CGRect(x: x, y: r.midY - h / 2, width: bw, height: h), cornerRadius: bw / 2), with: .color(.black))
                x += bw + gap
            }
        }
    }
}

// MARK: - Formats d'affichage

enum Fmt {
    static func short(_ s: Double) -> String {
        let t = max(0, s)
        let m = Int(t) / 60
        let rest = t - Double(m * 60)
        return String(format: "%d:%04.1f", m, rest).replacingOccurrences(of: ".", with: Loc.lang == "en" ? "." : ",")
    }
    /// « 3 h 21 » comme la maquette ; moins d'une heure : « 12 min 05 s ».
    static func long(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d h %02d", t / 3600, (t % 3600) / 60) : String(format: "%d min %02d s", t / 60, t % 60)
    }
    static func hz(_ r: Double) -> String { "\(Int(r.rounded()).formatted(.number.locale(Loc.locale))) Hz" }
}
