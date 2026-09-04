import Foundation

enum AgentToolID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case antigravity
}

enum AgentInstallMethod: String, Codable, Sendable {
    case homebrew
    case homebrewCask = "homebrew-cask"
    case npm
    case pnpm
    case bun
    case native
    case unknown
    case ambiguous

    static func parse(_ value: String) -> Self {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "brew", "homebrew": .homebrew
        case "cask", "homebrew-cask": .homebrewCask
        case "npm": .npm
        case "pnpm": .pnpm
        case "bun": .bun
        case "native", "standalone": .native
        case "ambiguous": .ambiguous
        default: .unknown
        }
    }

    var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .homebrewCask: "Homebrew cask"
        case .npm: "npm"
        case .pnpm: "pnpm"
        case .bun: "Bun"
        case .native: "Native"
        case .unknown: "Unknown"
        case .ambiguous: "Ambiguous"
        }
    }
}

struct AgentToolVersion: Equatable, Codable, Sendable {
    let tool: AgentToolID
    let installed: String?
    let latest: String?
    let channel: String?
    let method: AgentInstallMethod
    let executablePath: String?
    let error: String?

    var isUpdateAvailable: Bool {
        guard let installed, let latest else { return false }
        return AgentVersionComparator.isNewer(latest, than: installed)
    }
}

struct MacOSPublisherIdentity: Equatable, Sendable {
    let teamIdentifier: String
    let signingIdentifier: String
}

struct AgentToolDefinition: Equatable, Sendable {
    let id: AgentToolID
    let displayName: String
    let executable: String
    let herdrKinds: Set<String>
    let exitCommand: String
    let macOSPublisher: MacOSPublisherIdentity?
    let resumeArguments: @Sendable (String) -> [String]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.executable == rhs.executable
            && lhs.herdrKinds == rhs.herdrKinds
            && lhs.exitCommand == rhs.exitCommand
            && lhs.macOSPublisher == rhs.macOSPublisher
    }
}

enum AgentToolRegistry {
    static let definitions: [AgentToolDefinition] = [
        AgentToolDefinition(
            id: .claude,
            displayName: "Claude Code",
            executable: "claude",
            herdrKinds: ["claude"],
            exitCommand: "/exit",
            macOSPublisher: .init(
                teamIdentifier: "Q6L2SF6YDW",
                signingIdentifier: "com.anthropic.claude-code"
            ),
            resumeArguments: { ["--resume", $0] }
        ),
        AgentToolDefinition(
            id: .codex,
            displayName: "Codex",
            executable: "codex",
            herdrKinds: ["codex"],
            exitCommand: "/exit",
            macOSPublisher: .init(
                teamIdentifier: "2DC432GLL2",
                signingIdentifier: "codex"
            ),
            resumeArguments: { ["resume", $0] }
        ),
        AgentToolDefinition(
            id: .antigravity,
            displayName: "Antigravity",
            executable: "agy",
            herdrKinds: ["agy", "antigravity-cli"],
            exitCommand: "/exit",
            macOSPublisher: .init(
                teamIdentifier: "EQHXZ8M8AV",
                signingIdentifier: "cli"
            ),
            resumeArguments: { ["--conversation", $0] }
        )
    ]

    static func definition(for id: AgentToolID) -> AgentToolDefinition {
        // Exhaustive fixed registry: every enum case has one definition.
        definitions.first { $0.id == id }!
    }
}

enum AgentVersionParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?<![0-9A-Za-z])v?([0-9]+(?:\.[0-9]+){1,3}(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)"#
    )

    static func version(in output: String) -> String? {
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              let capture = Range(match.range(at: 1), in: output) else {
            return nil
        }
        let value = String(output[capture])
        return ParsedAgentVersion(value) == nil ? nil : value
    }
}

enum AgentVersionComparator {
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let candidate = ParsedAgentVersion(candidate),
              let installed = ParsedAgentVersion(installed) else {
            return false
        }
        return candidate > installed
    }
}

private struct ParsedAgentVersion: Comparable {
    enum Identifier: Equatable {
        case numeric(Int)
        case text(String)
    }

    let core: [Int]
    let prerelease: [Identifier]?

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") { value.removeFirst() }
        let withoutBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count >= 2,
              coreParts.count <= 4,
              coreParts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              coreParts.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        core = coreParts.map { Int($0)! }

