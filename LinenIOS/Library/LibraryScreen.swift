import LinenKit
import SwiftUI

/// The Library (IOS-1, sketch screen 11): everything kept on this iPhone, grouped by the Mac folder it came from,
/// the most recently changed first, a thread on what changed since it was read, the one sync line, search by name.
struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var settingsShown = false
    @State private var pairingShown = false

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    top
                    header
                    SearchField(text: $model.search)
                        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 8)
                    if model.loaded && model.groups.isEmpty && model.opened.isEmpty {
                        EmptyLibrary(paired: model.pairedMac != nil) { pairingShown = true }
                    } else {
                        groups
                    }
                }
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable {
                await model.link.syncNow()
                await model.refresh()
            }
            .background(palette.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: DocumentSource.self) { DocumentScreen(source: $0) }
        }
        .sheet(isPresented: $settingsShown) {
            SettingsSheet(pair: { settingsShown = false; pairingShown = true })
                .environment(\.palette, palette)
                .presentationDetents([.large, .medium])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $pairingShown) {
            PairingScreen().environment(\.palette, palette)
        }
        .alert(Text("Not opened"), isPresented: Binding(get: { model.openError != nil }, set: { if !$0 { model.openError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.openError ?? "")
        }
        .onChange(of: model.pendingPairCode) { _, code in if code != nil { settingsShown = false; pairingShown = true } }
        .onAppear {
            if model.pendingPairCode != nil { pairingShown = true }
            #if DEBUG
            if Launch.has("-LinenSettings") { settingsShown = true }
            if Launch.has("-LinenPairing") { pairingShown = true }
            if let r = Launch.value("-LinenOpen").flatMap(Launch.ref), model.path.isEmpty { model.path = [.pinned(r)] }
            if Launch.has("-LinenSweep") { Task { while !model.loaded { try? await Task.sleep(for: .milliseconds(200)) }; await model.sweep() } }
            if let f = Launch.value("-LinenOpenFile"), model.path.isEmpty {
                model.openFromElsewhere(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(f))
            }
            #endif
        }
    }

    private var top: some View {
        HStack {
            LinenMark().stroke(palette.head, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                .frame(width: 42, height: 20)
                .accessibilityHidden(true)
            Spacer()
            GlyphButton(glyph: .gear, label: "Settings") { settingsShown = true }
                .accessibilityIdentifier("settings")
        }
        .padding(.leading, 18).padding(.trailing, 6)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow("On this iPhone")
            Text("Library").font(Tok.serif(34)).foregroundStyle(palette.head)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            SyncLine(pair: { pairingShown = true })
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
    }

    @ViewBuilder private var groups: some View {
        ForEach(model.filteredGroups) { g in
            Eyebrow(path: g.pin.macPath)
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
            ForEach(g.files) { f in
                Button { model.path.append(.pinned(f.ref)) } label: {
                    LibraryRow(kind: f.kind, title: f.title, when: f.modified, changed: f.changedSinceRead)
                }
                .buttonStyle(RowPress())
                .accessibilityIdentifier("row:\(f.ref.storeKey)")
            }
        }
        if !model.filteredOpened.isEmpty {
            Eyebrow("Opened on this iPhone")
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
            ForEach(model.filteredOpened) { f in
                Button { model.path.append(.opened(f.id)) } label: {
                    LibraryRow(kind: f.kind, title: f.title, when: f.opened, changed: false)
                }
                .buttonStyle(RowPress())
                .contextMenu {
                    Button(role: .destructive) { model.removeOpened(f.id) } label: { Text("Remove from this iPhone") }
                }
            }
        }
        if model.loaded && !model.search.isEmpty && model.filteredGroups.isEmpty && model.filteredOpened.isEmpty {
            Text("Nothing by that name").font(Tok.sans(15)).foregroundStyle(palette.quiet)
                .padding(.horizontal, 18).padding(.top, 20)
        }
    }
}

/// One file: its kind glyph, title and when it changed; a thread at the leading edge when it changed since read.
struct LibraryRow: View {
    let kind: DocumentKind
    let title: String
    let when: Date
    let changed: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Glyph(Glyph.name(for: kind), size: 18)
            Text(verbatim: title).font(Tok.sans(16, medium: true)).foregroundStyle(palette.head)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: LibraryRow.when(when)).font(Tok.sans(13, relativeTo: .footnote)).foregroundStyle(palette.quiet.opacity(0.85))
        }
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 1) }
        .overlay(alignment: .leading) {
            if changed {
                RoundedRectangle(cornerRadius: 1).fill(palette.head).frame(width: 3).padding(.vertical, 12).offset(x: -10)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 18)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(changed ? Text("Changed since you read it") : Text(verbatim: LibraryRow.when(when)))
    }

    /// Today's time, Yesterday, else the day and month, in the interface's digits.
    static func when(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return String(localized: "Yesterday") }
        if cal.isDate(d, equalTo: Date(), toGranularity: .year) { return d.formatted(.dateTime.day().month(.abbreviated)) }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

