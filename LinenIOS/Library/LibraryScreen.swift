import LinenKit
import SwiftUI

/// The Library (IOS-1, sketch screen 11): everything kept on this iPhone, grouped by the Mac folder it came from,
/// the most recently changed first, a thread on what changed since it was read, the one sync line, search by name.
struct LibraryScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.palette) private var palette
    @State private var settingsShown = false
    @State private var pairingShown = false

    // iOS's own controls (Hatim, 2026-11-14): the navigation bar with its large title, a toolbar button for Settings,
    // the system search field, a list with navigation rows, swipe to remove, pull to sync. The sync line stays
    // Linen's own: it is a status line, not a control, and iOS has no equivalent (SYNC-7).
    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            List {
                Section {
                    SyncLine(pair: { pairingShown = true })
                        .listRowBackground(palette.ground)
                        .listRowSeparator(.hidden)
                }
                if model.loaded && model.groups.isEmpty && model.opened.isEmpty {
                    EmptyLibrary(paired: model.pairedMac != nil) { pairingShown = true }
                        .listRowBackground(palette.ground)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets())
                } else {
                    groups
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(palette.ground.ignoresSafeArea())
            .navigationTitle(Text("Library"))
            .searchable(text: $model.search, prompt: Text("Search by name"))
            .refreshable {
                await model.link.syncNow()
                await model.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settingsShown = true } label: { Label("Settings", systemImage: "gearshape") }
                        .accessibilityIdentifier("settings")
                }
            }
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

    @ViewBuilder private var groups: some View {
        ForEach(model.filteredGroups) { g in
            Section {
                ForEach(g.files) { f in
                    NavigationLink(value: DocumentSource.pinned(f.ref)) {
                        LibraryRow(kind: f.kind, title: f.title, when: f.modified, changed: f.changedSinceRead)
                    }
                    .listRowBackground(palette.ground)
                    .listRowSeparatorTint(palette.line)
                    .accessibilityIdentifier("row:\(f.ref.storeKey)")
                }
            } header: {
                // The Mac folder it came from, named once (IOS-1); a path keeps its own case.
                Text(verbatim: g.pin.macPath).font(Tok.sans(12.5, medium: true, relativeTo: .footnote)).foregroundStyle(palette.quiet)
                    .textCase(nil).lineLimit(1).truncationMode(.middle)
            }
        }
        if !model.filteredOpened.isEmpty {
            Section {
                ForEach(model.filteredOpened) { f in
                    NavigationLink(value: DocumentSource.opened(f.id)) {
                        LibraryRow(kind: f.kind, title: f.title, when: f.opened, changed: false)
                    }
                    .listRowBackground(palette.ground)
                    .listRowSeparatorTint(palette.line)
                    .swipeActions {
                        Button(role: .destructive) { model.removeOpened(f.id) } label: { Label("Remove from this iPhone", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button(role: .destructive) { model.removeOpened(f.id) } label: { Label("Remove from this iPhone", systemImage: "trash") }
                    }
                }
            } header: {
                Text("Opened on this iPhone").font(Tok.sans(12.5, medium: true, relativeTo: .footnote)).foregroundStyle(palette.quiet)
            }
        }
        if model.loaded && !model.search.isEmpty && model.filteredGroups.isEmpty && model.filteredOpened.isEmpty {
            Text("Nothing by that name").font(Tok.sans(15)).foregroundStyle(palette.quiet)
                .listRowBackground(palette.ground).listRowSeparator(.hidden)
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
        .padding(.vertical, 5)
        .frame(minHeight: 44)
        .overlay(alignment: .leading) {
            if changed {
                RoundedRectangle(cornerRadius: 1).fill(palette.head).frame(width: 3).padding(.vertical, 8).offset(x: -11)
                    .accessibilityHidden(true)
            }
        }
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
                Button(action: { act() }) { Text(verbatim: sub).font(Tok.sans(14, medium: true, relativeTo: .subheadline)) }
                    .buttonStyle(.borderless)
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
                Button(action: pair) { Text("Pair with a Mac").font(Tok.sans(15, medium: true)) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(palette.accent).foregroundStyle(palette.onAccent)
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WeaveBackground().opacity(0.9))
    }
}
