import Foundation

enum HerdrAgentLifecycle: String, Codable, Sendable {
    case idle
    case working
    case blocked
    case done
    case error
    case unknown
}

struct HerdrSessionEndpoint: Equatable, Sendable {
    let name: String
    let socketPath: String
}

struct HerdrAgentSnapshot: Equatable, Sendable {
    let herdrSession: String
    let socketPath: String
    let paneID: String
    let tool: AgentToolID
    let lifecycle: HerdrAgentLifecycle
    let conversationID: String?
    let foregroundPID: Int32?
    let integrationCurrent: Bool

    var isRestorable: Bool {
        integrationCurrent && conversationID != nil && foregroundPID != nil
    }
}

enum HerdrAgentInventoryError: Error, Equatable, Sendable {
    case malformedJSON
    case invalidSessions
    case invalidAgent
    case duplicateSession
    case duplicateAgent
    case staleAgent(String)
    case commandFailed(Int32)
    case inventoryTooLarge
}

enum HerdrAgentInventory {
    static let commandTimeout = Duration.seconds(30)
    static let outputLimit = 64 * 1024
    static let totalOutputLimit = 2 * 1024 * 1024
    static let maximumSessions = 32
    static let maximumAgents = 256
    static let sessionsCommand = "herdr session list --json"
    static let integrationsCommand = "herdr integration status"

    static func parseSessions(_ output: String) throws -> [HerdrSessionEndpoint] {
        let root = try jsonDictionary(in: output)
        guard let values = root["sessions"] as? [[String: Any]],
              values.count <= maximumSessions else {
            throw HerdrAgentInventoryError.invalidSessions
        }

        var endpoints: [HerdrSessionEndpoint] = []
        var names = Set<String>()
        var sockets = Set<String>()
        for value in values where (value["running"] as? Bool) == true {
            guard let name = value["name"] as? String,
                  isSafeName(name),
                  let socket = value["socket_path"] as? String,
                  isSafeAbsolutePath(socket) else {
                throw HerdrAgentInventoryError.invalidSessions
            }
            guard names.insert(name).inserted, sockets.insert(socket).inserted else {
                throw HerdrAgentInventoryError.duplicateSession
            }
            endpoints.append(.init(name: name, socketPath: socket))
        }
        return endpoints
    }

