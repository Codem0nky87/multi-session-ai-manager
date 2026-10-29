import Foundation

public enum SplitDirection: String, Codable, Sendable {
    case right
    case down
}

public enum AppSheetType: String, Codable, Sendable {
    case metrics
    case pulse
    case settings
}

public enum AppAction: Equatable, Sendable {
    case splitPane(direction: SplitDirection, stagedCommand: String?)
    case closePane
    case zoomPane
    case createHerdrTab(label: String, stagedCommand: String?)
    case switchHostTab(name: String)
    case openHostTab(hostName: String)
    case openAppSheet(sheet: AppSheetType)
}
