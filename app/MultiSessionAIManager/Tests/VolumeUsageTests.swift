import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct VolumeUsageTests {
    private let present = #"MSAM_DISK_USAGE={"path":"/home/alice/.local/libexec/msam-disk-usage/abc/disk-usage.py","present":true}"#
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(_ files: [(String, Int64)] = [("/data/vm/disk.qcow2", 120_000_000_000),
                                                      ("/data/backup.tar", 9_000_000_000)],
                        mountPoint: String = "/data", scanned: Int = 3_181_215,
                        unreadable: Int = 0, cloudOnly: Int = 0, complete: Bool = true) -> String {
        let object: [String: Any] = [
            "mountPoint": mountPoint,
            "files": files.map { ["path": $0.0, "bytes": $0.1] as [String: Any] },
            "scannedFiles": scanned, "unreadable": unreadable, "cloudOnly": cloudOnly,
            "complete": complete, "seconds": 7.2,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return "MSAM_DISK_USAGE=" + String(decoding: data, as: UTF8.self)
    }

    private func decoded(_ line: String) throws -> VolumeUsageReport {
        try VolumeUsageScan.helper.decode(VolumeUsageReport.self, from: line, missing: "no report")
    }

    private func makeConnection(connected: Bool = true) async -> (HostConnection, FakeSSHTransport) {
        let transport = FakeSSHTransport()
        let keys = KeyStore(backing: InMemoryKeychain())
        let keyID = try! keys.generateEd25519(label: "usage")
        let connection = HostConnection(
            host: Host(name: "h", address: "10.0.0.1", username: "alice", keyID: keyID, defaultWorkdir: "/home/alice"),
            keyStore: keys,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.usage.\(UUID())")!), transport: transport
        )
        if connected { await connection.connect() }
        return (connection, transport)
    }

    private func makeModel(connected: Bool = true) async -> (VolumeUsageModel, FakeSSHTransport) {
        let (connection, transport) = await makeConnection(connected: connected)
        return (VolumeUsageModel(connection: connection, now: { [clock] in clock }), transport)
    }

    private func stub(_ transport: FakeSSHTransport, _ outputs: [String]) {
        transport.structuredCommandResults = outputs.map {
            .success(SSHCommandResult(exitStatus: 0, stdout: Data($0.utf8), stderr: Data()))
        }
    }

    // MARK: - Talking to the host

    @Test func theReportLineIsReadOutOfWhateverElseTheHostPrints() throws {
        let value = try decoded("Welcome to forge\n" + report(unreadable: 72) + "\n")
        #expect(value.mountPoint == "/data")
        #expect(value.files.map(\.path) == ["/data/vm/disk.qcow2", "/data/backup.tar"])
        #expect(value.files[0].bytes == 120_000_000_000)
        #expect(value.scannedFiles == 3_181_215)
        #expect(value.unreadable == 72)
        #expect(value.complete)
    }

    @Test func theHostsOwnErrorIsWhatTheUserGetsToRead() {
        #expect(throws: HostHelperScript.Failure.failed("The volume /nope is missing or is not a folder.")) {
            _ = try decoded(#"MSAM_DISK_USAGE={"error":"The volume /nope is missing or is not a folder."}"#)
        }
    }

    @Test func scanningAVolumeRunsTheHelperOnThatMountPoint() async throws {
        let (connection, transport) = await makeConnection()
        stub(transport, [present, report()])
        let service = try #require(connection.provisioningCommandRunner)
        let result = try await VolumeUsageScan.largestFiles(on: "/data", using: service)
        #expect(result.files.count == 2)
        let command = try #require(transport.commandsRun.last)
        #expect(command.contains("'largest-files'"))
        #expect(command.contains("'/data'"))
        #expect(transport.writtenFiles.isEmpty, "A host that already has this helper is not sent it again")
        // The host stops itself first; the app's own timeout must outlast that.
        let allowed = try #require(transport.structuredCommandsRun.last?.timeout)
        #expect(allowed > VolumeUsageScan.timeLimit)
        await connection.disconnect()
    }

    @Test func aHostWithoutTheHelperIsSentItFirst() async throws {
        let (connection, transport) = await makeConnection()
        stub(transport, [#"MSAM_DISK_USAGE={"path":"/home/alice/x/disk-usage.py","present":false}"#, report()])
        let service = try #require(connection.provisioningCommandRunner)
        _ = try await VolumeUsageScan.largestFiles(on: "/data", using: service)
        let bundled = try HostServiceInstaller.resource("msam-disk-usage.py")
        #expect(transport.writtenFiles["/home/alice/x/disk-usage.py"] == bundled)
        await connection.disconnect()
    }

    @Test func theSoftwareHelperStillLivesWhereHostsAlreadyHaveIt() async throws {
        let (connection, transport) = await makeConnection()
        stub(transport, [#"MSAM_SOFTWARE={"path":"/home/alice/software.py","present":true}"#, #"MSAM_SOFTWARE={"plugins":[]}"#])
        let service = try #require(connection.provisioningCommandRunner)
        _ = try await HostSoftwareProvisioning.pluginStatus(using: service)
        // Connecting runs commands of its own, so look for the one that locates the helper.
        #expect(transport.commandsRun.contains {
            $0.contains("'msam-host-software'") && $0.contains("'software.py'") && $0.contains("'MSAM_SOFTWARE='")
        })
        await connection.disconnect()
    }

    // MARK: - What a volume row shows

    @Test func expandingAVolumeScansItAndKeepsTheResult() async {
        let (model, transport) = await makeModel()
        stub(transport, [present, report()])
        #expect(model.state(for: "/data") == nil)
        await model.load("/data")
        #expect(model.state(for: "/data") == .loaded(try! decoded(report()), at: clock))
        let commands = transport.commandsRun.count
        await model.load("/data")
        #expect(transport.commandsRun.count == commands, "Reopening a volume shows the last result")
        await model.connection.disconnect()
    }

    @Test func rescanAsksTheHostAgain() async {
        let (model, transport) = await makeModel()
        stub(transport, [present, report(), present, report([("/data/new.iso", 5_000_000_000)])])
        await model.load("/data")
        await model.rescan("/data")
        guard case .loaded(let value, _) = model.state(for: "/data") else {
            Issue.record("expected a result, got \(String(describing: model.state(for: "/data")))")
            return
        }
        #expect(value.files.map(\.path) == ["/data/new.iso"])
        await model.connection.disconnect()
    }

    @Test func aVolumeBeingScannedIsNotScannedTwice() async {
        let (model, transport) = await makeModel()
        stub(transport, [present, report()])
        let gate = ScanGate()
        transport.beforeCommand = { command in
            if command.contains("'largest-files'") { await gate.pause() }
        }
        let first = Task { await model.load("/data") }
        await gate.waitUntilEntered()
        #expect(model.state(for: "/data") == .scanning(since: clock))
        await model.load("/data")
        await model.rescan("/data")
        #expect(transport.commandsRun.filter { $0.contains("'largest-files'") }.count == 1)
        await gate.resume()
        await first.value
        #expect(model.state(for: "/data") == .loaded(try! decoded(report()), at: clock))
        await model.connection.disconnect()
    }

    @Test func aFailedScanSaysWhyAndCanBeTriedAgain() async {
        let (model, transport) = await makeModel()
        stub(transport, [present, #"MSAM_DISK_USAGE={"error":"The volume /data is missing or is not a folder."}"#,
                         present, report()])
        await model.load("/data")
        #expect(model.state(for: "/data") == .failed("The volume /data is missing or is not a folder."))
        await model.load("/data")
        #expect(model.state(for: "/data") == .loaded(try! decoded(report()), at: clock))
        await model.connection.disconnect()
    }

    @Test func withoutAConnectionTheVolumeSaysSo() async {
        let (model, transport) = await makeModel(connected: false)
        await model.load("/data")
        #expect(model.state(for: "/data") == .failed("Not connected to this host."))
        #expect(transport.commandsRun.isEmpty)
    }

    @Test func eachVolumeKeepsItsOwnResult() async {
        let (model, transport) = await makeModel()
        stub(transport, [present, report(), present, report([("/swapfile", 8_000_000_000)], mountPoint: "/")])
        await model.load("/data")
        await model.load("/")
        #expect(model.state(for: "/data") == .loaded(try! decoded(report()), at: clock))
        #expect(model.state(for: "/") == .loaded(try! decoded(report([("/swapfile", 8_000_000_000)], mountPoint: "/")), at: clock))
        await model.connection.disconnect()
    }

    // MARK: - Wording

    @Test func sizesReadInTheSameBinaryUnitsAsTheVolumeItself() {
        #expect(VolumeUsageFormat.size(120_000_000_000) == "111.8 GiB")
        #expect(VolumeUsageFormat.size(5 * 1024 * 1024) == "5 MiB")
        #expect(VolumeUsageFormat.size(2048) == "2 KiB")
        #expect(VolumeUsageFormat.size(900) == "900 B")
        #expect(VolumeUsageFormat.size(0) == "0 B")
    }

    @Test func largeCountsAreShortened() {
        #expect(VolumeUsageFormat.count(3_181_215) == "3.2M")
        #expect(VolumeUsageFormat.count(447_328) == "447K")
        #expect(VolumeUsageFormat.count(12_000_000) == "12M")
        #expect(VolumeUsageFormat.count(950) == "950")
    }

    @Test func aFileIsShownAsItsNameAndTheFolderItIsIn() {
        func parts(_ path: String) -> [String] {
            let file = VolumeUsageReport.File(path: path, bytes: 1)
            return [file.name, file.folder]
        }
        #expect(parts("/data/vm/disk.qcow2") == ["disk.qcow2", "/data/vm"])
        #expect(parts("/swapfile") == ["swapfile", "/"])
        #expect(parts(#"C:\Users\x\big.iso"#) == ["big.iso", #"C:\Users\x"#])
        #expect(parts(#"C:\pagefile.sys"#) == ["pagefile.sys", #"C:\"#])
    }

    @Test func aRunningScanShowsHowLongItHasBeenGoing() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(VolumeLargestFilesView.elapsed(from: start, to: start.addingTimeInterval(8.9)) == "8 s")
        #expect(VolumeLargestFilesView.elapsed(from: start, to: start.addingTimeInterval(65)) == "1 min 05 s")
        #expect(VolumeLargestFilesView.elapsed(from: start, to: start.addingTimeInterval(-3)) == "0 s")
    }

    @Test func theSummarySaysHowMuchWasLookedAt() throws {
        #expect(VolumeUsageFormat.headline(for: try decoded(report())) == "Largest 2 of 3.2M files")
        #expect(VolumeUsageFormat.headline(for: try decoded(report([], scanned: 0)))
                == "No files here that this login can read")
    }

    @Test func theSummaryNamesWhatTheScanCouldNotSee() throws {
        #expect(VolumeUsageFormat.caveats(for: try decoded(report())).isEmpty)
        let caveats = VolumeUsageFormat.caveats(for: try decoded(report(unreadable: 72, cloudOnly: 912, complete: false)))
        #expect(caveats == [
            "The scan ran out of time, so larger files may exist.",
            "72 folders or files could not be read by this login.",
            "912 cloud-only items skipped; they use no space on this disk.",
        ])
        #expect(VolumeUsageFormat.caveats(for: try decoded(report(unreadable: 1, cloudOnly: 1))) == [
            "1 folder or file could not be read by this login.",
            "1 cloud-only item skipped; it uses no space on this disk.",
        ])
    }
}

/// Holds a host command open so a test can look at the model mid-scan.
private actor ScanGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters = []
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }

    func resume() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}
