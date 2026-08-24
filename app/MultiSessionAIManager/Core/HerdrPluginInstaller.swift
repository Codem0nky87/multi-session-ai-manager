import Foundation

/// Installs the `herdr-file-viewer` plugin on a host and binds keys to it.
///
/// Without this the `open = "msam-send"` config that `MSAMSendInstaller` writes
/// is inert -- it configures a plugin that is not there. The two run together as
/// one setup step.
enum HerdrPluginInstaller {

    static let pluginSource = "smarzban/herdr-file-viewer"
    static let pluginID = "herdr-file-viewer"

    /// `--yes` is REQUIRED, not belt-and-braces: `herdr plugin install` refuses
    /// outright when stdin is not interactive, and an SSH exec channel never is.
    static let installCommand = "herdr plugin install \(pluginSource) --yes"

    /// Generous because the install has a slow path. It fetches a prebuilt
    /// binary matching the platform, and on ANY miss -- no matching release,
    /// checksum failure, unsupported arch -- falls back to building from source
    /// with cargo, which is minutes and needs a Rust toolchain.
    static let installTimeout = Duration.seconds(900)
    static let commandTimeout = Duration.seconds(60)
    static let outputLimit = 256 * 1024

    static let herdrConfigRelativePath = ".config/herdr/config.toml"

    /// Marks the stanza this installer owns, so a re-run recognises its own edit.
    static let keybindMarker = "# Added by MSAM: herdr-file-viewer"

    static let keybindStanza = """

        \(keybindMarker)
        [[keys.command]]
        key = "prefix+f"
        type = "plugin_action"
        command = "herdr-file-viewer.open-file-viewer"
        description = "open file viewer in split"

        [[keys.command]]
        key = "prefix+shift+f"
        type = "plugin_action"
        command = "herdr-file-viewer.open-file-viewer-tab"
        description = "open file viewer in tab"
        """

    enum PluginOutcome: String, Equatable {
        case installed = "PLUGIN_INSTALLED"
        case alreadyInstalled = "PLUGIN_ALREADY"
        /// The prebuilt fetch missed AND cargo is absent, so there is nothing to
        /// build with. Distinct from a generic failure because the fix is
        /// specific: install Rust, or use a host with a matching release.
        case noToolchain = "PLUGIN_NO_TOOLCHAIN"
    }

    enum KeybindOutcome: String, Equatable {
        case bound = "KEYS_BOUND"
        case alreadyBound = "KEYS_ALREADY"
        /// `prefix+f` is already bound to something else. NOT overwritten -- it
        /// is a key the user chose.
        case conflict = "KEYS_CONFLICT"
    }

    enum Failure: Error, Equatable {
        case installFailed(String)
        case noToolchain
    }

    struct Result: Equatable {
        let plugin: PluginOutcome
        let keybind: KeybindOutcome
        let configPath: String
    }

    /// Reports whether the plugin is already present, so a re-run does not spend
    /// minutes reinstalling it.
    static let probeCommand = """
        herdr plugin list 2>/dev/null | grep -q '\(pluginID)' \
        && printf '%s\\n' '\(PluginOutcome.alreadyInstalled.rawValue)'
        """

    /// Appends the keybinding unless `prefix+f` is already spoken for, then asks
    /// the running server to reload so it takes effect without restarting the
    /// user's session.
    static let keybindCommand = """
        cfg="$HOME/\(herdrConfigRelativePath)"
        mkdir -p "$(dirname "$cfg")"
        : >> "$cfg"
        if grep -q 'herdr-file-viewer.open-file-viewer' "$cfg"; then
          printf '%s\\n' '\(KeybindOutcome.alreadyBound.rawValue)'
        elif grep -qE '^[[:space:]]*key[[:space:]]*=[[:space:]]*"prefix\\+f"' "$cfg"; then
          printf '%s\\n' '\(KeybindOutcome.conflict.rawValue)'
        else
          cat >> "$cfg" <<'MSAMKEYS'
        \(keybindStanza)
        MSAMKEYS
          printf '%s\\n' '\(KeybindOutcome.bound.rawValue)'
        fi
        herdr server reload-config >/dev/null 2>&1 || true
        """

