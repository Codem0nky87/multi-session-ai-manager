import Foundation

/// One action a plugin declares in its manifest, as reported by
/// `herdr plugin list --json`. Invoked on the host with
/// `herdr plugin action invoke`.
struct PluginAction: Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    /// Where Herdr offers this action (e.g. `["pane"]` for the pane context
    /// menu). Empty means unrestricted.
    let contexts: [String]
}

/// One plugin installed on a host, as reported by `herdr plugin list --json`.
struct InstalledPlugin: Identifiable, Equatable, Sendable {
    let pluginID: String
    let name: String
    let version: String
    let description: String
    let enabled: Bool
    /// `owner/repo` this plugin was installed from, or nil for a locally linked
    /// one. Read from the CLI's `source` OBJECT (`{kind, owner, repo, ...}`) --
    /// it is not a string, and treating it as one left this nil for every
    /// plugin, so nothing could ever be recognised as already installed.
    let originRepository: String?
    var actions: [PluginAction] = []

    var id: String { pluginID }

    /// Actions that set up the plugin's keybindings, offered as buttons on the
    /// plugin's row. Matched on the "keybind" stem (Herdr's menu says
    /// "keybinds", Ferry's action says "keybindings") because the manifest has
    /// no structured action kind. Contextual actions are excluded: the manager
    /// sheet has no pane to invoke them from.
    var keybindingInstallers: [PluginAction] {
        actions.filter { action in
            action.contexts.isEmpty
                && (action.id.localizedCaseInsensitiveContains("keybind")
                    || action.title.localizedCaseInsensitiveContains("keybind"))
        }
    }
}

/// Lists, installs and uninstalls Herdr plugins on a host over SSH.
///
/// Separate from `HerdrPluginInstaller`, which installs one SPECIFIC plugin and
/// wires it up for file transfer. This is the general manager.
enum HerdrPluginManagement {

    static let listCommand = "herdr plugin list --json"
    static let listTimeout = Duration.seconds(30)
    static let outputLimit = 1024 * 1024

    /// Long, for the same reason the file-viewer install is: a plugin without a
    /// prebuilt binary for the host's platform is built from source with cargo.
    static let installTimeout = Duration.seconds(900)
    static let uninstallTimeout = Duration.seconds(120)

    enum Failure: Error, Equatable {
        /// The plugin has no prebuilt binary for this host and the toolchain it
        /// needs to build from source is missing. Distinct because the fix is
        /// specific and the user can act on it.
        case buildToolchainMissing(tool: String, plugin: String)
        case invalidSource(String)
        case listFailed(String)
        case installFailed(String)
        case uninstallFailed(String)
        case actionFailed(String)
    }

    /// Generous for a one-shot action: a keybinding installer may also reload
    /// the running Herdr server before it answers.
    static let actionTimeout = Duration.seconds(120)

    static func invokeActionCommand(pluginID: String, actionID: String) -> String {
        "herdr plugin action invoke --plugin \(pluginID) \(actionID)"
    }

    /// Runs one manifest action and returns the command's answer. There is no
    /// generic way to verify what an action did (each plugin's is different),
    /// so the output IS the result — the caller shows it as-is.
    static func invokeAction(
        pluginID: String, actionID: String, using service: SSHService
    ) async throws -> String {
        // Both ids come from a third-party manifest and are interpolated into a
        // command line, so they get the same shell-metacharacter refusal as an
        // uninstall's plugin id.
        guard isValidPluginID(pluginID) else { throw Failure.invalidSource(pluginID) }
        guard isValidPluginID(actionID) else { throw Failure.invalidSource(actionID) }
        do {
            let result = try await service.run(
                invokeActionCommand(pluginID: pluginID, actionID: actionID),
                timeout: actionTimeout,
                outputLimit: outputLimit
            )
            return tail(of: result.stdoutString + result.stderrString,
                        fallback: "The action reported nothing.")
        } catch {
            throw Failure.actionFailed("\(error)")
        }
    }

    // MARK: - Source validation

