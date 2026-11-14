#if DEBUG
import AppKit
import LinenKit

/// Debug builds only: the helper's development mode, so the iPhone app on the simulator (or a phone) can pair and sync
/// against the real helper code without touching the installed helper. It keeps its key in a file in its own folder
/// (no keychain prompt), its state in that folder, announces itself as "<Mac name> dev", serves no XPC, and takes one
/// command per line on stdin, answering on stdout:
///
///     pair            -> invite <QR text>
///     allow | refuse  -> Allow or Refuse on the waiting phone
///     state           -> state <HelperState JSON>
///     fail            -> runs the listener's failure path (mDNSResponder restarting)
///     pin <kind> <path>, unpin <id>
///     quit, or the end of stdin
enum DevControl {
    static func run(directory: URL) -> Never {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = (Host.current().localizedName ?? "Mac") + " dev"
        let service: HelperService
        do {
            service = try HelperService(stateDirectory: directory, identities: FileIdentityStore(url: directory.appendingPathComponent("identity.json")),
                                        serviceName: name, xpc: false)
        } catch {
            say("error \(error)")
            exit(1)
        }
        let server = service.server
        Thread.detachNewThread {
            while let line = readLine() {
                let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
                switch parts.first ?? "" {
                case "pair": say("invite \(server.beginPairing().text)")
                case "allow": server.answerPairing(allow: true); say("ok")
                case "refuse": server.answerPairing(allow: false); say("ok")
                case "cancel": server.cancelPairing(); say("ok")
                case "fail": server.failListenerForTesting(); say("ok")
                case "state":
                    let data = (try? JSONEncoder().encode(HelperState(server.snapshot()))) ?? Data()
                    say("state \(String(decoding: data, as: UTF8.self))")
                case "pin" where parts.count == 3:
                    say("pinned \(server.pin(path: parts[2], kind: Pin.Kind(rawValue: parts[1]) ?? .folder).id)")
                case "unpin" where parts.count == 2: server.unpin(parts[1]); say("ok")
                case "quit": exit(0)
                default: say("unknown \(line)")
                }
            }
            exit(0)
        }
        withExtendedLifetime(service) {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.run()
        }
        exit(0)
    }

    static func say(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }
}

/// The development helper's key, in a file in its own folder.
struct FileIdentityStore: LinkIdentityStore {
    let url: URL

    private struct Stored: Codable { var key: Data; var cert: Data }

    func load() throws -> LinkIdentity? {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Stored.self, from: d) else { return nil }
        return try LinkIdentity(privateKey: s.key, certificateDER: s.cert)
    }

    func save(_ identity: LinkIdentity) throws {
        let d = try JSONEncoder().encode(Stored(key: identity.privateKeyData(), cert: identity.certificateDER))
        // Created owner-only from the start, never readable by others for a moment (review P3-6).
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: d, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func delete() throws { try? FileManager.default.removeItem(at: url) }
}
#endif
