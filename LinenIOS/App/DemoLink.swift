#if DEBUG
import Foundation
import LinenKit

/// Debug builds only: a link that reports one fixed state (`-LinenStatus receiving`), so each sync line of sketch
/// screen 17 can be seen before the real link exists. It never dials anything.
final class DemoLink: PhoneLink {
    private let state: LinkStatus
    private let mac: PairedMac?

    init(_ name: String) {
        let now = Date()
        let nine = Calendar.current.date(bySettingHour: 9, minute: 14, second: 0, of: now) ?? now
        switch name {
        case "ok": state = .upToDate(mac: "MacBook Air", at: now.addingTimeInterval(-120))
        case "away": state = .notNearby(copiesFrom: nine)
        case "sleep": state = .asleep(mac: "MacBook Air", copiesFrom: Calendar.current.date(bySettingHour: 13, minute: 2, second: 0, of: now))
        case "receiving": state = .receiving(mac: "MacBook Air", done: 3, total: 9)
        case "finishing": state = .finishing(files: 3)
        case "lan": state = .localNetworkOff
        case "forgot": state = .forgotten
        case "full": state = .outOfSpace(needed: 1_200_000_000)
        default: state = .notPaired
        }
        mac = state == .notPaired ? nil : PairedMac(name: "MacBook Air", phoneName: "Hatim's iPhone",
                                                    pairedAt: Calendar.current.date(byAdding: .day, value: -17, to: now) ?? now, lastSeen: now)
    }

    func status() async -> LinkStatus { state }
    func statusUpdates() -> AsyncStream<LinkStatus> { AsyncStream { $0.yield(state) } }
    func pairedMac() async -> PairedMac? { mac }
    func pair(scannedCode: String, phoneName: String) -> AsyncStream<PairingStep> {
        AsyncStream { c in
            c.yield(.match(digits: "418207", mac: "MacBook Air"))
            c.finish()
        }
    }
    func forgetMac() async {}
    func syncNow() async {}
}
#endif
