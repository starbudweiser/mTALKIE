// mTALKIE — « Envoyer à mCASTING » : menu de la barre du bas, feuille « Voix à cloner » et feuille « Répliques vers la base »
// (maquettes validées : maquettes/pipeline.html, écrans A, B et C).
import AVFoundation
import SwiftUI

@MainActor
final class CastingSender: ObservableObject {
    static let shared = CastingSender()
    enum Sheet: Identifiable { case voice, lines; var id: Int { self == .voice ? 0 : 1 } }
    @Published var sheet: Sheet?
    @Published var sending = false
    @Published var done = 0
    @Published var total = 0
    @Published var result: String?
    @Published var failure: String?
    private var task: Task<Void, Never>?
    private let cancelFlag = CancelFlag()
    private var preview: AVAudioPlayer?

    var store: Store { Store.shared }
    var selected: [Line] { store.visibleLines.filter { store.selection.contains($0.id) } }
    var game: String { store.bank.flatMap { SoundBank.game(for: $0.url)?.short } ?? store.bank?.url.lastPathComponent ?? "" }
    var lang: String { store.texts?.language ?? "" }

    func open(_ s: Sheet) { result = nil; failure = nil; done = 0; total = 0; sheet = s }

    func listen(_ lines: [Line]) {
        guard let b = store.bank else { return }
        if preview?.isPlaying == true { preview?.stop(); preview = nil; return }
        do { preview = try AVAudioPlayer(data: WavWriter.data(CastingLink.assemble(b, lines).pcm)); preview?.play() }
        catch { failure = error.localizedDescription }
    }

    func sendVoice(_ lines: [Line], name: String, lang: String, gender: String, description: String) {
        guard let b = store.bank else { return }
        sending = true; failure = nil
        Task.detached(priority: .userInitiated) {
            do {
                try CastingLink.sendVoice(b, lines: lines, name: name, lang: lang, gender: gender, description: description)
                await MainActor.run { self.sending = false; self.result = L("cast.voice.sent", name) }
            } catch { await MainActor.run { self.sending = false; self.failure = error.localizedDescription } }
        }
    }

    func sendLines(_ lines: [Line], speakers: [String: String], audio: Bool, autoTags: Bool) {
        guard let b = store.bank else { return }
        CastingLink.saveSpeakers(speakers, game: game)
        sending = true; failure = nil; done = 0; total = lines.count; cancelFlag.value = false
        let lang = self.lang, flag = cancelFlag
        BusyFlag.set(true)
        task = Task.detached(priority: .userInitiated) {
            do {
                let n = try CastingLink.sendLines(b, lines: lines, lang: lang, speakers: speakers, audio: audio, autoTags: autoTags,
                                                  cancelled: { flag.value }) { d in
                    if d % 25 == 0 { Task { @MainActor in CastingSender.shared.done = d } }
                }
                await MainActor.run { self.done = lines.count; self.sending = false; self.result = L("cast.lines.sent", n); BusyFlag.set(false) }
            } catch {
                await MainActor.run { self.sending = false; self.failure = error is CancellationError ? L("cast.cancelled") : error.localizedDescription; BusyFlag.set(false) }
            }
        }
    }
    func cancel() { cancelFlag.value = true }

    final class CancelFlag: @unchecked Sendable { var value = false }
}

/// Menu « Envoyer à mCASTING » de la barre du bas.
struct CastingMenu: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var sender = CastingSender.shared
    var body: some View {
        Menu {
            Button(L("cast.menu.voice")) { sender.open(.voice) }.disabled(store.selection.isEmpty)
            Button(L("cast.menu.lines")) { sender.open(.lines) }
        } label: { Text(L("cast.menu")) }
        .menuStyle(.button).buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
        .disabled(!CastingLink.available || store.exporting || sender.sending)
        .help(CastingLink.available ? L("cast.menu.help") : L("cast.missing"))
    }
}

// MARK: - Feuille B : voix à cloner

struct CastVoiceSheet: View {
    @ObservedObject private var sender = CastingSender.shared
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [Line] = []
    @State private var name = ""
    @State private var lang = "en"
    @State private var gender = "man"
    @State private var desc = ""
    @State private var rights = false
    static let langs = ["fr", "en", "es", "it", "de"]
    static let genders = ["man", "woman", "child", "creature"]

    var usable: [Line] { lines.filter { $0.duration == 0 || $0.duration >= 0.8 } }     // « Ahhh! » et autres cris trop courts : écartés
    var clip: Double { CastingLink.clipDuration(usable) }
    var text: String { usable.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2_5) {
            Text(L("cast.voice.title")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            if let r = sender.result { done(r) } else { form }
        }
        .padding(Socle.M.space6).frame(width: 470).background(Socle.C.surface).foregroundStyle(Socle.C.text)
        .onAppear {
            lines = sender.selected
            let sp = CastingLink.speakers(game: sender.game)
            let who = lines.first.flatMap { sp[CastingLink.prefix($0.name)] } ?? ""
            name = who.isEmpty ? "" : "\(who) (\(sender.game))"
            lang = Self.langs.contains(sender.lang) ? sender.lang : "en"
        }
    }

