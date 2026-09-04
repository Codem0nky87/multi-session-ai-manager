import Foundation
import Observation

enum AgentUpdateBatchPhase: String, Codable, Sendable {
    case idle
    case queued
    case updating
    case rolling
    case approvalRequired = "approval_required"
    case complete
    case completedWithFailures = "completed_with_failures"
    case failedUpdate = "failed_update"
    case unknown

    var isActive: Bool {
        switch self {
        case .queued, .updating, .rolling, .approvalRequired, .unknown:
            true
        case .idle, .complete, .completedWithFailures, .failedUpdate:
            false
        }
    }
}

struct AgentUpdateTargetStatus: Equatable, Sendable {
    let index: Int
    let phase: String
    let attempts: Int
    let message: String
}

struct AgentUpdateBatchStatus: Equatable, Sendable {
    let id: UUID?
    let phase: AgentUpdateBatchPhase
    let approvalTool: AgentToolID?
    let total: Int
    let restored: Int
    let working: Int
    let attention: Int
    let retrying: Int
    let failed: Int
    let targets: [AgentUpdateTargetStatus]

    static let idle = AgentUpdateBatchStatus(
        id: nil,
        phase: .idle,
        approvalTool: nil,
        total: 0,
        restored: 0,
        working: 0,
        attention: 0,
        retrying: 0,
        failed: 0,
        targets: []
    )

    var isActive: Bool { id != nil && phase.isActive }
}

struct AgentUpdatePreview: Equatable, Sendable {
    let requestedTools: Set<AgentToolID>
    let request: AgentUpdateRequest?
    let existingBatch: AgentUpdateBatchStatus?
    let totalConversations: Int
    let workingConversations: Int
    let attentionConversations: Int
    let relaunchTool: AgentToolID?

    init(
        requestedTools: Set<AgentToolID>,
        request: AgentUpdateRequest?,
        existingBatch: AgentUpdateBatchStatus?,
        totalConversations: Int,
        workingConversations: Int,
        attentionConversations: Int,
        relaunchTool: AgentToolID? = nil
    ) {
        self.requestedTools = requestedTools
        self.request = request
        self.existingBatch = existingBatch
        self.totalConversations = totalConversations
        self.workingConversations = workingConversations
        self.attentionConversations = attentionConversations
        self.relaunchTool = relaunchTool
    }
}

enum AgentUpdateManagerError: Error, Equatable, Sendable {
    case notConnected
    case versionUnavailable(AgentToolID)
    case noUpdatesSelected
    case toolNotUpdateable(AgentToolID)
    case serviceUnavailable(String)
    case noConversationsToRelaunch(String)
    case unrestorableAgents([String])
    case invalidStatus
    case invalidAcceptance
    case remoteCommandFailed(Int32)
}

@MainActor
@Observable
final class AgentUpdateManager {
    enum State: Equatable, Sendable {
        case idle
        case refreshing
        case ready
        case preparing
        case submitting
        case failed(String)
    }

    struct Dependencies: Sendable {
        let fetchVersion: @Sendable (AgentToolID, SSHService) async throws -> AgentToolVersion
        let fetchInventory: @Sendable (SSHService) async throws -> [HerdrAgentSnapshot]
        let fetchContext: @Sendable (SSHService) async throws -> AgentUpdaterHostContext
        let fetchServiceStatus:
            @Sendable (AgentUpdaterHostContext, SSHService) async throws -> AgentUpdaterServiceStatus
        let fetchBatchStatus:
            @Sendable (AgentUpdaterHostContext, SSHService) async throws -> AgentUpdateBatchStatus

        static let live = Dependencies(
            fetchVersion: { tool, service in
                try await AgentToolVersionProbe.fetch(tool, using: service)
            },
            fetchInventory: { service in
                try await HerdrAgentInventory.fetch(using: service)
            },
            fetchContext: { service in
                try await AgentUpdateManager.liveContext(using: service)
            },
            fetchServiceStatus: { context, service in
                try await AgentUpdateManager.liveServiceStatus(context: context, using: service)
            },
            fetchBatchStatus: { context, service in
                try await AgentUpdateManager.liveBatchStatus(context: context, using: service)
            }
        )
    }

    nonisolated static let commandTimeout = Duration.seconds(45)
    nonisolated static let submitTimeout = Duration.seconds(90)
    nonisolated static let outputLimit = 64 * 1024
    nonisolated static let maximumMessageLength = 512

