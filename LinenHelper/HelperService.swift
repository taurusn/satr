import AppKit
import LinenKit
import UserNotifications

/// The helper's work (SYNC-2): the link's Mac side, the watcher on the pins, the XPC service the app talks to, the
/// note to connected phones before the Mac sleeps, and the one-hour notice when pinned changes wait for a phone.
final class HelperService: NSObject, NSXPCListenerDelegate, LinenHelperProtocol, @unchecked Sendable {
    let server: MacLinkServer
    private var watcher: PinWatcher?
    private let listener = NSXPCListener(machServiceName: LinenHelperXPC.serviceName)
    private var noticeSentFor: Date?
    private var timer: Timer?

    /// `identities`, `serviceName` and `xpc` differ only in the development mode (`DevControl`, debug builds), which
    /// runs beside the installed helper with its own key, state and Bonjour name and no XPC service.
    init(stateDirectory: URL, identities: any LinkIdentityStore = KeychainIdentityStore(service: "com.hatim.linen.link.mac"),
         serviceName: String? = nil, xpc: Bool = true) throws {
        let identity = try identities.loadOrCreate(commonName: "Linen Mac")
        let name = Host.current().localizedName ?? "Mac"
        server = MacLinkServer(identity: identity, config: .init(macName: name, serviceName: serviceName ?? name, stateDirectory: stateDirectory))
        super.init()
        let server = server
        watcher = PinWatcher { ids in server.rescan(ids) }
        server.onChange { [weak self] in
            // On the server's queue: hand the root list to the watcher from the main queue.
            DispatchQueue.main.async { self?.refreshWatch() }
        }
        try server.start()
        refreshWatch()
        DispatchQueue.global().async { server.rescan() }
        if xpc {
            listener.delegate = self
            listener.resume()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { _ in
            server.prepareForSleep()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.checkUnsent() }
    }

    private func refreshWatch() {
        watcher?.watch(server.pinRoots())
    }

    /// SYNC-5: one notice when pinned changes have waited an hour for a phone that has not connected.
    private func checkUnsent() {
        let s = server.snapshot()
        guard let since = s.unsentSince, Date().timeIntervalSince(since) > 3600, s.connected.isEmpty, !s.phones.isEmpty, noticeSentFor != since else { return }
        noticeSentFor = since
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = String(localized: "Pinned changes haven't reached your iPhone")
            c.body = String(localized: "Open Linen on your iPhone near this Mac.")
            center.add(UNNotificationRequest(identifier: "unsent", content: c, trigger: nil))
        }
    }

    // MARK: XPC

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Only Linen itself, signed by the same team, may drive the helper.
        c.setCodeSigningRequirement(LinenHelperXPC.requirement(identifier: LinenHelperXPC.appIdentifier))
        c.exportedInterface = LinenHelperXPC.interface()
        c.exportedObject = self
        c.resume()
        return true
    }

    func state(reply: @escaping @Sendable (Data) -> Void) {
        reply((try? JSONEncoder().encode(HelperState(server.snapshot()))) ?? Data())
    }

    func beginPairing(reply: @escaping @Sendable (String) -> Void) {
        reply(server.beginPairing().text)
    }

    func cancelPairing() { server.cancelPairing() }
    func answerPairing(_ allow: Bool) { server.answerPairing(allow: allow) }
    func forgetPhone(_ certHash: Data) { server.forgetPhone(certHash) }

    func pin(_ path: String, kind: String, reply: @escaping @Sendable (String) -> Void) {
        let k = Pin.Kind(rawValue: kind) ?? .folder
        let info = server.pin(path: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, kind: k)
        DispatchQueue.main.async { self.refreshWatch() }
        reply(info.id)
    }

    func unpin(_ id: String) {
        server.unpin(id)
        DispatchQueue.main.async { self.refreshWatch() }
    }

    func setTrust(_ json: Data) {
        guard let t = try? JSONDecoder().decode(PageTrust.self, from: json) else { return }
        server.setTrust(t)
    }

    func setLimit(_ bytes: Int64) { server.setTotalLimit(bytes) }
}