    /// Accepts `owner/repo` or `owner/repo/subdir`, which is what
    /// `herdr plugin install` takes.
    ///
    /// Validated rather than passed through: this string is interpolated into a
    /// command line, so a value carrying a space, quote or semicolon would run
    /// as a second command on the user's host.
    static func isValidSource(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// A git ref: branch, tag or sha. Same reasoning as `isValidSource`.
    static func isValidRef(_ ref: String) -> Bool {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 100 else { return false }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// A plugin id, for uninstall.
    static func isValidPluginID(_ pluginID: String) -> Bool {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128 else { return false }
        // The manifest spec allows letters, digits, dot, colon, underscore, hyphen.
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Commands

    /// `-y` is required, not defensive: `herdr plugin install` refuses outright
    /// when stdin is not interactive, and an SSH exec channel never is.
    static func installCommand(source: String, ref: String?) -> String {
        var command = "herdr plugin install \(source) --yes"
        if let ref, !ref.isEmpty { command += " --ref \(ref)" }
        return command
    }

    static func uninstallCommand(pluginID: String) -> String {
        "herdr plugin uninstall \(pluginID)"
    }

    // MARK: - Operations

    static func list(using service: SSHService) async throws -> [InstalledPlugin] {
        let output: String
        do {
            let result = try await service.run(
                listCommand, timeout: listTimeout, outputLimit: outputLimit
            )
            output = result.stdoutString
        } catch {
            throw Failure.listFailed("\(error)")
        }
        return try parseList(output)
    }

    /// Installs, then VERIFIES by listing — never by exit status, which Citadel
    /// does not surface reliably.
    static func install(
        source: String,
        ref: String? = nil,
        using service: SSHService
    ) async throws -> [InstalledPlugin] {
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidSource(trimmedSource) else { throw Failure.invalidSource(source) }
        let trimmedRef = ref?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedRef, !trimmedRef.isEmpty, !isValidRef(trimmedRef) {
            throw Failure.invalidSource(trimmedRef)
        }

        let before = (try? await list(using: service)) ?? []

        // A throw here is NOT conclusive. A plugin install downloads a prebuilt
        // binary and falls back to a cargo build, so it can run for minutes; over
        // a slow link the channel can close before Citadel sees a clean finish
        // while the install on the host completed. Reporting that as failure is
        // how an install that WORKED came back as "install failed".
        var installFailure: (any Error)?
        // Captured, not discarded. `herdr plugin install` explains itself
        // clearly when it fails -- "plugin build failed ... cargo ... No such
        // file or directory" -- and throwing that away left the user with
        // "the plugin did not appear", which says nothing they can act on.
        var installOutput = ""
        do {
            let result = try await service.run(
                installCommand(source: trimmedSource, ref: trimmedRef),
                timeout: installTimeout,
                outputLimit: outputLimit
            )
            installOutput = result.stdoutString + result.stderrString
        } catch {
            installFailure = error
        }

        let after: [InstalledPlugin]
        do {
            after = try await list(using: service)
        } catch {
            // Could not ask the host at all; the install error is the more useful
            // of the two if there was one.
            throw Failure.installFailed("\(installFailure ?? error)")
        }

        // Presence decides, never the command's outcome. Counting alone is not
        // enough: reinstalling an existing plugin REPLACES it, so the count is
        // unchanged even though the install succeeded.
        let wanted = repositoryComponent(of: trimmedSource).lowercased()
        let present = after.contains { $0.originRepository?.lowercased() == wanted }
        guard present || after.count > before.count else {
            // A missing build toolchain has a specific, actionable fix, so it is
            // told apart rather than buried in installer output.
            if let tool = missingBuildTool(in: installOutput) {
                throw Failure.buildToolchainMissing(tool: tool, plugin: trimmedSource)
            }
            if let installFailure {
                throw Failure.installFailed("\(installFailure)")
            }
            throw Failure.installFailed(
                Self.tail(of: installOutput, fallback: "the plugin did not appear in `herdr plugin list`")
            )
        }
        return after
    }

    static func uninstall(
        pluginID: String,
        using service: SSHService
    ) async throws -> [InstalledPlugin] {
        let trimmed = pluginID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidPluginID(trimmed) else { throw Failure.invalidSource(pluginID) }
        var uninstallFailure: (any Error)?
        do {
            _ = try await service.run(
                uninstallCommand(pluginID: trimmed),
                timeout: uninstallTimeout,
                outputLimit: outputLimit
            )
        } catch {
            uninstallFailure = error
        }
        let after: [InstalledPlugin]
        do {
            after = try await list(using: service)
        } catch {
            throw Failure.uninstallFailed("\(uninstallFailure ?? error)")
        }
        // Absence decides, for the same reason presence does on install.
        guard !after.contains(where: { $0.pluginID == trimmed }) else {
            throw Failure.uninstallFailed(
                uninstallFailure.map { "\($0)" } ?? "\(trimmed) is still installed"
            )
        }
        return after
    }

    /// The build tool a failed install could not start, if that is why it failed.
    ///
    /// A plugin with no prebuilt binary for this platform falls back to building
    /// from source; `herdr` reports the command it tried and the OS error. That
    /// is worth recognising because the remedy — install the toolchain on the
    /// host — is not something the user could guess from raw output.
    static func missingBuildTool(in output: String) -> String? {
        guard output.contains("plugin build failed")
            || output.lowercased().contains("failed to start") else { return nil }
        for tool in ["cargo", "go", "npm", "pnpm", "yarn", "bun", "make", "zig"]
        where output.range(of: "command: \(tool)") != nil
            || output.range(of: "build: \(tool)") != nil {
            return tool
        }
        return nil
    }

    /// The last few lines of installer output — where the reason lives.
    static func tail(of output: String, lines: Int = 6, fallback: String) -> String {
        let trimmed = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: "\n")
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// `owner/repo` from the CLI's `source` field.
    ///
    /// Herdr reports it as an OBJECT — `{"kind":"github","owner":…,"repo":…,
    /// "resolved_commit":…}`. A string form (`github:owner/repo@sha`) is also
    /// accepted so a future or older shape does not silently read as "unknown
    /// origin", which is what made every install look like it had not landed.
    static func originRepository(from raw: Any?) -> String? {
        if let object = raw as? [String: Any],
           let owner = object["owner"] as? String,
           let repo = object["repo"] as? String,
           !owner.isEmpty, !repo.isEmpty {
            return "\(owner)/\(repo)"
        }
        if let text = raw as? String, text.hasPrefix("github:") {
            let withoutScheme = text.dropFirst("github:".count)
            return String(withoutScheme.split(separator: "@").first ?? withoutScheme)
        }
        return nil
    }

    /// `owner/repo` from `owner/repo[/subdir]`.
    static func repositoryComponent(of source: String) -> String {
        source.split(separator: "/").prefix(2).joined(separator: "/")
    }

    // MARK: - Parsing

    /// Extracts the plugin array from `herdr plugin list --json`.
    ///
    /// The JSON is found rather than assumed to be the whole of stdout: the
    /// command runs through a shell that may print anything before it.
    static func parseList(_ output: String) throws -> [InstalledPlugin] {
        guard let start = output.firstIndex(of: "{") else {
            throw Failure.listFailed("no JSON in `herdr plugin list` output")
        }
        let candidate = String(output[start...])
        guard let data = candidate.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let plugins = result["plugins"] as? [[String: Any]]
        else {
            throw Failure.listFailed("could not read `herdr plugin list` output")
        }

        return plugins.compactMap { entry in
            guard let pluginID = entry["plugin_id"] as? String else { return nil }
            return InstalledPlugin(
                pluginID: pluginID,
                name: entry["name"] as? String ?? pluginID,
                version: entry["version"] as? String ?? "",
                description: entry["description"] as? String ?? "",
                // A plugin with no `enabled` key is treated as enabled, matching
                // Herdr: the key records a deliberate disable.
                enabled: entry["enabled"] as? Bool ?? true,
                originRepository: Self.originRepository(from: entry["source"]),
                actions: Self.parseActions(entry["actions"])
            )
        }
    }

    private static func parseActions(_ value: Any?) -> [PluginAction] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String,
                  let title = entry["title"] as? String else { return nil }
            return PluginAction(
                id: id,
                title: title,
                description: entry["description"] as? String ?? "",
                contexts: entry["contexts"] as? [String] ?? []
            )
        }
    }
}
