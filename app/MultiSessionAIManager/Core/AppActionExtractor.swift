import Foundation

public struct ExtractedActionResult: Equatable, Sendable {
    public let cleanText: String
    public let action: AppAction?

    public init(cleanText: String, action: AppAction?) {
        self.cleanText = cleanText
        self.action = action
    }
}

public enum AppActionExtractor {
    private struct ActionPayload: Decodable {
        let type: String
        let direction: String?
        let target: String?
        let label: String?
        let staged_command: String?
        let sheet: String?
    }

    public static func extract(from text: String) -> ExtractedActionResult {
        let pattern = "```action[ \\t]*\\r?\\n([\\s\\S]*?)\\r?\\n```[ \\t]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ExtractedActionResult(cleanText: text, action: nil)
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

        guard let firstMatch = matches.first else {
            return ExtractedActionResult(cleanText: text, action: nil)
        }

        let jsonRange = firstMatch.range(at: 1)
        let jsonString = nsString.substring(with: jsonRange).trimmingCharacters(in: .whitespacesAndNewlines)

        var parsedAction: AppAction? = nil
        if let data = jsonString.data(using: .utf8),
           let payload = try? JSONDecoder().decode(ActionPayload.self, from: data) {
            switch payload.type {
            case "split_pane":
                let dir = payload.direction?.lowercased() == "right" ? SplitDirection.right : SplitDirection.down
                parsedAction = .splitPane(direction: dir, stagedCommand: payload.staged_command)
            case "close_pane":
                parsedAction = .closePane
            case "zoom_pane":
                parsedAction = .zoomPane
            case "create_herdr_tab":
                parsedAction = .createHerdrTab(label: payload.label ?? payload.target ?? "new-tab", stagedCommand: payload.staged_command)
            case "switch_host_tab":
                if let target = payload.target, !target.isEmpty {
                    parsedAction = .switchHostTab(name: target)
                }
            case "open_host_tab":
                if let target = payload.target, !target.isEmpty {
                    parsedAction = .openHostTab(hostName: target)
                }
            case "open_sheet":
                switch payload.sheet?.lowercased() {
                case "metrics": parsedAction = .openAppSheet(sheet: .metrics)
                case "pulse": parsedAction = .openAppSheet(sheet: .pulse)
                default: parsedAction = .openAppSheet(sheet: .settings)
                }
            default:
                break
            }
        }

        let cleanText = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsString.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ExtractedActionResult(cleanText: cleanText, action: parsedAction)
    }
}