    let connection: HostConnection
    private let dependencies: Dependencies
    private(set) var state: State = .idle
    private(set) var tools: [AgentToolVersion] = []
    private(set) var serviceStatus: AgentUpdaterServiceStatus?
    private(set) var serviceMessage: String?
    private(set) var batch: AgentUpdateBatchStatus?
    private(set) var lastChecked: Date?
    private(set) var gatekeeperPolicy: HostGatekeeperPolicy
    private var operationGeneration: UInt64 = 0

    init(connection: HostConnection, dependencies: Dependencies = .live) {
        self.connection = connection
        self.dependencies = dependencies
        gatekeeperPolicy = connection.host.gatekeeperPolicy
    }

    func setGatekeeperPolicy(_ policy: HostGatekeeperPolicy) {
        gatekeeperPolicy = policy
    }

    func refresh() async {
        operationGeneration &+= 1
        let generation = operationGeneration
        state = .refreshing

        guard let service = connection.provisioningCommandRunner else {
            guard operationGeneration == generation else { return }
            state = .failed(Self.message(for: AgentUpdateManagerError.notConnected))
            return
        }

        var refreshedTools: [AgentToolVersion] = []
        for tool in AgentToolID.allCases {
            guard !Task.isCancelled else { return }
            do {
                let value = try await dependencies.fetchVersion(tool, service)
                guard value.tool == tool else {
                    throw AgentUpdateManagerError.versionUnavailable(tool)
                }
                refreshedTools.append(value)
            } catch {
                refreshedTools.append(AgentToolVersion(
                    tool: tool,
                    installed: nil,
                    latest: nil,
                    channel: nil,
                    method: .unknown,
                    executablePath: nil,
                    error: Self.message(for: error)
                ))
            }
        }

        var refreshedService: AgentUpdaterServiceStatus?
        var refreshedBatch: AgentUpdateBatchStatus?
        var refreshedServiceMessage: String?
        do {
            let context = try await dependencies.fetchContext(service)
            refreshedService = try await dependencies.fetchServiceStatus(context, service)
            refreshedBatch = try await dependencies.fetchBatchStatus(context, service)
        } catch {
            refreshedServiceMessage = Self.message(for: error)
        }

        guard !Task.isCancelled, operationGeneration == generation else { return }
        tools = refreshedTools
        serviceStatus = refreshedService
        serviceMessage = refreshedServiceMessage
        batch = refreshedBatch
        lastChecked = Date()
        state = .ready
    }

    func prepareUpdate(_ selectedTools: Set<AgentToolID>) async throws -> AgentUpdatePreview {
        operationGeneration &+= 1
        let generation = operationGeneration
        state = .preparing
        do {
            guard !selectedTools.isEmpty else {
                throw AgentUpdateManagerError.noUpdatesSelected
            }
            for tool in selectedTools {
                guard let version = tools.first(where: { $0.tool == tool }),
                      version.isUpdateAvailable,
                      version.method != .ambiguous,
                      version.method != .unknown else {
                    throw AgentUpdateManagerError.toolNotUpdateable(tool)
                }
            }
            let service = try requireService()
            let context = try await dependencies.fetchContext(service)
            let status = try await dependencies.fetchServiceStatus(context, service)
            guard status.isReady, status.lingerEnabled != false else {
                throw AgentUpdateManagerError.serviceUnavailable(
                    "Complete host updater setup before queueing an update."
                )
            }

            let currentBatch = try await dependencies.fetchBatchStatus(context, service)
            if currentBatch.isActive {
                guard !Task.isCancelled, operationGeneration == generation else {
                    throw CancellationError()
                }
                batch = currentBatch
                state = .ready
                return AgentUpdatePreview(
                    requestedTools: selectedTools,
                    request: nil,
                    existingBatch: currentBatch,
                    totalConversations: currentBatch.total,
                    workingConversations: currentBatch.working,
                    attentionConversations: currentBatch.attention
                )
            }

            let snapshots = try await dependencies.fetchInventory(service)
            let unsafe = snapshots.filter { !$0.isRestorable }
            guard unsafe.isEmpty else {
                let panes = unsafe.map { "\($0.herdrSession)/\($0.paneID)" }
                throw AgentUpdateManagerError.unrestorableAgents(panes)
            }

            let targets = snapshots.map { snapshot in
                AgentRollTarget(
                    herdrSession: snapshot.herdrSession,
                    socketPath: snapshot.socketPath,
                    paneID: snapshot.paneID,
                    foregroundPID: snapshot.foregroundPID,
                    tool: snapshot.tool,
                    conversationID: snapshot.conversationID!
                )
            }
            let request = AgentUpdateRequest(
                protocolVersion: 1,
                batchID: UUID(),
                requestedTools: selectedTools,
                targets: targets,
                gatekeeperPolicy: gatekeeperPolicy
            )
            try request.validate()

            guard !Task.isCancelled, operationGeneration == generation else {
                throw CancellationError()
            }
            state = .ready
            return AgentUpdatePreview(
                requestedTools: selectedTools,
                request: request,
                existingBatch: nil,
                totalConversations: snapshots.count,
                workingConversations: snapshots.count { $0.lifecycle == .working },
                attentionConversations: snapshots.count {
                    $0.lifecycle == .blocked || $0.lifecycle == .unknown || $0.lifecycle == .error
                }
            )
        } catch {
            if operationGeneration == generation, !(error is CancellationError) {
                state = .failed(Self.message(for: error))
            }
            throw error
        }
    }