    static func parseAgents(
        _ output: String,
        session: HerdrSessionEndpoint
    ) throws -> [HerdrAgentSnapshot] {
        guard isSafeName(session.name), isSafeAbsolutePath(session.socketPath) else {
            throw HerdrAgentInventoryError.invalidSessions
        }
        let root = try jsonDictionary(in: output)
        guard let result = root["result"] as? [String: Any],
              let values = result["agents"] as? [[String: Any]],
              values.count <= maximumAgents else {
            throw HerdrAgentInventoryError.invalidAgent
        }

        var snapshots: [HerdrAgentSnapshot] = []
        var panes = Set<String>()
        var conversations = Set<String>()
        for value in values {
            guard let tool = tool(for: value) else { continue }
            let snapshot = try parseAgent(value, session: session, expectedTool: tool)
            guard panes.insert(snapshot.paneID).inserted else {
                throw HerdrAgentInventoryError.duplicateAgent
            }
            if let conversation = snapshot.conversationID {
                let identity = "\(tool.rawValue):\(conversation)"
                guard conversations.insert(identity).inserted else {
                    throw HerdrAgentInventoryError.duplicateAgent
                }
            }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    static func applyLiveDetails(
        to snapshot: HerdrAgentSnapshot,
        agentOutput: String,
        processOutput: String
    ) throws -> HerdrAgentSnapshot {
        let agentRoot = try jsonDictionary(in: agentOutput)
        guard let result = agentRoot["result"] as? [String: Any],
              let value = result["agent"] as? [String: Any] else {
            throw HerdrAgentInventoryError.invalidAgent
        }
        let session = HerdrSessionEndpoint(
            name: snapshot.herdrSession,
            socketPath: snapshot.socketPath
        )
        let fresh = try parseAgent(value, session: session, expectedTool: snapshot.tool)
        guard fresh.paneID == snapshot.paneID,
              fresh.tool == snapshot.tool,
              snapshot.conversationID == nil || fresh.conversationID == nil || fresh.conversationID == snapshot.conversationID else {
            throw HerdrAgentInventoryError.staleAgent(snapshot.paneID)
        }

        let processRoot = try jsonDictionary(in: processOutput)
        guard let processResult = processRoot["result"] as? [String: Any],
              let processInfo = processResult["process_info"] as? [String: Any],
              processInfo["pane_id"] as? String == snapshot.paneID else {
            throw HerdrAgentInventoryError.staleAgent(snapshot.paneID)
        }
        let processes = processInfo["foreground_processes"] as? [[String: Any]] ?? []
        let foregroundPID = processes.lazy.compactMap { int32($0["pid"]) }.first
            ?? int32(processInfo["foreground_pid"])

        var conversationID = fresh.conversationID ?? snapshot.conversationID
        if conversationID == nil {
            for proc in processes {
                if let argv = proc["argv"] as? [String] {
                    if let idx = argv.firstIndex(of: "--conversation"), idx + 1 < argv.count {
                        let cand = argv[idx + 1]
                        if isSafeField(cand, maximumBytes: 2_048) {
                            conversationID = cand
                            break
                        }
                    } else if let idx = argv.firstIndex(of: "--resume"), idx + 1 < argv.count {
                        let cand = argv[idx + 1]
                        if isSafeField(cand, maximumBytes: 2_048) {
                            conversationID = cand
                            break
                        }
                    } else if let idx = argv.firstIndex(of: "resume"), idx + 1 < argv.count {
                        let cand = argv[idx + 1]
                        if isSafeField(cand, maximumBytes: 2_048) {
                            conversationID = cand
                            break
                        }
                    }
                }
            }
        }

        return HerdrAgentSnapshot(
            herdrSession: snapshot.herdrSession,
            socketPath: snapshot.socketPath,
            paneID: snapshot.paneID,
            tool: snapshot.tool,
            lifecycle: fresh.lifecycle,
            conversationID: conversationID,
            foregroundPID: foregroundPID,
            integrationCurrent: snapshot.integrationCurrent
        )
    }

    static func applyIntegrationStatuses(
        _ statuses: [String: HerdrIntegrationStatus],
        to snapshots: [HerdrAgentSnapshot]
    ) -> [HerdrAgentSnapshot] {
        snapshots.map { snapshot in
            let target = integrationTarget(for: snapshot.tool)
            return HerdrAgentSnapshot(
                herdrSession: snapshot.herdrSession,
                socketPath: snapshot.socketPath,
                paneID: snapshot.paneID,
                tool: snapshot.tool,
                lifecycle: snapshot.lifecycle,
                conversationID: snapshot.conversationID,
                foregroundPID: snapshot.foregroundPID,
                integrationCurrent: statuses[target]?.isCurrent == true
            )
        }
    }

    static func fetch(using service: SSHService) async throws -> [HerdrAgentSnapshot] {
        var totalOutput = 0
        let sessionsResult = try await checkedRun(sessionsCommand, using: service)
        try addOutput(sessionsResult, total: &totalOutput)
        let sessions = try parseSessions(sessionsResult.stdoutString)

        let integrationResult = try await checkedRun(integrationsCommand, using: service)
        try addOutput(integrationResult, total: &totalOutput)
        let statuses = HerdrIntegrationManager.parseStatuses(integrationResult.stdoutString)

        var inventory: [HerdrAgentSnapshot] = []
        for session in sessions {
            try Task.checkCancellation()
            let list = try await checkedRun(
                scopedCommand("herdr agent list", session: session),
                using: service
            )
            try addOutput(list, total: &totalOutput)
            let snapshots = applyIntegrationStatuses(
                statuses,
                to: try parseAgents(list.stdoutString, session: session)
            )
            guard inventory.count + snapshots.count <= maximumAgents else {
                throw HerdrAgentInventoryError.inventoryTooLarge
            }

            for snapshot in snapshots {
                let pane = POSIXShell.quote(snapshot.paneID)
                let agent = try await checkedRun(
                    scopedCommand("herdr agent get \(pane)", session: session),
                    using: service
                )
                try addOutput(agent, total: &totalOutput)
                let process = try await checkedRun(
                    scopedCommand("herdr pane process-info --pane \(pane)", session: session),
                    using: service
                )
                try addOutput(process, total: &totalOutput)
                inventory.append(try applyLiveDetails(
                    to: snapshot,
                    agentOutput: agent.stdoutString,
                    processOutput: process.stdoutString
                ))
            }
        }

        var targets = Set<String>()
        for snapshot in inventory {
            let key = "\(snapshot.socketPath):\(snapshot.paneID)"
            guard targets.insert(key).inserted else {
                throw HerdrAgentInventoryError.duplicateAgent
            }
        }
        return inventory
    }

    private static func checkedRun(
        _ command: String,
        using service: SSHService
    ) async throws -> SSHCommandResult {
        try Task.checkCancellation()
        let result = try await service.run(
            command,
            timeout: commandTimeout,
            outputLimit: outputLimit
        )
        try Task.checkCancellation()
        guard result.exitStatus == 0 else {
            throw HerdrAgentInventoryError.commandFailed(result.exitStatus)
        }
        return result
    }

    private static func addOutput(_ result: SSHCommandResult, total: inout Int) throws {
        total += result.stdout.count + result.stderr.count
        guard total <= totalOutputLimit else {
            throw HerdrAgentInventoryError.inventoryTooLarge
        }
    }

    private static func scopedCommand(
        _ command: String,
        session: HerdrSessionEndpoint
    ) -> String {
        "HERDR_SOCKET_PATH=\(POSIXShell.quote(session.socketPath)) \(command)"
    }

    private static func parseAgent(
        _ value: [String: Any],
        session: HerdrSessionEndpoint,
        expectedTool: AgentToolID
    ) throws -> HerdrAgentSnapshot {
        guard let paneID = value["pane_id"] as? String, isPaneID(paneID) else {
            throw HerdrAgentInventoryError.invalidAgent
        }
        let lifecycle = (value["agent_status"] as? String)
            .flatMap(HerdrAgentLifecycle.init(rawValue:)) ?? .unknown
        let native = value["agent_session"] as? [String: Any]
        let nativeAgent = native?["agent"] as? String
        if let nativeAgent, !AgentToolRegistry.definition(for: expectedTool).herdrKinds.contains(nativeAgent) {
            throw HerdrAgentInventoryError.invalidAgent
        }
        let conversation = native?["value"] as? String
        if let conversation, !isSafeField(conversation, maximumBytes: 2_048) {
            throw HerdrAgentInventoryError.invalidAgent
        }
        return HerdrAgentSnapshot(
            herdrSession: session.name,
            socketPath: session.socketPath,
            paneID: paneID,
            tool: expectedTool,
            lifecycle: lifecycle,
            conversationID: conversation,
            foregroundPID: nil,
            integrationCurrent: false
        )
    }

    private static func tool(for value: [String: Any]) -> AgentToolID? {
        let native = value["agent_session"] as? [String: Any]
        let kind = (native?["agent"] as? String) ?? (value["agent"] as? String)
            ?? (value["kind"] as? String)
        guard let kind else { return nil }
        return AgentToolRegistry.definitions.first { $0.herdrKinds.contains(kind) }?.id
    }

    private static func integrationTarget(for tool: AgentToolID) -> String {
        switch tool {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "antigravity-cli"
        }
    }

    private static func jsonDictionary(in output: String) throws -> [String: Any] {
        guard output.utf8.count <= outputLimit else {
            throw HerdrAgentInventoryError.inventoryTooLarge
        }
        for index in output.indices where output[index] == "{" {
            let candidate = output[index...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                continue
            }
            return dictionary
        }
        throw HerdrAgentInventoryError.malformedJSON
    }

    private static func isSafeName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        let punctuation = Set("_-".utf8)
        return bytes.allSatisfy { isASCIIAlphaNumeric($0) || punctuation.contains($0) }
    }

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && isSafeField(value, maximumBytes: 1_024)
    }

    private static func isSafeField(_ value: String, maximumBytes: Int) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= maximumBytes
            && bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
    }

    private static func isPaneID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        let body = bytes.first == Character("%").asciiValue ? bytes.dropFirst() : bytes[...]
        guard let first = body.first, isASCIIAlphaNumeric(first) else { return false }
        let punctuation = Set("._:%@+-".utf8)
        return body.allSatisfy { isASCIIAlphaNumeric($0) || punctuation.contains($0) }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func int32(_ value: Any?) -> Int32? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.int64Value
        guard raw > 0, raw <= Int64(Int32.max) else { return nil }
        return Int32(raw)
    }
}