    var form: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2_5) {
            field(L("cast.voice.name")) { TextField(L("cast.voice.name.ph"), text: $name).textFieldStyle(.plain).socle(Socle.T.body).padding(.horizontal, 8).frame(height: 26).background(Socle.C.bgSunken) }
            field(L("cast.voice.lang")) { SocleSegmented(options: Self.langs, selection: lang, label: { $0.uppercased() }) { lang = $0 }.fixedSize() }
            field(L("cast.voice.gender")) { SocleSegmented(options: Self.genders, selection: gender, label: { L("cast.g." + $0) }) { gender = $0 }.fixedSize() }
            field(L("cast.voice.desc")) { TextField(L("cast.voice.desc.ph"), text: $desc).textFieldStyle(.plain).socle(Socle.T.body).padding(.horizontal, 8).frame(height: 26).background(Socle.C.bgSunken) }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(L("cast.voice.clip", usable.count)).foregroundStyle(Socle.C.textMuted)
                    Spacer()
                    Text(String(format: "%.1f s", clip) + (clip >= CastingLink.minClip ? " ✓" : ""))
                        .fontWeight(.semibold).foregroundStyle(clip >= CastingLink.minClip ? Socle.C.success : Socle.C.warning)
                }.socle(Socle.T.body)
                Gauge(value: clip)
                if clip < CastingLink.minClip { Text(L("cast.voice.short")).socle(Socle.T.caption).foregroundStyle(Socle.C.warning) }
                if usable.count < lines.count { Text(L("cast.voice.skipped", lines.count - usable.count)).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted) }
            }
            Text(text.isEmpty ? L("cast.voice.notext") : "« " + text + " »").socle(Socle.T.monoSm).foregroundStyle(text.isEmpty ? Socle.C.warning : Socle.C.textMuted)
                .lineLimit(4).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Socle.C.bgSunken)
            Text(L("cast.voice.reftext")).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted)
            Button(L("cast.voice.listen")) { sender.listen(usable) }.buttonStyle(SocleButtonStyle(.secondary, height: 26)).fixedSize().disabled(usable.isEmpty)
            Toggle(isOn: $rights) { Text(L("cast.rights")).socle(Socle.T.body) }.toggleStyle(.checkbox)
            if let f = sender.failure { Text(f).socle(Socle.T.body).foregroundStyle(Socle.C.warning) }
            HStack {
                Spacer()
                Button(L("btn.cancel")) { dismiss() }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                Button(L("cast.send")) { sender.sendVoice(usable, name: name.trimmingCharacters(in: .whitespaces), lang: lang, gender: gender, description: desc) }
                    .buttonStyle(SocleButtonStyle(.primary, height: 28)).fixedSize().keyboardShortcut(.defaultAction)
                    .disabled(!rights || name.trimmingCharacters(in: .whitespaces).isEmpty || text.isEmpty || usable.isEmpty || sender.sending)
            }
        }
    }

    func done(_ r: String) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space2_5) {
            Text(r).socle(Socle.T.body).foregroundStyle(Socle.C.success)
            HStack { Spacer(); Button(L("btn.close")) { dismiss() }.buttonStyle(SocleButtonStyle(.primary, height: 28)).fixedSize().keyboardShortcut(.defaultAction) }
        }
    }

    func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(label).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted); c() }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Jauge 0–30 s : zone 15–25 s en pointillés, remplissage vert dans la zone, orange sinon.
    struct Gauge: View {
        let value: Double
        var body: some View {
            GeometryReader { g in
                let w = g.size.width, k = w / 30
                ZStack(alignment: .leading) {
                    Rectangle().fill(Socle.C.bgSunken)
                    Rectangle().fill(value >= CastingLink.minClip ? Socle.C.success : Socle.C.warning).frame(width: min(w, value * k))
                    Rectangle().strokeBorder(Socle.C.textMuted, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .frame(width: 10 * k).offset(x: 15 * k)
                }
            }.frame(height: 8)
        }
    }
}

// MARK: - Feuille C : répliques vers la base

struct CastLinesSheet: View {
    @ObservedObject private var sender = CastingSender.shared
    @ObservedObject private var store = Store.shared
    @Environment(\.dismiss) private var dismiss
    @State private var all = true
    @State private var audio = true
    @State private var autoTags = true
    @State private var speakers: [String: String] = [:]