    func prepareRelaunch(for tool: AgentToolID? = nil) async throws -> AgentUpdatePreview {
        operationGeneration &+= 1
        let generation = operationGeneration
        state = .preparing
        do {
            let service = try requireService()
            let context = try await dependencies.fetchContext(service)
            let status = try await dependencies.fetchServiceStatus(context, service)
            guard status.isReady, status.lingerEnabled != false else {
                throw AgentUpdateManagerError.serviceUnavailable(
                    "Complete host updater setup before queueing a re-launch."
                )
            }

            let currentBatch = try await dependencies.fetchBatchStatus(context, service)
            if currentBatch.isActive {
                guard !Task.isCancelled, operationGeneration == generation else {
                    throw CancellationError()
                }
                batch = currentBatch
                state = .ready
                return AgentUpdatePreview(
                    requestedTools: [],
                    request: nil,
                    existingBatch: currentBatch,
                    totalConversations: currentBatch.total,
                    workingConversations: currentBatch.working,
                    attentionConversations: currentBatch.attention,
                    relaunchTool: tool
                )
            }

            let snapshots = try await dependencies.fetchInventory(service)
            let filteredSnapshots: [HerdrAgentSnapshot]
            if let tool {
                filteredSnapshots = snapshots.filter { $0.tool == tool }
            } else {
                filteredSnapshots = snapshots
            }

            guard !filteredSnapshots.isEmpty else {
                if let tool {
                    throw AgentUpdateManagerError.noConversationsToRelaunch(
                        "No active \(AgentToolRegistry.definition(for: tool).displayName) conversations found on this host."
                    )
                } else {
                    throw AgentUpdateManagerError.noConversationsToRelaunch(
                        "No active AI agent conversations found on this host to re-launch."
                    )
                }
            }

            let unsafe = filteredSnapshots.filter { !$0.isRestorable }
            guard unsafe.isEmpty else {
                let panes = unsafe.map { "\($0.herdrSession)/\($0.paneID)" }
                throw AgentUpdateManagerError.unrestorableAgents(panes)
            }

            let targets = filteredSnapshots.map { snapshot in
                AgentRollTarget(
                    herdrSession: snapshot.herdrSession,
                    socketPath: snapshot.socketPath,
                    paneID: snapshot.paneID,
                    foregroundPID: snapshot.foregroundPID,
                    tool: snapshot.tool,
                    conversationID: snapshot.conversationID!
                )
            }
            let request = AgentUpdateRequest(
                protocolVersion: 1,
                batchID: UUID(),
                requestedTools: [],
                targets: targets,
                gatekeeperPolicy: gatekeeperPolicy
            )
            try request.validate()

            guard !Task.isCancelled, operationGeneration == generation else {
                throw CancellationError()
            }
            state = .ready
            return AgentUpdatePreview(
                requestedTools: [],
                request: request,
                existingBatch: nil,
                totalConversations: filteredSnapshots.count,
                workingConversations: filteredSnapshots.count { $0.lifecycle == .working },
                attentionConversations: filteredSnapshots.count {
                    $0.lifecycle == .blocked || $0.lifecycle == .unknown || $0.lifecycle == .error
                },
                relaunchTool: tool
            )
        } catch {
            if operationGeneration == generation, !(error is CancellationError) {
                state = .failed(Self.message(for: error))
            }
            throw error
        }
    }

