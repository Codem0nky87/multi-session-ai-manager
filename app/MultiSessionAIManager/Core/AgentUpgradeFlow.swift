import Foundation
import Observation

/// What the host's durable status says about one particular batch.
///
/// The host reports the batch it is working on or, when it is idle, the last one
/// it finished. A request that has only just been queued is neither: the service
/// picks it up on its next two-second pass, and until then the status still
/// describes the previous batch. That batch being finished says nothing about
/// the one just queued.
enum AgentBatchWatch {
    enum Progress: Equatable, Sendable {
        /// Not queued yet, or queued and not picked up by the host yet.
        case waiting
        case running(AgentUpdateBatchStatus)
        case finished(AgentUpdateBatchStatus)
    }

    static func progress(of batchID: UUID?, in status: AgentUpdateBatchStatus?) -> Progress {
        guard let batchID, let status, status.id == batchID else { return .waiting }
        return status.isActive ? .running(status) : .finished(status)
    }

    /// How long an idle host may leave a queued request unclaimed before the
    /// flow stops waiting. The service looks at its queue every two seconds.
    static let pickupPatience: TimeInterval = 60
}

/// The guided upgrade: update one tool on the host, then offer to re-launch its
/// sessions onto the new version.
///
/// Each step queues one batch and follows that batch only. The flow used to act
/// on whatever status the host returned, so the first poll after "Start Upgrade"
/// — still describing an earlier, finished batch — read as "upgrade complete"
/// before the upgrade had been submitted. The re-launch offered next then found
/// the upgrade batch running, adopted it instead of queueing itself, and closed
/// with "Done" when the upgrade ended: no session was ever re-launched.
@MainActor
@Observable
final class AgentUpgradeFlow {
    enum Stage: Equatable {
        case confirming
        case upgrading
        case sessions
        case rolling
        case done
        case failed(String)
    }

    let tool: AgentToolID
    private let manager: AgentUpdateManager
    private let now: () -> Date

    private(set) var stage: Stage = .confirming
    private(set) var sessions: [HerdrAgentSnapshot] = []
    private(set) var unrestorable: [UnrestorablePane] = []
    /// Why the host's sessions could not be listed, when they could not.
    private(set) var sessionsError: String?
    var closeUnrestorable = false
    /// How the re-launch ended, for the closing summary.
    private(set) var rollResult: AgentUpdateBatchStatus?

    /// The batch the current step queued; no other batch's status moves the flow.
    private var watched: UUID?
    private var waitingSince: Date?
    /// Every batch this flow queued, so a retried step resumes its own batch
    /// instead of mistaking it for someone else's.
    private var queuedHere: Set<UUID> = []
    private var retryStage: Stage = .confirming

    init(tool: AgentToolID, manager: AgentUpdateManager, now: @escaping () -> Date = Date.init) {
        self.tool = tool
        self.manager = manager
        self.now = now
    }

    private var toolName: String { AgentToolRegistry.definition(for: tool).displayName }

    /// A step is talking to the host; the status is worth polling.
    var isBusy: Bool { stage == .upgrading || stage == .rolling }

    /// The durable status of the batch this step queued, once the host has it.
    var progress: AgentUpdateBatchStatus? {
        switch AgentBatchWatch.progress(of: watched, in: manager.batch) {
        case .waiting: nil
        case .running(let status), .finished(let status): status
        }
    }

    var statusLine: String {
        if let progress { return AgentUpdatePresentation.batchTitle(progress) }
        return watched == nil ? "Contacting the host" : "Queued on host"
    }

    func startUpgrade() async {
        begin(.upgrading, retry: .confirming)
        do {
            let preview = try await manager.prepareUpgradeOnly(tool)
            await queue(preview, whenHostIsBusy:
                "Another agent update is already running on this host. Wait for it to finish, then start this upgrade again.")
        } catch {
            fail(AgentUpdateManager.message(for: error))
        }
    }

    func startRoll() async {
        begin(.rolling, retry: .sessions)
        do {
            let preview = try await manager.prepareRelaunch(for: tool)
            await queue(preview.withCloseUnrestorablePanes(closeUnrestorable), whenHostIsBusy:
                "Another agent update is still running on this host. Wait for it to finish, then re-launch the sessions.")
        } catch {
            fail(AgentUpdateManager.message(for: error))
        }
    }

    /// Read the host's durable status once and move the flow on if the watched
    /// batch has got somewhere.
    func poll() async {
        guard isBusy else { return }
        await manager.pollBatch()
        guard isBusy else { return }
        switch AgentBatchWatch.progress(of: watched, in: manager.batch) {
        case .waiting:
            guard watched != nil else { return }
            if manager.batch?.isActive == true {
                // Queued behind another batch: the wait starts when the host is free.
                waitingSince = now()
            } else if let waitingSince, now().timeIntervalSince(waitingSince) > AgentBatchWatch.pickupPatience {
                fail("The host service has not started this request. Check Host Service for this host; the request stays queued and runs once the service is back.")
            }
        case .running(let batch):
            if stage == .upgrading, batch.phase == .approvalRequired {
                fail("Open \(toolName) once on the host to approve the new build, then retry.")
            }
        case .finished(let batch):
            watched = nil
            waitingSince = nil
            if stage == .rolling {
                rollResult = batch
                stage = .done
            } else if batch.phase == .failedUpdate {
                fail("The host could not update \(toolName). Check the updater service and retry.")
            } else {
                await loadSessions()
            }
        }
    }

    /// List the tool's sessions for the re-launch step.
    func loadSessions() async {
        do {
            let inventory = try await manager.inventory().filter { $0.tool == tool }
            sessions = inventory.filter { $0.isRestorable }
            unrestorable = inventory.filter { !$0.isRestorable }.map {
                UnrestorablePane(herdrSession: $0.herdrSession, socketPath: $0.socketPath, paneID: $0.paneID)
            }
            sessionsError = nil
        } catch {
            // The upgrade itself succeeded; say why there is nothing to offer.
            sessions = []
            unrestorable = []
            sessionsError = AgentUpdateManager.message(for: error)
        }
        stage = .sessions
    }

    /// Back to the step that failed: a failed re-launch must not restart the upgrade.
    func retry() {
        stage = retryStage
    }

    private func begin(_ stage: Stage, retry: Stage) {
        watched = nil
        waitingSince = nil
        retryStage = retry
        self.stage = stage
    }

    private func queue(_ preview: AgentUpdatePreview, whenHostIsBusy busyMessage: String) async {
        if let running = preview.existingBatch {
            // Nothing was queued because a batch is running. It can be followed
            // only when it is this flow's own, from a step the user came back to.
            guard let id = running.id, queuedHere.contains(id) else {
                fail(busyMessage)
                return
            }
            watch(id)
            return
        }
        guard let request = preview.request else {
            fail(AgentUpdateManager.message(for: AgentUpdateManagerError.invalidAcceptance))
            return
        }
        await manager.submit(preview)
        if case .failed(let message) = manager.state {
            fail(message)
            return
        }
        queuedHere.insert(request.batchID)
        watch(request.batchID)
    }

    private func watch(_ batchID: UUID) {
        guard isBusy else { return }
        watched = batchID
        waitingSince = now()
    }

    private func fail(_ message: String) {
        watched = nil
        waitingSince = nil
        stage = .failed(message)
    }
}
