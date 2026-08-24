import Foundation

enum HostKeyVerdict: Equatable { case trustedNew, match, mismatch }

/// `@unchecked Sendable`: all state lives in `UserDefaults` (thread-safe), and
/// it is captured into the transport's `@Sendable` host-key validator closure.
final class KnownHostsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "msam.knownhosts"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var map: [String: String] {
        get { (defaults.dictionary(forKey: key) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }
    func verify(host: String, fingerprint: String) -> HostKeyVerdict {
        guard let known = map[host] else { return .trustedNew }
        return known == fingerprint ? .match : .mismatch
    }
    func pin(host: String, fingerprint: String) { var m = map; m[host] = fingerprint; map = m }
}
