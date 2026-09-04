import Foundation

enum AgentToolID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case antigravity
}

enum AgentInstallMethod: String, Codable, Sendable {
    case homebrew
    case npm
    case pnpm
    case bun
    case native
    case unknown
    case ambiguous

    static func parse(_ value: String) -> Self {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "brew", "homebrew": .homebrew
        case "npm": .npm
        case "pnpm": .pnpm
        case "bun": .bun
        case "native", "standalone": .native
        case "ambiguous": .ambiguous
        default: .unknown
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

struct AgentToolDefinition: Equatable, Sendable {
    let id: AgentToolID
    let displayName: String
    let executable: String
    let herdrKinds: Set<String>
    let exitCommand: String
    let resumeArguments: @Sendable (String) -> [String]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.executable == rhs.executable
            && lhs.herdrKinds == rhs.herdrKinds
            && lhs.exitCommand == rhs.exitCommand
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
            resumeArguments: { ["--resume", $0] }
        ),
        AgentToolDefinition(
            id: .codex,
            displayName: "Codex",
            executable: "codex",
            herdrKinds: ["codex"],
            exitCommand: "/exit",
            resumeArguments: { ["resume", $0] }
        ),
        AgentToolDefinition(
            id: .antigravity,
            displayName: "Antigravity",
            executable: "agy",
            herdrKinds: ["agy", "antigravity-cli"],
            exitCommand: "/exit",
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