    /// Bind the viewer's keys and reload the running server.
    ///
    /// Split out from `install` so the plugin MANAGER can own installation --
    /// one place to add and remove plugins -- while this keeps the part the
    /// manager has no reason to know about.
    static func bindKeys(using service: SSHService) async throws -> Result {
        let home: String
        do {
            let probe = try await service.run(
                "printf %s \"$HOME\"", timeout: commandTimeout, outputLimit: outputLimit
            )
            home = probe.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Failure.installFailed("could not reach the host: \(error)")
        }
        guard home.hasPrefix("/") else {
            throw Failure.installFailed("the host did not report a home directory")
        }

        let output: String
        do {
            output = try await service.run(
                keybindCommand, timeout: commandTimeout, outputLimit: outputLimit
            ).stdoutString
        } catch {
            throw Failure.installFailed("could not write the keybinding: \(error)")
        }

        return Result(
            plugin: .alreadyInstalled,
            keybind: parseKeybindOutcome(output),
            configPath: "\(home)/\(herdrConfigRelativePath)"
        )
    }

    static func install(using service: SSHService) async throws -> Result {
        let home: String
        do {
            let probe = try await service.run(
                "printf %s \"$HOME\"", timeout: commandTimeout, outputLimit: outputLimit
            )
            home = probe.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Failure.installFailed("could not reach the host: \(error)")
        }
        guard home.hasPrefix("/") else {
            throw Failure.installFailed("the host did not report a home directory")
        }

        // Skip the slow path entirely when it is already there.
        let alreadyPresent: Bool
        do {
            let probe = try await service.run(
                probeCommand, timeout: commandTimeout, outputLimit: outputLimit
            )
            alreadyPresent = probe.stdoutString.contains(PluginOutcome.alreadyInstalled.rawValue)
        } catch {
            alreadyPresent = false
        }

        var pluginOutcome: PluginOutcome = .alreadyInstalled
        if !alreadyPresent {
            let output: String
            do {
                let result = try await service.run(
                    installCommand, timeout: installTimeout, outputLimit: outputLimit
                )
                output = result.stdoutString + result.stderrString
            } catch {
                throw Failure.installFailed("\(error)")
            }
            // Verified by capability, never by exit status -- Citadel does not
            // surface one reliably, which is why HerdrInstaller works this way too.
            let verified = try await isPluginPresent(using: service)
            guard verified else {
                if Self.mentionsMissingToolchain(output) { throw Failure.noToolchain }
                throw Failure.installFailed(Self.tail(of: output))
            }
            pluginOutcome = .installed
        }

        let keybindOutput: String
        do {
            let result = try await service.run(
                keybindCommand, timeout: commandTimeout, outputLimit: outputLimit
            )
            keybindOutput = result.stdoutString
        } catch {
            throw Failure.installFailed("could not write the keybinding: \(error)")
        }

        return Result(
            plugin: pluginOutcome,
            keybind: parseKeybindOutcome(keybindOutput),
            configPath: "\(home)/\(herdrConfigRelativePath)"
        )
    }

    static func isPluginPresent(using service: SSHService) async throws -> Bool {
        do {
            let result = try await service.run(
                probeCommand, timeout: commandTimeout, outputLimit: outputLimit
            )
            return result.stdoutString.contains(PluginOutcome.alreadyInstalled.rawValue)
        } catch {
            return false
        }
    }

    /// A missing Rust toolchain has a specific fix, so it is worth telling apart
    /// from a generic install failure.
    static func mentionsMissingToolchain(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("cargo: not found")
            || lowered.contains("cargo: command not found")
            || lowered.contains("command not found: cargo")
            || lowered.contains("no such file or directory: cargo")
    }

    static func parseKeybindOutcome(_ output: String) -> KeybindOutcome {
        if output.contains(KeybindOutcome.conflict.rawValue) { return .conflict }
        if output.contains(KeybindOutcome.alreadyBound.rawValue) { return .alreadyBound }
        return .bound
    }

    /// Installer output can be long; the last few lines are what says why.
    static func tail(of output: String, lines: Int = 4) -> String {
        let trimmed = output.split(separator: "\n").suffix(lines).joined(separator: "\n")
        return trimmed.isEmpty ? "the plugin did not install" : trimmed
    }
}