    func submit(_ preview: AgentUpdatePreview) async {
        operationGeneration &+= 1
        let generation = operationGeneration
        if let existing = preview.existingBatch {
            batch = existing
            state = .ready
            return
        }
        guard let request = preview.request else {
            state = .failed(Self.message(for: AgentUpdateManagerError.invalidAcceptance))
            return
        }
        state = .submitting

        do {
            let service = try requireService()
            let context = try await dependencies.fetchContext(service)
            let serviceStatus = try await dependencies.fetchServiceStatus(context, service)
            guard serviceStatus.isReady, serviceStatus.lingerEnabled != false else {
                throw AgentUpdateManagerError.serviceUnavailable(
                    "The host updater is no longer ready. Test or repair it before retrying."
                )
            }
            let serialized = try request.serialized()
            let incomingPath = Self.incomingPath(context: context, batchID: request.batchID)
            try await service.writeFile(Data(serialized.utf8), to: incomingPath)
            try Task.checkCancellation()

            var submitError: Error?
            var accepted = false
            do {
                let result = try await service.run(
                    Self.submitCommand(context: context, batchID: request.batchID),
                    timeout: Self.submitTimeout,
                    outputLimit: Self.outputLimit
                )
                guard result.exitStatus == 0 else {
                    throw AgentUpdateManagerError.remoteCommandFailed(result.exitStatus)
                }
                try Self.validateAcceptance(result.stdoutString, batchID: request.batchID)
                accepted = true
            } catch {
                // Submission is atomic on the host. An SSH disconnect after the
                // rename is indeterminate, so durable status is authoritative.
                submitError = error
            }

            let durable = try await dependencies.fetchBatchStatus(context, service)
            // An unrelated active batch is never proof that this request was
            // accepted. Only the matching durable batch can resolve an
            // indeterminate SSH submission.
            guard accepted || durable.id == request.batchID else {
                throw submitError ?? AgentUpdateManagerError.invalidAcceptance
            }
            guard !Task.isCancelled, operationGeneration == generation else { return }
            batch = durable
            state = .ready
        } catch {
            guard operationGeneration == generation, !(error is CancellationError) else { return }
            state = .failed(Self.message(for: error))
        }
    }

