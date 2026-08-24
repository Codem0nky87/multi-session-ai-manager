import Foundation

/// Installs a build toolchain a plugin needs, on the host, over SSH.
///
/// Some Herdr plugins ship no prebuilt binary and build from source, so the
/// install fails on a host without the toolchain. Reporting that is better than
/// a blank failure, but the user still has to go and fix it by hand — and they
/// already gave the app an authenticated shell on that machine.
enum BuildToolchainInstaller {

    enum Platform: String, Equatable {
        case macOS
        case linux
        case windows
        case unknown
    }

    /// Tools this can install. Anything else is reported rather than guessed at.
    enum Tool: String, Equatable, CaseIterable {
        case cargo
    }

    static let detectTimeout = Duration.seconds(30)
    /// Rust builds are slow, and this compiles a toolchain download plus the
    /// plugin afterwards.
    static let installTimeout = Duration.seconds(1200)
    static let outputLimit = 256 * 1024

    enum Failure: Error, Equatable {
        case unsupportedTool(String)
        case unsupportedPlatform(Platform)
        case installFailed(String)
        case stillMissing(tool: String)

        /// What was learned about the host before failing, so the caller can
        /// offer manual steps that match it rather than generic ones.
        enum Context: Equatable {
            case none
            case detected(platform: Platform, hasBrew: Bool)
        }

        var context: Context {
            if case .unsupportedPlatform(let platform) = self {
                return .detected(platform: platform, hasBrew: false)
            }
            return .none
        }
    }

    /// What the installer learned about the host.
    struct HostContext: Equatable {
        let platform: Platform
        let hasBrew: Bool
    }

    // MARK: - Platform

    /// `uname -s`, with a Windows fallback for shells that have no `uname`.
    static let detectCommand = "uname -s 2>/dev/null || echo Windows"

    static func platform(from output: String) -> Platform {
        let text = output.lowercased()
        if text.contains("darwin") { return .macOS }
        // MINGW/MSYS/CYGWIN all report a uname that is not Linux; check before it.
        if text.contains("mingw") || text.contains("msys")
            || text.contains("cygwin") || text.contains("windows") { return .windows }
        if text.contains("linux") { return .linux }
        return .unknown
    }

    // MARK: - Commands

    /// Whether Homebrew is available, so macOS can prefer it.
    static let brewProbeCommand = "command -v brew >/dev/null 2>&1 && printf %s HAS_BREW"
    static func hasBrew(_ output: String) -> Bool { output.contains("HAS_BREW") }

    /// `rustup` rather than a system package manager on Linux.
    ///
    /// `apt`/`dnf`/`pacman` all need root, and an SSH exec channel cannot answer
    /// a sudo password prompt — the install would hang until it timed out.
    /// `rustup` installs entirely under `$HOME`, so it needs no privileges.
    /// `-y` is required for the same reason `--yes` is elsewhere: stdin is not a
    /// terminal.
    static let rustupCommand =
        "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path"

    static func installCommand(for tool: Tool, platform: Platform, hasBrew: Bool) -> String? {
        switch tool {
        case .cargo:
            switch platform {
            case .macOS:
                // Homebrew needs no root, and puts cargo somewhere already on
                // PATH -- which matters because HERDR runs the plugin build, in
                // its own environment, not ours.
                return hasBrew ? "brew install rust" : rustupCommand
            case .linux:
                return rustupCommand
            case .windows:
                return "winget install --id Rustlang.Rustup -e --accept-source-agreements "
                     + "--accept-package-agreements"
            case .unknown:
                return nil
            }
        }
    }

    /// Where a rustup install puts the binaries.
    ///
    /// `--no-modify-path` is deliberate: rustup would otherwise append to
    /// `~/.profile`, which bash ignores when a `~/.bash_profile` exists -- the
    /// exact shadowing that stopped Herdr itself being found. The path is added
    /// explicitly instead, next to the one Herdr's installer uses.
    static let cargoBinDirectory = "$HOME/.cargo/bin"

    /// Puts the toolchain on PATH for the login shells that will run the build.
    ///
    /// Appended to `~/.profile` AND `~/.bash_profile` when that exists, because
    /// bash reads only one of them.
    static let persistPathCommand = """
        line='export PATH="$HOME/.cargo/bin:$PATH"'
        for f in "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc"; do
          [ -e "$f" ] || continue
          grep -qF '.cargo/bin' "$f" || printf '\\n%s\\n' "$line" >> "$f"
        done
        [ -e "$HOME/.profile" ] || printf '%s\\n' "$line" > "$HOME/.profile"
        """

    /// Said up front, because "let an app install a compiler on my server"
    /// deserves an answer to "as root?" before the button is pressed.
    static let privilegeNotice =
        "Installs under your home directory on the host. No root or sudo, and nothing system-wide."

    /// What to run by hand if the automatic install does not work.
    ///
    /// Listed rather than left to a search: the user is being told their host
    /// is missing something, and the next thing they need is the command.
    static func manualSteps(for tool: Tool, platform: Platform, hasBrew: Bool) -> [String] {
        switch tool {
        case .cargo:
            switch platform {
            case .macOS:
                return hasBrew
                    ? ["brew install rust"]
                    : [rustupCommand, "source \"$HOME/.cargo/env\""]
            case .linux:
                return [
                    rustupCommand,
                    "source \"$HOME/.cargo/env\"",
                    "# or, with root: sudo apt install cargo   (Debian/Ubuntu)"
                ]
            case .windows:
                return ["winget install --id Rustlang.Rustup -e"]
            case .unknown:
                return ["Install a Rust toolchain (https://rustup.rs), then retry."]
            }
        }
    }

    static func verifyCommand(for tool: Tool) -> String {
        "PATH=\"\(cargoBinDirectory):$PATH\"; export PATH; command -v \(tool.rawValue)"
    }

    // MARK: - Install

    @discardableResult
    static func install(_ tool: Tool, using service: SSHService) async throws -> HostContext {
        let detected: Platform
        do {
            let result = try await service.run(
                detectCommand, timeout: detectTimeout, outputLimit: outputLimit
            )
            detected = platform(from: result.stdoutString)
        } catch {
            throw Failure.installFailed("could not identify the host: \(error)")
        }

        var brewAvailable = false
        if detected == .macOS {
            brewAvailable = hasBrew(
                (try? await service.run(brewProbeCommand, timeout: detectTimeout,
                                        outputLimit: outputLimit))?.stdoutString ?? ""
            )
        }

        guard let command = installCommand(for: tool, platform: detected, hasBrew: brewAvailable) else {
            throw Failure.unsupportedPlatform(detected)
        }

        // As everywhere else here, the command's own outcome is not trusted --
        // presence of the tool afterwards is.
        _ = try? await service.run(command, timeout: installTimeout, outputLimit: outputLimit)
        _ = try? await service.run(persistPathCommand, timeout: detectTimeout, outputLimit: outputLimit)

        let verified = (try? await service.run(
            verifyCommand(for: tool), timeout: detectTimeout, outputLimit: outputLimit
        ))?.stdoutString ?? ""
        guard verified.contains(tool.rawValue) else {
            throw Failure.stillMissing(tool: tool.rawValue)
        }
        return HostContext(platform: detected, hasBrew: brewAvailable)
    }
}
