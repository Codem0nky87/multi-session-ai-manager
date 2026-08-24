import Foundation
import Observation

/// Drives the per-host plugin manager: what is installed, what can be browsed,
/// and the install/uninstall operations on both.
@MainActor
@Observable
final class HerdrPluginManagerModel {

    enum ListState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    enum CatalogueState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    let connection: HostConnection
    private let catalogue: any PluginCatalogueFetching

    private(set) var installed: [InstalledPlugin] = []
    private(set) var listState: ListState = .idle

    private(set) var results: [CataloguePlugin] = []
    private(set) var catalogueState: CatalogueState = .idle

    /// A long operation the user should be watching rather than guessing at.
    ///
    /// Plugin work can take minutes -- a source build, a toolchain download --
    /// and a row-sized spinner does not carry that. This drives a modal instead,
    /// so it is obvious something is happening, what it is, and that it is
    /// expected to take a while.
    struct Operation: Equatable {
        let title: String
        var step: String
        /// Set when the wait is legitimately long, so a slow step does not read
        /// as a hang.
        var isSlow: Bool = false
    }

    private(set) var operation: Operation?

    /// The plugin id currently being installed or removed, so only its own row
    /// shows a spinner rather than the whole list going inert.
    private(set) var busyIdentifier: String?
    private(set) var errorMessage: String?
    private(set) var noticeMessage: String?
    /// Set when an install failed only because the host lacks a build
    /// toolchain, so the UI can offer to fix it rather than leaving the user to
    /// go and do it by hand on a machine the app already has a shell on.
    private(set) var missingToolchain: (tool: BuildToolchainInstaller.Tool, source: String)?
    /// Populated only when the automatic install has actually failed, so the
    /// manual steps appear as a fallback rather than as noise beside a button
    /// that usually works.
    private(set) var manualSteps: [String] = []
    /// The host's platform, learned during a toolchain install.
    private(set) var hostPlatform: BuildToolchainInstaller.Platform = .unknown
    private(set) var hostHasBrew = false

    init(connection: HostConnection, catalogue: any PluginCatalogueFetching = GitHubPluginCatalogue()) {
        self.connection = connection
        self.catalogue = catalogue
    }

    var isBusy: Bool { busyIdentifier != nil }

    func isInstalled(_ fullName: String) -> Bool {
        installed.contains { $0.originRepository?.lowercased() == fullName.lowercased() }
    }

    // MARK: - Installed list

    func refresh() async {
        guard let service = connection.provisioningCommandRunner else {
            listState = .failed("Not connected to this host.")
            return
        }
        listState = .loading
        do {
            installed = try await HerdrPluginManagement.list(using: service)
            listState = .loaded
        } catch {
            listState = .failed(Self.message(for: error))
        }
    }

    // MARK: - Catalogue

    func search(_ query: String) async {
        catalogueState = .loading
        errorMessage = nil
        do {
            results = try await catalogue.search(query)
            catalogueState = .loaded
        } catch {
            results = []
            catalogueState = .failed(Self.message(for: error))
        }
    }

    /// Checks a repository really carries a plugin manifest.
    ///
    /// Done per row on demand, never for a whole page: the topic alone does not
    /// make a repository a plugin (plenty of unrelated projects wear the tag),
    /// and unauthenticated GitHub allows only a handful of requests a minute.
    func verifyThenInstall(_ plugin: CataloguePlugin) async {
        busyIdentifier = plugin.fullName
        operation = Operation(title: plugin.repositoryName, step: "Checking the repository…")
        defer { busyIdentifier = nil; operation = nil }
        errorMessage = nil
        noticeMessage = nil

        do {
            guard try await catalogue.hasManifest(plugin.fullName) else {
                errorMessage = """
                    \(plugin.fullName) carries the herdr-plugin topic but has no \
                    herdr-plugin.toml, so Herdr cannot install it.
                    """
                return
            }
        } catch {
            // A rate limit must not block the install: verification is a
            // courtesy, and `herdr plugin install` fails safely by itself.
            noticeMessage = "Could not pre-check \(plugin.fullName): \(Self.message(for: error))"
        }
        await performInstall(source: plugin.fullName, ref: nil, identifier: plugin.fullName)
    }