        if parts.count == 1 {
            prerelease = nil
        } else {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty,
                  identifiers.allSatisfy({ !$0.isEmpty }) else {
                return nil
            }
            prerelease = identifiers.map { value in
                if value.allSatisfy(\.isNumber), let number = Int(value) {
                    return .numeric(number)
                }
                return .text(String(value).lowercased())
            }
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.core.count, rhs.core.count)
        for index in 0..<count {
            let left = index < lhs.core.count ? lhs.core[index] : 0
            let right = index < rhs.core.count ? rhs.core[index] : 0
            if left != right { return left < right }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (.some(let left), .some(let right)):
            for index in 0..<min(left.count, right.count) {
                if left[index] == right[index] { continue }
                switch (left[index], right[index]) {
                case (.numeric(let a), .numeric(let b)):
                    return a < b
                case (.numeric, .text):
                    return true
                case (.text, .numeric):
                    return false
                case (.text(let a), .text(let b)):
                    return a < b
                }
            }
            return left.count < right.count
        }
    }
}

enum AgentToolReleaseSources {
    static let claudeNativeLatest =
        "https://downloads.claude.ai/claude-code-releases/latest"
    static let codexNativeLatest =
        "https://releases.openai.com/codex/channels/latest"
    static let antigravityManifestBase =
        "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests"
}

enum AgentToolVersionProbeError: Error, Equatable, Sendable {
    case missingMarkers(AgentToolID)
    case malformedField(String)
    case commandFailed(Int32)
}

enum AgentToolVersionProbe {
    static let timeout = Duration.seconds(45)
    static let outputLimit = 256 * 1024