struct RowPress: ButtonStyle {
    @Environment(\.palette) private var palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? palette.line.opacity(0.5) : .clear)
    }
}

/// Search by name: paper-2, a rule, 2-point corners.
struct SearchField: View {
    @Binding var text: String
    @Environment(\.palette) private var palette
    var body: some View {
        TextField(text: $text) { Text("Search by name").foregroundStyle(palette.quiet.opacity(0.75)) }
            .font(Tok.sans(16))
            .foregroundStyle(palette.text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .padding(.horizontal, 12).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: Tok.corner).fill(palette.raised))
            .overlay(RoundedRectangle(cornerRadius: Tok.corner).stroke(palette.line, lineWidth: 1))
            .accessibilityIdentifier("search")
    }
}

/// The one place sync state shows (SYNC-7), with the install's last two days (IOS-10). Rust only when something needs
/// Hatim.
struct SyncLine: View {
    let pair: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette

    var body: some View {
        let (line, sub, bad) = Self.text(model.status, expiryDays: model.expiryWarningDays)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(bad ? Tok.paper : palette.head).frame(width: 6, height: 6)
                Text(verbatim: line).font(Tok.sans(13.5, relativeTo: .subheadline))
                    .foregroundStyle(bad ? Tok.paper : palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, bad ? 10 : 0).padding(.vertical, bad ? 6 : 0)
            .background(RoundedRectangle(cornerRadius: Tok.corner).fill(bad ? Tok.rust : .clear))
            if let sub {
                Button(action: { act() }) { LinkLabel(text: Text(verbatim: sub)) }.buttonStyle(.plain)
                    .frame(minHeight: 30, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("syncline")
    }

    private func act() {
        switch model.status {
        case .notPaired, .forgotten: pair()
        case .localNetworkOff: if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
        default: break
        }
    }

    static func text(_ s: LinkStatus, expiryDays: Int?) -> (String, String?, Bool) {
        if let d = expiryDays {
            return (String(localized: "This copy of Linen stops opening in \(d) days"), String(localized: "Reinstall from your Mac"), true)
        }
        switch s {
        case .notPaired:
            return (String(localized: "Not paired with a Mac yet"), String(localized: "Pair with a Mac"), false)
        case let .upToDate(mac, at):
            return (String(localized: "Up to date with \(mac) · \(at.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"), nil, false)
        case let .notNearby(from):
            return (from.map { String(localized: "Mac not nearby · copies from \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "Mac not nearby"), nil, false)
        case let .asleep(mac, from):
            return (from.map { String(localized: "\(mac) is asleep · copies from \($0.formatted(date: .omitted, time: .shortened))") } ?? String(localized: "\(mac) is asleep"), nil, false)
        case let .receiving(mac, done, total):
            return (String(localized: "Receiving \(done) of \(total) files from \(mac)"), nil, false)
        case let .finishing(n):
            return (String(localized: "Finishing \(n) files paused when you left"), nil, false)
        case .localNetworkOff:
            return (String(localized: "Local network access is off for Linen"), String(localized: "Settings › Linen › Local Network"), true)
        case .forgotten:
            return (String(localized: "This Mac no longer knows this iPhone"), String(localized: "Pair again"), true)
        case let .outOfSpace(needed):
            return (String(localized: "Not enough space on this iPhone · \(needed.formatted(.byteCount(style: .file))) needed"), nil, true)
        }
    }
}

/// Nothing kept yet: what to do on the Mac, and pairing when there is no Mac.
struct EmptyLibrary: View {
    let paired: Bool
    let pair: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing is kept on this iPhone yet").font(Tok.serif(24, relativeTo: .title2)).foregroundStyle(palette.head)
            Text(paired ? "On your Mac, choose File › Keep on iPhone for a folder. It arrives here when the Mac is near."
                        : "Pair with your Mac, then choose File › Keep on iPhone there for a folder. Files you open from Files or AirDrop also appear here.")
                .font(Tok.sans(15.5)).foregroundStyle(palette.text).fixedSize(horizontal: false, vertical: true)
            if !paired {
                Button(action: pair) {
                    Text("Pair with a Mac").font(Tok.sans(15, medium: true)).foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 18).frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: Tok.corner).fill(palette.accent))
                }
                .buttonStyle(.plain).padding(.top, 6)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WeaveBackground().opacity(0.9))
    }
}
