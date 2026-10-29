import Foundation

public struct AppRuntimeContext: Equatable, Sendable {
    public let hostTabs: [String]
    public let selectedHostTab: String?
    public let activeHostName: String?
    public let currentDirectory: String?

    public init(
        hostTabs: [String] = [],
        selectedHostTab: String? = nil,
        activeHostName: String? = nil,
        currentDirectory: String? = nil
    ) {
        self.hostTabs = hostTabs
        self.selectedHostTab = selectedHostTab
        self.activeHostName = activeHostName
        self.currentDirectory = currentDirectory
    }

    public var promptContext: String {
        var lines: [String] = [
            "You are the Apple Intelligence assistant for Multi-Session AI Manager.",
            "You can assist with terminal tasks and control app windows/tabs.",
            "When the user requests an action on windows, panes, or tabs, provide a natural language explanation and append a structured action block:",
            "```action",
            "{\"type\": \"split_pane\", \"direction\": \"down\"|\"right\", \"staged_command\": \"optional command\"}",
            "{\"type\": \"close_pane\"}",
            "{\"type\": \"zoom_pane\"}",
            "{\"type\": \"create_herdr_tab\", \"label\": \"name\", \"staged_command\": \"optional command\"}",
            "{\"type\": \"switch_host_tab\", \"target\": \"HostName\"}",
            "```",
            "",
            "Current App Runtime State:"
        ]

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