    var todo: [Line] { all ? store.lines : sender.selected }
    var prefixes: [(String, Int)] {
        var h: [String: Int] = [:]
        for l in todo { let p = CastingLink.prefix(l.name); if !p.isEmpty { h[p, default: 0] += 1 } }
        return h.sorted { $0.value > $1.value }
    }
    var withText: Int { todo.filter { !$0.text.isEmpty }.count }
    var named: Int { todo.filter { !(speakers[CastingLink.prefix($0.name)] ?? "").isEmpty }.count }
    var sizeMB: Int { Int((todo.reduce(0) { $0 + $1.duration } * CastingLink.aacBytesPerSecond / 1_000_000).rounded(.up)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2_5) {
            Text(L("cast.lines.title")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            if sender.sending { progress } else if let r = sender.result { done(r) } else { form }
        }
        .padding(Socle.M.space6).frame(width: 500).background(Socle.C.surface).foregroundStyle(Socle.C.text)
        .onAppear { speakers = CastingLink.speakers(game: sender.game); all = store.selection.isEmpty }
    }

    var form: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            HStack {
                Text(L("cast.lines.scope")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
                SocleSegmented(options: [false, true], selection: all, label: { $0 ? L("cast.lines.all", store.lines.count) : L("cast.lines.sel", store.selection.count) }) { all = $0 }
            }
            kv(L("cast.lines.game"), CastingLink.sourceTitle(store.bank!))
            kv(L("cast.lines.lang"), sender.lang.isEmpty ? "—" : sender.lang.uppercased())
            kv(L("cast.lines.text"), "\(withText) (\(todo.isEmpty ? 0 : withText * 100 / todo.count) %)", ok: withText * 10 >= todo.count * 9)
            if !prefixes.isEmpty {
                kv(L("cast.lines.named"), "\(named) (\(todo.isEmpty ? 0 : named * 100 / todo.count) %)", ok: named * 2 >= todo.count)
                VStack(spacing: 0) {
                    HStack { Text(L("cast.lines.prefix")); Spacer(); Text(L("cast.lines.speaker")).frame(width: 170, alignment: .leading); Text(L("cast.lines.count")).frame(width: 50, alignment: .trailing) }
                        .socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted).padding(.horizontal, 8).padding(.vertical, 4)
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(prefixes, id: \.0) { p, n in
                                HStack {
                                    Text(p + "_").socle(Socle.T.monoSm).foregroundStyle(Socle.C.textMuted)
                                    Spacer()
                                    TextField(L("lines.unknown.ph"), text: Binding(get: { speakers[p] ?? "" }, set: { speakers[p] = $0 }))
                                        .textFieldStyle(.plain).socle(Socle.T.body).foregroundStyle(Socle.C.accentText).frame(width: 170)
                                    Text("\(n)").socle(Socle.T.body).monospacedDigit().frame(width: 50, alignment: .trailing)
                                }.padding(.horizontal, 8).frame(height: 24)
                                .overlay(alignment: .bottom) { Rectangle().fill(Socle.C.border).frame(height: 1) }
                            }
                        }
                    }.frame(maxHeight: 170)
                }.background(Socle.C.bgSunken)
            } else {
                Text(L("cast.lines.nonames")).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted)
            }
            Toggle(isOn: $audio) { Text(L("cast.lines.audio", sizeMB)).socle(Socle.T.body) }.toggleStyle(.checkbox)
            Toggle(isOn: $autoTags) { Text(L("cast.lines.tags")).socle(Socle.T.body) }.toggleStyle(.checkbox)
            Text(L("cast.lines.rights")).socle(Socle.T.caption).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true)
            if let f = sender.failure { Text(f).socle(Socle.T.body).foregroundStyle(Socle.C.warning) }
            HStack {
                Spacer()
                Button(L("btn.cancel")) { dismiss() }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
                Button(L("cast.lines.send", todo.count)) { sender.sendLines(todo, speakers: speakers, audio: audio, autoTags: autoTags) }
                    .buttonStyle(SocleButtonStyle(.primary, height: 28)).fixedSize().keyboardShortcut(.defaultAction).disabled(todo.isEmpty)
            }
        }
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2_5) {
            ProgressView(value: Double(sender.done), total: Double(max(1, sender.total))).progressViewStyle(.linear).tint(Socle.C.accentText)
            HStack {
                Text("\(sender.done) / \(sender.total)").monospacedDigit().foregroundStyle(Socle.C.textMuted)
                Spacer()
                Button(L("btn.cancel")) { sender.cancel() }.buttonStyle(SocleButtonStyle(.secondary, height: 28)).fixedSize()
            }.socle(Socle.T.body)
        }
    }

    func done(_ r: String) -> some View {
        VStack(alignment: .leading, spacing: Socle.M.space2_5) {
            Text(r).socle(Socle.T.body).foregroundStyle(Socle.C.success)
            HStack { Spacer(); Button(L("btn.close")) { dismiss() }.buttonStyle(SocleButtonStyle(.primary, height: 28)).fixedSize().keyboardShortcut(.defaultAction) }
        }
    }

    func kv(_ k: String, _ v: String, ok: Bool? = nil) -> some View {
        HStack { Text(k).foregroundStyle(Socle.C.textMuted); Spacer(); Text(v).fontWeight(.semibold).foregroundStyle(ok == nil ? Socle.C.text : (ok! ? Socle.C.success : Socle.C.warning)) }.socle(Socle.T.body)
    }
}
