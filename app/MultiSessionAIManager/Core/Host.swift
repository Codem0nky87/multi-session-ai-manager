import Foundation
import Observation

struct Host: Identifiable, Codable, Equatable, Sendable {
    enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case missingName
        case missingAddress
        case invalidPort
        case missingUsername
        case missingKey

        var errorDescription: String? {
            switch self {
            case .missingName:
                "Host name is required."
            case .missingAddress:
                "Private SSH address is required."
            case .invalidPort:
                "SSH port must be between 1 and 65535."
            case .missingUsername:
                "SSH username is required."
            case .missingKey:
                "An SSH key is required."
            }
        }
    }

    var id = UUID()
    var name: String
    var address: String
    var port: Int = 22
    var username: String
    var keyID: String          // reference into KeyStore/Keychain
    var defaultWorkdir: String

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        port: Int = 22,
        username: String,
        keyID: String,
        defaultWorkdir: String
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.username = username
        self.keyID = keyID
        self.defaultWorkdir = defaultWorkdir
    }

    /// Key used in `KnownHostsStore`. Keep port 22 on the legacy address-only key
    /// so existing trusted pins keep working; isolate non-default SSH ports so
    /// `host:22` and `host:2222` do not trip false host-key-changed warnings.
    var knownHostsKey: String {
        port == 22 ? address : "[\(address)]:\(port)"
    }

    /// Validates the complete stored host and returns the canonical form used for
    /// persistence/provisioning. SSH and Cloudflare identifiers remain exact;
    /// only the established Herdr URL and Access-email contracts normalize.
    func validated() throws -> Host {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingName
        }
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingAddress
        }
        guard (1...65_535).contains(port) else {
            throw ValidationError.invalidPort
        }
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingUsername
        }
        guard !keyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.missingKey
        }

        return self
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case address
        case port
        case username
        case keyID
        case defaultWorkdir
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        keyID = try container.decode(String.self, forKey: .keyID)
        defaultWorkdir = try container.decode(String.self, forKey: .defaultWorkdir)
        // A `herdr` blob persisted by an older build is simply ignored: the
        // Cloudflare Access / WARP metadata it held has no reader left.
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(address, forKey: .address)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encode(keyID, forKey: .keyID)
        try container.encode(defaultWorkdir, forKey: .defaultWorkdir)
    }
}

extension Host {
    /// Stand-in for a tab whose host has been deleted. The empty address, username,
    /// and key reference guarantee `HostConnection.connect()` fails locally rather
    /// than dialling anything, so a stranded tab renders a failure instead of
    /// crashing or reaching an unintended machine.
    static var placeholder: Host {
        Host(name: "unknown host", address: "", username: "", keyID: "", defaultWorkdir: "")
    }
}

@Observable final class HostStore {
    private let defaults: UserDefaults
    private let key = "msam.hosts"
    private(set) var hosts: [Host] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = decoded
        }
    }

    func add(_ h: Host) { hosts.append(h); save() }
    func remove(_ h: Host) { hosts.removeAll { $0.id == h.id }; save() }
    func update(_ h: Host) { if let i = hosts.firstIndex(where: { $0.id == h.id }) { hosts[i] = h; save() } }

    private func save() { defaults.set(try? JSONEncoder().encode(hosts), forKey: key) }
}

/// Whether a host can be offered port forwarding.
///
/// Extracted from the editor so the rule is testable: a tunnel runs over an
/// authenticated SSH connection, which needs a SAVED, valid host that has a key.
/// Offering it otherwise presents a sheet that can only fail.
enum HostPortForwardingAvailability {
    static func isOfferable(host: Host, isSaved: Bool) -> Bool {
        guard isSaved, !host.keyID.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return (try? host.validated()) != nil
    }
}