    nonisolated static func parseStatus(_ output: String) throws -> AgentUpdateBatchStatus {
        guard output.utf8.count <= outputLimit else {
            throw AgentUpdateManagerError.invalidStatus
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.firstIndex(of: "MSAM_AGENT_UPDATE_STATUS\t1"),
              let end = lines[(header + 1)...].firstIndex(of: "END") else {
            throw AgentUpdateManagerError.invalidStatus
        }

        var id: UUID?
        var phase: AgentUpdateBatchPhase?
        var approvalTool: AgentToolID?
        var counts: [Int]?
        var targets: [AgentUpdateTargetStatus] = []
        for line in lines[(header + 1)..<end] {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch fields.first {
            case "BATCH" where fields.count == 3:
                guard phase == nil else { throw AgentUpdateManagerError.invalidStatus }
                if fields[1] != "-" {
                    guard let parsed = UUID(uuidString: fields[1]) else {
                        throw AgentUpdateManagerError.invalidStatus
                    }
                    id = parsed
                }
                phase = AgentUpdateBatchPhase(rawValue: fields[2]) ?? .unknown
            case "TARGET" where fields.count == 5:
                guard let index = Int(fields[1]), index > 0,
                      let attempts = Int(fields[3]), attempts >= 0 else {
                    throw AgentUpdateManagerError.invalidStatus
                }
                targets.append(.init(
                    index: index,
                    phase: bounded(fields[2]),
                    attempts: attempts,
                    message: bounded(fields[4])
                ))
            case "APPROVAL" where fields.count == 2:
                guard approvalTool == nil,
                      let tool = AgentToolID(rawValue: fields[1]) else {
                    throw AgentUpdateManagerError.invalidStatus
                }
                approvalTool = tool
            case "COUNTS" where fields.count == 7:
                let parsed = fields.dropFirst().compactMap(Int.init)
                guard parsed.count == 6, parsed.allSatisfy({ $0 >= 0 }) else {
                    throw AgentUpdateManagerError.invalidStatus
                }
                counts = parsed
            default:
                throw AgentUpdateManagerError.invalidStatus
            }
        }
        guard let phase, let counts, counts[0] == targets.count || targets.isEmpty else {
            throw AgentUpdateManagerError.invalidStatus
        }
        return AgentUpdateBatchStatus(
            id: id,
            phase: phase,
            approvalTool: approvalTool,
            total: counts[0],
            restored: counts[1],
            working: counts[2],
            attention: counts[3],
            retrying: counts[4],
            failed: counts[5],
            targets: targets
        )
    }

    nonisolated static func incomingPath(
        context: AgentUpdaterHostContext,
        batchID: UUID
    ) -> String {
        "\(AgentUpdaterInstaller.statePath(for: context))/incoming/\(batchID.uuidString).request"
    }

    nonisolated static func submitCommand(
        context: AgentUpdaterHostContext,
        batchID: UUID
    ) -> String {
        "\(POSIXShell.quote(AgentUpdaterInstaller.helperPath(for: context))) submit \(batchID.uuidString)"
    }

    nonisolated private static func validateAcceptance(
        _ output: String,
        batchID: UUID
    ) throws {
        let accepted = "MSAM_AGENT_UPDATE_ACCEPTED\t1\t\(batchID.uuidString)\t"
        guard output.split(whereSeparator: \.isNewline).contains(where: {
            $0 == accepted + "queued" || $0 == accepted + "existing"
        }) else {
            throw AgentUpdateManagerError.invalidAcceptance
        }
    }

    nonisolated private static func liveContext(
        using service: SSHService
    ) async throws -> AgentUpdaterHostContext {
        let result = try await service.run(
            AgentUpdaterInstaller.contextCommand,
            timeout: commandTimeout,
            outputLimit: outputLimit
        )
        guard result.exitStatus == 0 else {
            throw AgentUpdateManagerError.remoteCommandFailed(result.exitStatus)
        }
        return try AgentUpdaterInstaller.parseHostContext(result.stdoutString)
    }

    nonisolated private static func liveServiceStatus(
        context: AgentUpdaterHostContext,
        using service: SSHService
    ) async throws -> AgentUpdaterServiceStatus {
        let result = try await service.run(
            AgentUpdaterInstaller.verificationCommand(for: context),
            timeout: commandTimeout,
            outputLimit: outputLimit
        )
        guard result.exitStatus == 0 else {
            throw AgentUpdateManagerError.remoteCommandFailed(result.exitStatus)
        }
        return try AgentUpdaterInstaller.parseVerification(result.stdoutString, platform: context.platform)
    }

    nonisolated private static func liveBatchStatus(
        context: AgentUpdaterHostContext,
        using service: SSHService
    ) async throws -> AgentUpdateBatchStatus {
        let helper = POSIXShell.quote(AgentUpdaterInstaller.helperPath(for: context))
        let result = try await service.run(
            "\(helper) status",
            timeout: commandTimeout,
            outputLimit: outputLimit
        )
        guard result.exitStatus == 0 else {
            throw AgentUpdateManagerError.remoteCommandFailed(result.exitStatus)
        }
        return try parseStatus(result.stdoutString)
    }

    private func requireService() throws -> SSHService {
        guard let service = connection.provisioningCommandRunner else {
            throw AgentUpdateManagerError.notConnected
        }
        return service
    }

    nonisolated private static func bounded(_ value: String) -> String {
        guard value.count > maximumMessageLength else { return value }
        return String(value.prefix(maximumMessageLength - 1)) + "…"
    }

    nonisolated private static func message(for error: Error) -> String {
        switch error {
        case AgentUpdateManagerError.notConnected:
            "Connect and authenticate SSH to this host first."
        case AgentUpdateManagerError.versionUnavailable(let tool):
            "Could not read \(AgentToolRegistry.definition(for: tool).displayName) version information."
        case AgentUpdateManagerError.noUpdatesSelected:
            "Select at least one available update."
        case AgentUpdateManagerError.toolNotUpdateable(let tool):
            "\(AgentToolRegistry.definition(for: tool).displayName) does not have a confirmed compatible update."
        case AgentUpdateManagerError.serviceUnavailable(let detail):
            bounded(detail)
        case AgentUpdateManagerError.noConversationsToRelaunch(let detail):
            bounded(detail)
        case AgentUpdateManagerError.unrestorableAgents(let panes):
            bounded("Every AI conversation must have a current Herdr integration and native restore reference. Check: \(panes.joined(separator: ", ")).")
        case AgentUpdateManagerError.invalidStatus:
            "The host updater returned an invalid or incomplete status."
        case AgentUpdateManagerError.invalidAcceptance:
            "The host did not confirm the durable update request. Refresh before retrying."
        case AgentUpdateManagerError.remoteCommandFailed(let status):
            "The host updater command exited with status \(status)."
        case is CancellationError:
            "Cancelled."
        default:
            bounded(SSHFailure.classify(message: String(describing: error)).userMessage)
        }
    }
}
