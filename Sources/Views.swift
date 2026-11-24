// mTALKIE — interface (Socle standard : sombre, plat, dense).
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var store = Store.shared
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            HStack(spacing: 0) {
                Sidebar(dropHover: dropHover).frame(width: 270)
                Rectangle().fill(Socle.C.border).frame(width: 1)
                MainArea(dropHover: dropHover)
            }
            if store.bank != nil { FooterBar() }
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

// MARK: - En-tête

struct HeaderBar: View {
    @ObservedObject private var store = Store.shared
    var body: some View {
        HStack(spacing: Socle.M.space3) {
            Text(branded: "mTALKIE").socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            Spacer()
            if let b = store.bank {
                Text(b.gameName ?? b.url.deletingLastPathComponent().lastPathComponent)
                    .socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).lineLimit(1)
            }
            Button(L("btn.open")) { store.chooseFile() }.buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
            Button { Main.delegate.showSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(SocleButtonStyle(.secondary, height: 26)).frame(width: 36)
        }
        .padding(.leading, 84).padding(.trailing, Socle.M.space3)
        .frame(height: Socle.M.sizeBar)
        .background(Socle.C.surfaceRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(Socle.C.border).frame(height: 1) }
    }
}

// MARK: - Colonne de gauche

struct Sidebar: View {
    @ObservedObject private var store = Store.shared
    let dropHover: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Socle.M.space4) {
                if let b = store.bank {
                    FileCard(bank: b)
                    ExportCard()
                }
                VStack(alignment: .leading, spacing: Socle.M.space1) {
                    SectionTitle(L("side.recent"))
                    if store.recents.isEmpty { Text(L("side.none")).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted) }
                    ForEach(store.recents, id: \.self) { u in RecentRow(url: u, current: store.bank?.url == u) }
                }
            }
            .padding(Socle.M.space3)
        }
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
        HStack { Text(k).foregroundStyle(Socle.C.textMuted); Spacer(minLength: 8); Text(v).foregroundStyle(color).lineLimit(1).monospacedDigit() }
            .socle(Socle.T.body)
    }
}

struct Box<C: View>: View {
    @ViewBuilder let content: C
    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space1_5) { content }
            .padding(Socle.M.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radius))
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radius).stroke(Socle.C.border))
    }
}

struct FileCard: View {
    let bank: SoundBank
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space1_5) {
            SectionTitle(L("side.file"))
            Box {
                Text(bank.url.lastPathComponent).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).lineLimit(1).truncationMode(.middle)
                    .help(bank.url.path)
                KV(k: L("info.format"), v: bank.codec == .voc ? L("info.voc") : bank.codec.rawValue.uppercased())
                KV(k: L("info.lines"), v: store.lines.count.formatted(.number.locale(Loc.locale)))
                KV(k: L("info.duration"), v: pending ? L("info.pending") : Fmt.long(store.lines.reduce(0) { $0 + $1.duration }))
                KV(k: L("info.rate"), v: rate)
                KV(k: L("info.size"), v: ByteCountFormatter.string(fromByteCount: Int64(bank.data.count), countStyle: .file))
                let bad = store.lines.filter { !$0.supported }.count
                KV(k: L("info.decode"), v: bad == 0 ? L("info.complete") : L("info.partial", bad), color: bad == 0 ? Socle.C.success : Socle.C.warning)
            }
        }
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
            Box {
                SocleSegmented(options: ExportFormat.allCases, selection: store.format, label: { $0.label }) { store.format = $0 }
                HStack(spacing: Socle.M.space2) {
                    Text(store.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .socle(Socle.T.monoSm).foregroundStyle(Socle.C.accentText).lineLimit(1).truncationMode(.head)
                        .help(store.destination.path)
                    Spacer(minLength: 4)
                    Button(L("btn.folder")) { store.chooseFolder() }.buttonStyle(SocleButtonStyle(.secondary, height: 24)).fixedSize()
                }
            }
        }
    }
}

struct RecentRow: View {
    let url: URL; let current: Bool
    @State private var hover = false
    var body: some View {
        Button { Store.shared.open(url) } label: {
            HStack {
                Text(url.lastPathComponent).foregroundStyle(Socle.C.text).lineLimit(1)
                Spacer(minLength: 6)
                Text(url.deletingLastPathComponent().lastPathComponent).foregroundStyle(Socle.C.textMuted).lineLimit(1).truncationMode(.middle)
            }
            .socle(Socle.T.body)
            .padding(.horizontal, Socle.M.space2).padding(.vertical, 5)
            .background(current || hover ? Socle.C.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: Socle.M.radius))
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
        VStack(spacing: Socle.M.space3) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 34, weight: .medium)).foregroundStyle(Socle.C.accentText)
            Text(L("drop.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            Text(L("drop.formats")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            Text(L("drop.folder")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            Button(L("btn.choose")) { Store.shared.chooseFile() }.buttonStyle(SocleButtonStyle(.primary)).fixedSize().padding(.top, Socle.M.space2)
            Text(L("drop.games")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).multilineTextAlignment(.center).padding(.top, Socle.M.space4)
            Text(L("safe")).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
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
            let all = !store.selection.isEmpty && store.selection.count == store.visibleLines.count
            Button(all ? L("btn.selectNone") : L("btn.selectAll")) {
                store.selection = all ? [] : Set(store.visibleLines.map(\.id))
            }.buttonStyle(SocleButtonStyle(.secondary, height: 30)).fixedSize()
        }
    }
}

