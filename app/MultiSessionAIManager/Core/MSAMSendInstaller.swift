import Foundation

/// Installs the host side of host->iPad file transfer: the `msam-send` script,
/// and the `herdr-file-viewer` plugin config that points its `open` command at
/// it so pressing `O` on a file queues that file for the iPad.
///
/// Mirrors `HerdrInstaller`'s shape -- probe, install, verify -- and like it does
/// NOT gate on exit status, because Citadel does not surface one reliably. The
/// verification step is the authority.
enum MSAMSendInstaller {

    /// `$HOME/.local/bin` is already on the PATH every bounded command runs
    /// with (see `SSHService.provisioningShellCommand`), so the plugin resolves
    /// `msam-send` by name without an absolute path in its config.
    static let scriptRelativePath = ".local/bin/msam-send"
    static let commandName = "msam-send"

    /// Where the viewer looks for its config when run STANDALONE. Only a
    /// fallback: under herdr the live file is `$HERDR_PLUGIN_CONFIG_DIR/
    /// config.toml`, which `herdr plugin config-dir` prints. Writing to the
    /// standalone path while the viewer runs under herdr produces a config that
    /// is never read -- the install reports success and `O` does nothing.
    static let standaloneConfigDirectory = ".config/herdr-file-viewer"

    static let timeout = Duration.seconds(60)
    static let outputLimit = 64 * 1024

    /// What the plugin runs. The viewer appends the selected path as the final
    /// argument and invokes no shell.
    static let script = """
        #!/bin/sh
        # msam-send -- queue a file for transfer to the iPad (MultiSessionAIManager).
        #
        # Installed by MSAM and wired to the herdr-file-viewer plugin's `open`
        # command, so pressing O on a file in the viewer queues it. The plugin
        # appends the selected path as the final argument and invokes NO shell,
        # so the path arrives here as one argv element however it is spelled.
        set -eu

        outbox_dir="$HOME/.msam"
        mkdir -p "$outbox_dir"

        for arg in "$@"; do
          case "$arg" in
            /*) path="$arg" ;;
            *)  path="$(cd "$(dirname "$arg")" 2>/dev/null && pwd)/$(basename "$arg")" ;;
          esac
          # Only queue something that is actually a readable file: the iPad
          # cannot do anything with a directory, and a dangling path would
          # surface there as a failed download with no explanation.
          [ -f "$path" ] || continue
          printf '%s\\n' "$path" >> "$outbox_dir/outbox"
        done

        """

    /// Marks the config stanza this installer owns, so a re-run can tell its own
    /// edit from one the user made by hand.
    static let configMarker = "# Added by MSAM"

    static let configStanza = """

        \(configMarker): press O on a file in the viewer to send it to the iPad.
        open = "\(commandName)"
        """

    /// What a run did, so the UI can report it honestly rather than saying
    /// "done" over a config it declined to touch.
    enum ConfigOutcome: String, Equatable {
        /// No `open` key was set; the installer added one.
        case added = "ADDED"
        /// Already points at `msam-send`; nothing to do.
        case alreadySet = "ALREADY"
        /// An `open` key exists pointing somewhere else. NOT overwritten -- that
        /// is a setting the user chose, and silently replacing it would break
        /// whatever they wired up.
        case conflict = "CONFLICT"
    }

    /// Makes the uploaded script executable and reports the config outcome. The
    /// script itself is written over SFTP rather than echoed through a shell,
    /// which keeps its quoting out of the command line entirely.
    /// Marks the config path in the finalise output, so the UI reports where the
    /// file actually landed rather than a path it assumed.
    static let configPathMarker = "MSAM_CONFIG_PATH="

    static let finaliseCommand = """
        chmod 0755 "$HOME/\(scriptRelativePath)" || exit 1
        cfgdir="$(herdr plugin config-dir herdr-file-viewer 2>/dev/null)"
        [ -n "$cfgdir" ] || cfgdir="$HOME/\(standaloneConfigDirectory)"
        mkdir -p "$cfgdir"
        cfg="$cfgdir/config.toml"
        : >> "$cfg"
        printf '%s%s\\n' '\(configPathMarker)' "$cfg"
        if grep -qE '^[[:space:]]*open[[:space:]]*=' "$cfg"; then
          if grep -qE '^[[:space:]]*open[[:space:]]*=[[:space:]]*"\(commandName)"' "$cfg"; then
            printf '%s\\n' 'ALREADY'
          else
            printf '%s\\n' 'CONFLICT'
          fi
        else
          cat >> "$cfg" <<'MSAMEOF'
        \(configStanza)
        MSAMEOF
          printf '%s\\n' 'ADDED'
        fi
        """

    /// Confirms the script is on PATH and runnable. This, not an exit status, is
    /// what decides whether the install worked.
    static let verifyCommand = """
        command -v \(commandName) >/dev/null 2>&1 && printf '%s\\n' 'MSAM_SEND_OK'
        """

    enum Failure: Error, Equatable {
        case notConnected
        case uploadFailed(String)
        case verificationFailed(String)
    }

    struct Result: Equatable {
        let configOutcome: ConfigOutcome
        /// Absolute path the config lives at, so the UI can tell the user where
        /// to look when there is a conflict.
        let configPath: String
    }

    static func install(using service: SSHService) async throws -> Result {
        let home: String
        do {
            let probe = try await service.run(
                "mkdir -p \"$HOME/.local/bin\" && printf %s \"$HOME\"",
                timeout: timeout,
                outputLimit: outputLimit
            )
            home = probe.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Failure.uploadFailed("could not prepare ~/.local/bin: \(error)")
        }
        guard home.hasPrefix("/") else {
            throw Failure.uploadFailed("the host did not report a home directory")
        }

        do {
            try await service.writeFile(Data(script.utf8), to: "\(home)/\(scriptRelativePath)")
        } catch {
            throw Failure.uploadFailed("\(error)")
        }

        let outcomeText: String
        do {
            let result = try await service.run(finaliseCommand, timeout: timeout, outputLimit: outputLimit)
            outcomeText = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Failure.uploadFailed("could not enable the script: \(error)")
        }

        // Verify by capability, never by exit status.
        do {
            let verify = try await service.run(verifyCommand, timeout: timeout, outputLimit: outputLimit)
            guard verify.stdoutString.contains("MSAM_SEND_OK") else {
                throw Failure.verificationFailed(
                    "msam-send was installed but is not on the host's PATH"
                )
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.verificationFailed("\(error)")
        }

        return Result(
            configOutcome: parseConfigOutcome(outcomeText),
            configPath: parseConfigPath(outcomeText)
                ?? "\(home)/\(standaloneConfigDirectory)/config.toml"
        )
    }

    /// The finalise script's stdout also carries whatever the login shell felt
    /// like printing, so the marker is searched for rather than compared.
    /// The path the host actually wrote to, reported by the finalise script.
    static func parseConfigPath(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains(configPathMarker) {
            guard let range = line.range(of: configPathMarker) else { continue }
            let path = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") { return path }
        }
        return nil
    }

    static func parseConfigOutcome(_ output: String) -> ConfigOutcome {
        if output.contains(ConfigOutcome.conflict.rawValue) { return .conflict }
        if output.contains(ConfigOutcome.alreadySet.rawValue) { return .alreadySet }
        return .added
    }
}
