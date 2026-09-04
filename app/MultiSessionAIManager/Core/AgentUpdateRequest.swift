import Foundation

struct AgentRollTarget: Equatable, Codable, Sendable {
    var herdrSession: String
    var socketPath: String
    var paneID: String
    var foregroundPID: Int32?
    var tool: AgentToolID
    var conversationID: String
}

struct AgentUpdateRequest: Equatable, Codable, Sendable {
    var protocolVersion: Int
    var batchID: UUID
    var requestedTools: Set<AgentToolID>
    var targets: [AgentRollTarget]
    var gatekeeperPolicy: HostGatekeeperPolicy

    func validate() throws {
        guard protocolVersion == 1 else {
            throw AgentUpdateRequestValidationError.unsupportedProtocol(protocolVersion)
        }
        guard !requestedTools.isEmpty || !targets.isEmpty else {
            throw AgentUpdateRequestValidationError.noRequestedTools
        }

        var paneKeys = Set<String>()
        for target in targets {
            guard Self.isLineField(target.herdrSession, maximumBytes: 128) else {
                throw AgentUpdateRequestValidationError.invalidSession
            }
            guard target.socketPath.hasPrefix("/"),
                  Self.isLineField(target.socketPath, maximumBytes: 1_024) else {
                throw AgentUpdateRequestValidationError.invalidSocketPath
            }
            guard Self.isPaneIdentifier(target.paneID) else {
                throw AgentUpdateRequestValidationError.invalidPaneID
            }
            guard Self.isLineField(target.conversationID, maximumBytes: 2_048) else {
                throw AgentUpdateRequestValidationError.invalidConversationID
            }
            if let pid = target.foregroundPID, pid <= 0 {
                throw AgentUpdateRequestValidationError.invalidForegroundPID
            }

            let paneKey = "\(target.socketPath):\(target.paneID)"
            guard paneKeys.insert(paneKey).inserted else {
                throw AgentUpdateRequestValidationError.duplicateTarget(paneKey)
            }
        }
    }

    func serialized() throws -> String {
        try validate()
        var lines = [
            "MSAM_AGENT_UPDATE_REQUEST\t\(protocolVersion)",
            "BATCH\t\(batchID.uuidString)",
            "POLICY\t\(gatekeeperPolicy.rawValue)"
        ]
        let requested = AgentToolID.allCases.filter(requestedTools.contains)
        lines.append(contentsOf: requested.map { "UPDATE\t\($0.rawValue)" })

        let orderedTargets = targets.sorted { lhs, rhs in
            let left = [lhs.socketPath, lhs.herdrSession, lhs.paneID, lhs.tool.rawValue, lhs.conversationID]
            let right = [rhs.socketPath, rhs.herdrSession, rhs.paneID, rhs.tool.rawValue, rhs.conversationID]
            return left.lexicographicallyPrecedes(right)
        }
        lines.append(contentsOf: orderedTargets.map { target in
            let pid = target.foregroundPID.map(String.init) ?? "-"
            return [
                "TARGET",
                target.herdrSession,
                target.socketPath,
                target.paneID,
                pid,
                target.tool.rawValue,
                target.conversationID
            ].joined(separator: "\t")
        })
        lines.append("END")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func isLineField(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty
            && bytes.count <= maximumBytes
            && bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
    }

    private static func isPaneIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        let body = bytes.first == Character("%").asciiValue ? bytes.dropFirst() : bytes[...]
        guard let first = body.first, Self.isASCIIAlphaNumeric(first) else { return false }
        let punctuation = Set("._:%@+-".utf8)
        return body.allSatisfy { Self.isASCIIAlphaNumeric($0) || punctuation.contains($0) }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

enum AgentUpdateRequestValidationError: Error, Equatable, Sendable {
    case unsupportedProtocol(Int)
    case noRequestedTools
    case duplicateTarget(String)
    case invalidSession
    case invalidSocketPath
    case invalidPaneID
    case invalidForegroundPID
    case invalidConversationID
}