struct LinesTable: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var player = Store.shared.player

    var body: some View {
        Table(of: Line.self, selection: $store.selection) {
            TableColumn("") { line in
                Button { store.play(line.id) } label: {
                    Image(systemName: player.playing == line.id && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 9)).frame(width: 22, height: 22)
                        .foregroundStyle(player.playing == line.id ? Socle.C.onAccentFill : Socle.C.text)
                        .background(player.playing == line.id ? Socle.C.accentFill : Socle.C.control, in: Circle())
                }.buttonStyle(.plain)
            }.width(28)
            TableColumn(L("col.n")) { line in Text(String(format: "%04d", line.id)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted) }.width(48)
            TableColumn(L("col.wave")) { line in
                WaveView(peaks: store.peaks[line.id] ?? [], highlight: player.playing == line.id)
                    .frame(height: 18)
                    .onAppear { store.requestPeaks(line.id) }
            }
            TableColumn(L("col.duration")) { line in
                Text(line.rate > 0 ? Fmt.short(line.duration) : "…").monospacedDigit()
                    .foregroundStyle(line.supported ? Socle.C.text : Socle.C.warning)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(64)
            TableColumn(L("col.rate")) { line in
                Text(line.rate > 0 ? Fmt.hz(line.rate) : "…").socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(84)
            TableColumn(L("col.offset")) { line in
                Text(String(format: "0x%06X", line.offset)).socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
            }.width(86)
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
    var progress: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let w = size.width / CGFloat(peaks.count)
            for (i, p) in peaks.enumerated() {
                let h = max(1.5, CGFloat(p.squareRoot()) * size.height)
                let rect = CGRect(x: CGFloat(i) * w, y: (size.height - h) / 2, width: max(1, w * 0.6), height: h)
                let done = progress.map { Double(i) / Double(peaks.count) < $0 } ?? highlight
                ctx.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(done ? Socle.C.accentText : Socle.C.textMuted.opacity(0.55)))
            }
        }
    }
}

// MARK: - Barre du bas : lecteur et export

struct FooterBar: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var player = Store.shared.player

    var body: some View {
        HStack(spacing: Socle.M.space3) {
            Button { if player.playing != nil { player.toggle() } else { store.playSelection() } } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12))
                    .frame(width: 32, height: 32).foregroundStyle(Socle.C.onAccentFill).background(Socle.C.accentFill, in: Circle())
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                if let id = player.playing {
                    HStack {
                        Text(L("player.line", String(format: "%04d", id))).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong)
                        Spacer()
                        Text("\(Fmt.short(player.position)) / \(Fmt.short(player.duration))").socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                    }
                    GeometryReader { g in
                        WaveView(peaks: player.peaks, progress: player.duration > 0 ? player.position / player.duration : 0)
                            .contentShape(Rectangle())
                            .onTapGesture { loc in player.seek(loc.x / g.size.width) }
                    }.frame(height: 22)
                } else {
                    Text(L("player.none")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(store.selection.isEmpty ? L("count.lines", store.lines.count) : L("count.selected", store.selection.count))
                .socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize()
            Button(L("btn.exportSel")) { store.export(selectionOnly: true) }
                .buttonStyle(SocleButtonStyle(.secondary, height: 30)).fixedSize()
                .disabled(store.selection.isEmpty || store.exporting)
            Button(L("btn.exportAll")) { store.export(selectionOnly: false) }
                .buttonStyle(SocleButtonStyle(.action, height: 30)).fixedSize()
                .disabled(store.exporting)
        }
        .padding(.horizontal, Socle.M.space3).frame(height: 56)
        .background(Socle.C.surfaceRaised)
        .overlay(alignment: .top) { Rectangle().fill(Socle.C.border).frame(height: 1) }
    }
}

// MARK: - Feuille d'export