    static func command(for tool: AgentToolID) -> String {
        let definition = AgentToolRegistry.definition(for: tool)
        let packages: (brew: String, node: String) = switch tool {
        case .claude: ("claude-code", "@anthropic-ai/claude-code")
        case .codex: ("codex", "@openai/codex")
        case .antigravity: ("", "")
        }
        let nativeLookup = switch tool {
        case .claude:
            #"curl --connect-timeout 8 --max-time 20 -fsSL "\#(AgentToolReleaseSources.claudeNativeLatest)""#
        case .codex:
            #"curl --connect-timeout 8 --max-time 20 -fsSL "\#(AgentToolReleaseSources.codexNativeLatest)" | sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1"#
        case .antigravity:
            #"platform=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'); arch=$(uname -m 2>/dev/null); case "$arch" in aarch64) arch=arm64 ;; amd64) arch=x86_64 ;; esac; curl --connect-timeout 8 --max-time 20 -fsSL "\#(AgentToolReleaseSources.antigravityManifestBase)/${platform}_${arch}.json" | sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -n 1"#
        }
        let nativeOwnershipCheck = switch tool {
        case .claude:
            #"[ -x "$native_path" ] && [ -d "$HOME/.local/share/claude/versions" ]"#
        case .codex:
            #"[ -x "$native_path" ] && [ -d "$HOME/.codex/packages/standalone" ]"#
        case .antigravity:
            #"[ -x "$native_path" ]"#
        }

        return #"""
        set +e
        extract_version() {
          printf '%s\n' "$1" | grep -Eo 'v?[0-9]+(\.[0-9]+){1,3}(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?' | head -n 1 | sed 's/^v//'
        }
        tool_path=$(command -v \#(definition.executable) 2>/dev/null || :)
        installed=
        latest=
        method=unknown
        channel=
        error=
        native_path="$HOME/.local/bin/\#(definition.executable)"
        if [ -z "$tool_path" ]; then
          error='not installed'
        else
          installed=$(extract_version "$("$tool_path" --version 2>/dev/null | head -n 1)")
          owner_count=0
          owner=
          owner_path=
          if \#(nativeOwnershipCheck); then
            owner_count=$((owner_count + 1)); owner=native; owner_path="$native_path"
          fi
          if [ -n '\#(packages.brew)' ] && command -v brew >/dev/null 2>&1 && brew list --formula --versions \#(packages.brew) >/dev/null 2>&1; then
            owner_count=$((owner_count + 1)); owner=homebrew
            owner_path="$(brew --prefix 2>/dev/null)/bin/\#(definition.executable)"
          fi
          if [ -n '\#(packages.brew)' ] && command -v brew >/dev/null 2>&1 && brew list --cask --versions \#(packages.brew) >/dev/null 2>&1; then
            owner_count=$((owner_count + 1)); owner=homebrew-cask
            owner_path="$(brew --prefix 2>/dev/null)/bin/\#(definition.executable)"
          fi
          if [ -n '\#(packages.node)' ] && command -v npm >/dev/null 2>&1 && npm list -g --depth=0 \#(packages.node) >/dev/null 2>&1; then
            owner_count=$((owner_count + 1)); owner=npm
            owner_path="$(npm prefix -g 2>/dev/null)/bin/\#(definition.executable)"
          fi
          if [ -n '\#(packages.node)' ] && command -v pnpm >/dev/null 2>&1 && pnpm list -g --depth=0 \#(packages.node) >/dev/null 2>&1; then
            owner_count=$((owner_count + 1)); owner=pnpm
            owner_path="$(pnpm bin -g 2>/dev/null)/\#(definition.executable)"
          fi
          if [ -n '\#(packages.node)' ] && command -v bun >/dev/null 2>&1 && bun pm ls -g 2>/dev/null | grep -F '\#(packages.node)' >/dev/null 2>&1; then
            owner_count=$((owner_count + 1)); owner=bun
            owner_path="$(bun pm bin -g 2>/dev/null)/\#(definition.executable)"
          fi
          if [ "$owner_count" -gt 1 ]; then
            method=ambiguous
            error='installation owner is ambiguous'
          elif [ "$owner_count" -eq 1 ]; then
            method=$owner
            if [ -z "$owner_path" ] || [ "$tool_path" != "$owner_path" ]; then
              method=ambiguous
              error='detected owner does not own the selected executable'
            fi
          else
            method=unknown
            error='installation owner is unknown'
          fi

          case "$method" in
            homebrew) latest_raw=$(brew info --formula --json=v2 \#(packages.brew) 2>/dev/null | sed -nE 's/.*"(stable|version)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' | head -n 1) ;;
            homebrew-cask) latest_raw=$(brew info --cask --json=v2 \#(packages.brew) 2>/dev/null | sed -nE 's/.*"(stable|version)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' | head -n 1) ;;
            npm) latest_raw=$(npm view \#(packages.node) version 2>/dev/null | head -n 1) ;;
            pnpm) latest_raw=$(pnpm view \#(packages.node) version 2>/dev/null | head -n 1) ;;
            bun) latest_raw=$(bun pm view \#(packages.node) version 2>/dev/null | head -n 1) ;;
            native) latest_raw=$(\#(nativeLookup)) ;;
            *) latest_raw= ;;
          esac
          latest=$(extract_version "${latest_raw:-}")
          if [ -n "$latest" ]; then
            channel=latest
          elif [ -z "$error" ]; then
            error='latest lookup failed'
          fi
          if [ -z "$installed" ] && [ -z "$error" ]; then
            error='installed version unreadable'
          fi
        fi
        printf '%s\n' 'MSAM_TOOL_BEGIN:\#(tool.rawValue)'
        printf 'installed=%s\n' "$installed"
        printf 'latest=%s\n' "$latest"
        printf 'method=%s\n' "$method"
        printf 'channel=%s\n' "$channel"
        printf 'path=%s\n' "$tool_path"
        printf 'error=%s\n' "$error"
        printf '%s\n' 'MSAM_TOOL_END:\#(tool.rawValue)'
        """#
    }

    static func parse(_ output: String, tool: AgentToolID) throws -> AgentToolVersion {
        let begin = "MSAM_TOOL_BEGIN:\(tool.rawValue)"
        let end = "MSAM_TOOL_END:\(tool.rawValue)"
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard let beginIndex = lines.firstIndex(of: begin),
              let endIndex = lines[(beginIndex + 1)...].firstIndex(of: end),
              beginIndex < endIndex else {
            throw AgentToolVersionProbeError.missingMarkers(tool)
        }

        let allowed = Set(["installed", "latest", "method", "channel", "path", "error"])
        var fields: [String: String] = [:]
        for line in lines[(beginIndex + 1)..<endIndex] {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw AgentToolVersionProbeError.malformedField(line) }
            let key = String(parts[0])
            guard allowed.contains(key), fields[key] == nil else {
                throw AgentToolVersionProbeError.malformedField(key)
            }
            fields[key] = String(parts[1])
        }

        guard let methodValue = fields["method"] else {
            throw AgentToolVersionProbeError.malformedField("method")
        }
        let installed = try parsedVersion(fields["installed"], field: "installed")
        let latest = try parsedVersion(fields["latest"], field: "latest")
        return AgentToolVersion(
            tool: tool,
            installed: installed,
            latest: latest,
            channel: nonEmpty(fields["channel"]),
            method: AgentInstallMethod.parse(methodValue),
            executablePath: nonEmpty(fields["path"]),
            error: nonEmpty(fields["error"])
        )
    }

    static func fetch(_ tool: AgentToolID, using service: SSHService) async throws -> AgentToolVersion {
        let result = try await service.run(
            command(for: tool),
            timeout: timeout,
            outputLimit: outputLimit
        )
        guard result.exitStatus == 0 else {
            throw AgentToolVersionProbeError.commandFailed(result.exitStatus)
        }
        return try parse(result.stdoutString, tool: tool)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func parsedVersion(_ value: String?, field: String) throws -> String? {
        guard let value = nonEmpty(value) else { return nil }
        guard AgentVersionParser.version(in: value) == value else {
            throw AgentToolVersionProbeError.malformedField(field)
        }
        return value
    }
}
