#if os(macOS)
import Foundation
import Network
import Testing
@testable import LinenKit

/// The routes and the watcher for real: the Mac advertises a uniquely named `_linen._tcp` service on this Mac's network,
/// the phone finds it by Bonjour, pairs, and a file saved on the Mac reaches the phone through FSEvents. Runs only with
/// `LINEN_BONJOUR_TESTS=1`, since it advertises on the local network.
@Suite("Link over Bonjour, with the watcher", .serialized, .enabled(if: ProcessInfo.processInfo.environment["LINEN_BONJOUR_TESTS"] == "1"))
struct LinkBonjourTests {
    @Test("Found by Bonjour, paired, and a save on the Mac reaches the phone through the watcher")
    func bonjourAndWatcher() async throws {
        let folder = TempFolder("LinkBonjour")
        let mac = try LinkIdentity.generate(commonName: "bonjour-mac")
        let name = "linen-test-\(UUID().uuidString.prefix(6))"
        let server = MacLinkServer(identity: mac, config: .init(macName: "Test Mac", serviceName: name, port: .any, peerToPeer: false,
                                                                stateDirectory: folder.url.appendingPathComponent("mac")))
        try server.start()
        defer { server.stop() }
        #expect(await waitUntil(10) { server.snapshot().listening && server.snapshot().serviceName == name })
        folder.write("files/notes/a.md", "# A")
        let notes = folder.url.appendingPathComponent("files/notes")
        let pin = server.pin(path: notes.path, kind: .folder)
        let watcher = PinWatcher { ids in server.rescan(ids) }
        watcher.watch(server.pinRoots())
        defer { watcher.stop() }

        let phone = MirrorLink(mirror: try PhoneMirror(root: folder.url.appendingPathComponent("phone/Mirror")), identities: MemoryIdentityStore(),
                               recordURL: folder.url.appendingPathComponent("phone/link.json"), routes: BonjourRoutes(), peerToPeer: false)
        let invite = server.beginPairing()
        #expect(invite.service == name)
        var steps: [PairingStep] = []
        for await s in phone.pair(scannedCode: invite.text, phoneName: "Bonjour") {
            steps.append(s)
            if case .match = s {
                Task {
                    _ = await waitUntil { server.snapshot().pairing.waiting != nil }
                    server.answerPairing(allow: true)
                }
            }
        }
        guard case .paired = steps.last else { Issue.record("steps \(steps)"); return }
        phone.activate()
        defer { phone.deactivate() }
        #expect(await waitUntil(10) { phone.mirror.filesOnDisk(pin.id).keys.sorted() == ["a.md"] })

        // A save on the Mac: FSEvents, rescan, changed, hello, manifest, want, chunk, generation.
        let t0 = Date()
        folder.write("files/notes/a.md", "# A, saved again")
        let want = PinFiles.hash(root: notes, kind: .folder, diskPath: "a.md")
        #expect(await waitUntil(5) { phone.mirror.filesOnDisk(pin.id)["a.md"] == want })
        let took = Date().timeIntervalSince(t0)
        #expect(took < 2, "a save reached the phone in \(took) s")
        print("Bonjour: save to phone in \(String(format: "%.2f", took)) s")
    }
}
#endif