struct ExportSheet: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space3) {
            if let r = store.exportReport {
                Text(r.cancelled ? L("export.cancelled") : L("export.done")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                HStack(spacing: Socle.M.space3) {
                    Text(L("export.ok", r.ok)).foregroundStyle(Socle.C.success)
                    if !r.skipped.isEmpty { Text(L("export.skipped", r.skipped.count)).foregroundStyle(Socle.C.warning) }
                }.socle(Socle.T.label)
                if !r.skipped.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(r.skipped, id: \.0.id) { item in
                                Text("\(String(format: "%04d · 0x%06X", item.0.id, item.0.offset)) — \(item.1)").socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }
                Text(r.folder.path).socle(Socle.T.monoSm).foregroundStyle(Socle.C.accentText).lineLimit(2).truncationMode(.middle)
                HStack(spacing: Socle.M.space2) {
                    Spacer()
                    Button(L("btn.finder")) { NSWorkspace.shared.activateFileViewerSelecting([r.folder]) }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize()
                    Button(L("btn.close")) { store.dismissReport() }.buttonStyle(SocleButtonStyle(.primary)).fixedSize()
                }
            } else {
                Text(L("export.title")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
                Text(L("export.sub", store.exportTotal, store.format.label)).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                Text(store.destination.path).socle(Socle.T.monoSm).foregroundStyle(Socle.C.accentText).lineLimit(1).truncationMode(.middle)
                ProgressView(value: Double(store.exportDone), total: Double(max(1, store.exportTotal))).tint(Socle.C.accentText)
                HStack {
                    Text("\(store.exportDone) / \(store.exportTotal)").monospacedDigit()
                    Spacer()
                    Text(store.remaining).foregroundStyle(Socle.C.textStrong)
                }.socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                HStack { Spacer(); Button(L("btn.cancel")) { store.cancelExport() }.buttonStyle(SocleButtonStyle(.secondary)).fixedSize(); Spacer() }
            }
        }
        .padding(Socle.M.space6)
        .frame(width: 440)
        .background(Socle.C.surface)
    }
}

// MARK: - Réglages

struct SettingsView: View {
    @ObservedObject private var store = Store.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space4) {
            Box {
                SectionTitle(L("set.export"))
                row(L("set.format")) {
                    SocleSegmented(options: ExportFormat.allCases, selection: store.format, label: { $0.label }) { store.format = $0 }
                }
                Hint(L("set.format.help"))
                row(L("set.pattern")) {
                    TextField("", text: $store.pattern).textFieldStyle(.plain).socle(Socle.T.mono).foregroundStyle(Socle.C.accentText)
                        .padding(.horizontal, Socle.M.space3).frame(width: 240, height: 30).background(Socle.C.bgSunken)
                }
                Hint(L("set.pattern.help"))
                Hint(L("set.example", Encoder.name(pattern: store.pattern, source: URL(fileURLWithPath: "MONSTER.SOU"),
                                                    line: Line(id: 42, offset: 0x1D6C0, start: 0, length: 0, rate: 0, duration: 0), format: store.format)))
                row(L("set.folder")) {
                    HStack {
                        Text(store.destination.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).socle(Socle.T.monoSm)
                            .foregroundStyle(Socle.C.accentText).lineLimit(1).truncationMode(.head)
                        Button(L("btn.folder")) { store.chooseFolder() }.buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize()
                    }
                }
                Toggle(L("set.subfolder"), isOn: $store.subfolder).toggleStyle(.checkbox).socle(Socle.T.body)
            }
            Box {
                SectionTitle(L("upd.title"))
                UpdateSection()
            }
        }
        .padding(Socle.M.space6)
        .frame(width: 600)
        .background(Socle.C.bg)
        .foregroundStyle(Socle.C.text)
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(label).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted); Spacer(); c() }.padding(.vertical, 2)
    }
}

struct Hint: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View { Text(text).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle).fixedSize(horizontal: false, vertical: true) }
}

struct UpdateSection: View {
    @ObservedObject var updater = Updater.shared
    @ObservedObject private var store = Store.shared
    @AppStorage("autoUpdate") private var auto = true

    private var status: String {
        switch updater.state {
        case .idle: return L("upd.version", updater.currentVersion)
        case .checking: return L("upd.checking")
        case .upToDate: return L("upd.uptodate", updater.currentVersion)
        case .available(let v): return L("upd.available", v)
        case .downloading: return L("upd.downloading")
        case .failed(let e): return L("upd.failed", e)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Toggle(L("upd.auto"), isOn: $auto).toggleStyle(.checkbox).socle(Socle.T.body)
            HStack(spacing: Socle.M.space2) {
                Button(L("upd.check")) { Task { await updater.check() } }
                    .buttonStyle(SocleButtonStyle(.secondary, height: 30)).fixedSize()
                    .disabled(updater.state == .checking || updater.state == .downloading)
                if case .available(let v) = updater.state {
                    Button(L("upd.install", v)) { Task { await updater.install() } }
                        .buttonStyle(SocleButtonStyle(.primary, height: 30)).fixedSize().disabled(store.exporting)
                }
            }
            Hint(status)
            if case .available = updater.state, store.exporting { Hint(L("upd.busy")) }
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
            var bubble = Path(roundedRect: r, cornerRadius: s * 0.16)
            bubble.move(to: CGPoint(x: s * 0.3, y: r.maxY - 1))
            bubble.addLine(to: CGPoint(x: s * 0.24, y: s * 0.88))
            bubble.addLine(to: CGPoint(x: s * 0.46, y: r.maxY - 1))
            bubble.closeSubpath()
            ctx.fill(bubble, with: .foreground)
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
    static func long(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d h %02d min", t / 3600, (t % 3600) / 60) : String(format: "%d min %02d s", t / 60, t % 60)
    }
    static func hz(_ r: Double) -> String { "\(Int(r.rounded()).formatted(.number.locale(Loc.locale))) Hz" }
}
