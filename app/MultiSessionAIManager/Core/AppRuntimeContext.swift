import Foundation

public struct AppRuntimeContext: Equatable, Sendable {
    public let availableHosts: [String]
    public let hostTabs: [String]
    public let selectedHostTab: String?
    public let activeHostName: String?
    public let currentDirectory: String?

    public init(
        availableHosts: [String] = [],
        hostTabs: [String] = [],
        selectedHostTab: String? = nil,
        activeHostName: String? = nil,
        currentDirectory: String? = nil
    ) {
        self.availableHosts = availableHosts
        self.hostTabs = hostTabs
        self.selectedHostTab = selectedHostTab
        self.activeHostName = activeHostName
        self.currentDirectory = currentDirectory
    }

    public var promptContext: String {
        var lines: [String] = [
            "You are the Apple Intelligence assistant for Multi-Session AI Manager.",
            "You can assist with terminal tasks, run Herdr commands, and control app windows/tabs.",
            "Hosts in Multi-Session AI Manager are saved remote SSH servers (not external websites).",
            "Herdr is the terminal workspace multiplexer on these hosts. To check or list Herdr tabs/panes, use commands like `herdr tab list` or `herdr workspace list`.",
            "When the user requests an action on windows, panes, or tabs, provide a natural language explanation and append a structured action block:",
            "```action",
            "{\"type\": \"split_pane\", \"direction\": \"down\"|\"right\", \"staged_command\": \"optional command\"}",
            "{\"type\": \"close_pane\"}",
            "{\"type\": \"zoom_pane\"}",
            "{\"type\": \"create_herdr_tab\", \"label\": \"name\", \"staged_command\": \"optional command\"}",
            "{\"type\": \"switch_host_tab\", \"target\": \"HostName\"}",
            "{\"type\": \"open_host_tab\", \"host\": \"HostName\"}",
            "```",
            "",
            "Current App Runtime State:"
        ]

        if !availableHosts.isEmpty {
            lines.append("- Saved SSH Hosts: [\(availableHosts.joined(separator: ", "))]")
        }
        if !hostTabs.isEmpty {
            let tabsList = hostTabs.map { $0 == selectedHostTab ? "\($0) (active)" : $0 }.joined(separator: ", ")
            lines.append("- Open Host Tabs: [\(tabsList)]")
        }
        if let activeHostName, !activeHostName.isEmpty {
            lines.append("- Active Host: \(activeHostName)")
        }
        if let currentDirectory, !currentDirectory.isEmpty {
            lines.append("- Working Directory: \(currentDirectory)")
        }

        return lines.joined(separator: "\n")
    }
}