    // MARK: - Operations

    func install(source: String, ref: String?) async {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard HerdrPluginManagement.isValidSource(trimmed) else {
            errorMessage = "\"\(trimmed)\" is not an owner/repo path."
            return
        }
        busyIdentifier = trimmed
        defer { busyIdentifier = nil }
        await performInstall(source: trimmed, ref: ref, identifier: trimmed)
    }

    private func performInstall(source: String, ref: String?, identifier: String) async {
        guard let service = connection.provisioningCommandRunner else {
            errorMessage = "Not connected to this host."
            return
        }
        // A plugin with no prebuilt binary is compiled on the host, so this step
        // is minutes rather than seconds and has to say so.
        operation = Operation(title: source, step: "Installing on the host…", isSlow: true)
        do {
            installed = try await HerdrPluginManagement.install(
                source: source, ref: ref, using: service
            )
            listState = .loaded
            noticeMessage = "Installed \(source)."
            missingToolchain = nil
        } catch let failure as HerdrPluginManagement.Failure {
            errorMessage = Self.message(for: failure)
            if case .buildToolchainMissing(let tool, _) = failure,
               let known = BuildToolchainInstaller.Tool(rawValue: tool) {
                missingToolchain = (known, source)
            }
            await refresh()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func uninstall(_ plugin: InstalledPlugin) async {
        guard let service = connection.provisioningCommandRunner else {
            errorMessage = "Not connected to this host."
            return
        }
        busyIdentifier = plugin.pluginID
        operation = Operation(title: plugin.name, step: "Removing from the host…")
        defer { busyIdentifier = nil; operation = nil }
        errorMessage = nil
        noticeMessage = nil
        do {
            installed = try await HerdrPluginManagement.uninstall(
                pluginID: plugin.pluginID, using: service
            )
            noticeMessage = "Removed \(plugin.name)."
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    /// Install the toolchain the last failed install needed, then retry it.
    ///
    /// Retrying automatically is the point: installing `cargo` is not the thing
    /// the user asked for, it is a prerequisite, so leaving them to press
    /// Install again would be busywork.
    func installMissingToolchainAndRetry() async {
        guard let pending = missingToolchain else { return }
        guard let service = connection.provisioningCommandRunner else {
            errorMessage = "Not connected to this host."
            return
        }
        busyIdentifier = pending.source
        operation = Operation(
            title: pending.source,
            step: "Installing \(pending.tool.rawValue) on the host…",
            isSlow: true
        )
        defer { busyIdentifier = nil; operation = nil }
        errorMessage = nil
        noticeMessage = nil

        do {
            let context = try await BuildToolchainInstaller.install(pending.tool, using: service)
            hostPlatform = context.platform
            hostHasBrew = context.hasBrew
        } catch let failure as BuildToolchainInstaller.Failure {
            noticeMessage = nil
            errorMessage = Self.message(for: failure)
            if case .detected(let platform, let brew) = failure.context {
                hostPlatform = platform
                hostHasBrew = brew
            }
            manualSteps = BuildToolchainInstaller.manualSteps(
                for: pending.tool, platform: hostPlatform, hasBrew: hostHasBrew
            )
            return
        } catch {
            noticeMessage = nil
            errorMessage = Self.message(for: error)
            manualSteps = BuildToolchainInstaller.manualSteps(
                for: pending.tool, platform: hostPlatform, hasBrew: hostHasBrew
            )
            return
        }
        manualSteps = []
        missingToolchain = nil
        operation?.step = "Installed \(pending.tool.rawValue). Retrying the plugin…"
        await performInstall(source: pending.source, ref: nil, identifier: pending.source)
    }

    // MARK: - File transfer wiring

    /// The plugin this app can additionally wire up for host -> iPad transfer.
    static let fileViewerRepository = HerdrPluginInstaller.pluginSource

    func isFileViewer(_ plugin: InstalledPlugin) -> Bool {
        plugin.originRepository?.lowercased() == Self.fileViewerRepository.lowercased()
            || plugin.pluginID == HerdrPluginInstaller.pluginID
    }

    /// Bind the viewer's keys and point its `open` command at `msam-send`.
    ///
    /// Lives on the installed plugin's own row rather than in a separate setup
    /// card: installing plugins belongs to one place, and this is the step that
    /// only makes sense once THIS plugin is present.
    func configureFileTransfer(for plugin: InstalledPlugin) async {
        guard let service = connection.provisioningCommandRunner else {
            errorMessage = "Not connected to this host."
            return
        }
        busyIdentifier = plugin.pluginID
        operation = Operation(title: plugin.name, step: "Wiring up file transfer…")
        defer { busyIdentifier = nil; operation = nil }
        errorMessage = nil
        noticeMessage = nil

        var notes: [String] = []
        do {
            let keys = try await HerdrPluginInstaller.bindKeys(using: service)
            if keys.keybind == .conflict {
                notes.append("`prefix+f` was already bound, so it was left alone.")
            }
            let send = try await MSAMSendInstaller.install(using: service)
            if send.configOutcome == .conflict {
                notes.append("The viewer's `open` command was already set, so it was left alone: "
                             + send.configPath)
            }
        } catch {
            errorMessage = Self.message(for: error)
            return
        }
        noticeMessage = ([
            "Ready — press ctrl+b then f, then O on a file. Reopen the viewer if it is already open."
        ] + notes).joined(separator: " ")
    }

    // MARK: - Wording

    static func message(for error: Error) -> String {
        if let failure = error as? HerdrPluginManagement.Failure {
            switch failure {
            case .buildToolchainMissing(let tool, let plugin):
                return "\(plugin) has no prebuilt binary for this host and must be built from "
                    + "source, but `\(tool)` is not installed there. Install \(tool) on the host, "
                    + "then try again."
            case .invalidSource(let value):
                return "\"\(value)\" is not a valid owner/repo path."
            case .listFailed(let reason):
                return "Could not list plugins: \(reason)"
            case .installFailed(let reason):
                return "Install failed: \(reason)"
            case .uninstallFailed(let reason):
                return "Uninstall failed: \(reason)"
            }
        }
        if let failure = error as? BuildToolchainInstaller.Failure {
            switch failure {
            case .unsupportedTool(let tool):
                return "This app cannot install \(tool) for you. Install it on the host, then retry."
            case .unsupportedPlatform(let platform):
                return "Could not tell what kind of host this is (\(platform.rawValue)), so the "
                    + "toolchain cannot be installed automatically."
            case .installFailed(let reason):
                return "Could not install the toolchain: \(reason)"
            case .stillMissing(let tool):
                return "\(tool) still is not on the host's PATH after installing. Herdr runs plugin "
                    + "builds in its own login shell, so it may need restarting to pick it up."
            }
        }
        if let failure = error as? MSAMSendInstaller.Failure {
            switch failure {
            case .notConnected: return "Connect to this host first."
            case .uploadFailed(let reason): return "Could not install msam-send: \(reason)"
            case .verificationFailed(let reason): return "msam-send did not verify: \(reason)"
            }
        }
        if let failure = error as? HerdrPluginInstaller.Failure {
            switch failure {
            case .noToolchain: return "The host has no Rust toolchain to build with."
            case .installFailed(let reason): return "Could not configure the viewer: \(reason)"
            }
        }
        if let failure = error as? PluginCatalogueError {
            switch failure {
            case .rateLimited:
                return "GitHub is rate-limiting the catalogue. Wait a minute and try again."
            case .unavailable(let reason):
                return "The plugin catalogue is unavailable: \(reason)"
            }
        }
        return error.localizedDescription
    }
}
