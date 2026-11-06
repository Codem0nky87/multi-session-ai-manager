import Foundation

/// Coordinates remote Herdr tab creation, task analysis, and pane command execution for session rollover.
public enum HerdrSessionRollover {
    public struct AnalysisResult: Codable, Equatable, Sendable {
        public let model: String
        public let effort: String
        public let isComplex: Bool?
        public let summary: String?

        enum CodingKeys: String, CodingKey {
            case model
            case effort
            case isComplex = "is_complex"
            case summary
        }

        public init(model: String, effort: String, isComplex: Bool? = nil, summary: String? = nil) {
            self.model = model
            self.effort = effort
            self.isComplex = isComplex
            self.summary = summary
        }
    }

    /// Shell PATH prefix ensuring ~/.local/bin and standard binary locations are reachable.
    public static let pathPrefix = "PATH=\"$HOME/.local/bin:$PATH\"; export PATH"

    /// Command to run the background analyzer script on the host.
    public static func makeAnalysisCommand(transcriptPath: String, provider: String) -> String {
        "\(pathPrefix); python3 \"$HOME/.local/libexec/msam-host-agent/current/msam-host-agent.py\" analyze-task \(POSIXShell.quote(transcriptPath)) \(POSIXShell.quote(provider))"
    }

    /// Extracts and parses the JSON analysis result from stdout.
    public static func parseAnalysisResult(json: String) -> AnalysisResult? {
        guard let start = json.range(of: "{"),
              let end = json.range(of: "}", options: .backwards) else {
            return nil
        }
        let substring = String(json[start.lowerBound..<end.upperBound])
        guard let data = substring.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnalysisResult.self, from: data)
    }

    /// Extract workspace ID from tabID (e.g. "wQ:t1" -> "wQ").
    public static func extractWorkspaceID(from tabID: String) -> String? {
        let trimmed = tabID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let ws = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            return ws.isEmpty ? nil : ws
        }
        return trimmed
    }

    /// Command to create a new tab in Herdr on the host.
    public static func makeCreateTabCommand(workspaceID: String?, cwd: String, label: String) -> String {
        var cmd = "\(pathPrefix); herdr tab create"
        if let ws = workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), !ws.isEmpty {
            cmd += " --workspace \(POSIXShell.quote(ws))"
        }
        let cleanCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanCwd.isEmpty {
            cmd += " --cwd \(POSIXShell.quote(cleanCwd))"
        }
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanLabel.isEmpty {
            cmd += " --label \(POSIXShell.quote(cleanLabel))"
        }
        cmd += " --focus"
        return cmd
    }

    /// Response structure from `herdr tab create`.
    private struct TabCreateResponse: Decodable {
        struct Result: Decodable {
            struct RootPane: Decodable {
                let pane_id: String
                let tab_id: String?
            }
            struct Tab: Decodable {
                let tab_id: String
            }
            let root_pane: RootPane?
            let tab: Tab?
        }
        let result: Result?
    }

    /// Parses the tabID and paneID from `herdr tab create` output JSON.
    public static func parseCreatedTabResult(json: String) -> (tabID: String, paneID: String)? {
        guard let start = json.range(of: "{"),
              let end = json.range(of: "}", options: .backwards) else {
            return nil
        }
        let substring = String(json[start.lowerBound..<end.upperBound])
        guard let data = substring.data(using: .utf8),
              let response = try? JSONDecoder().decode(TabCreateResponse.self, from: data),
              let rootPane = response.result?.root_pane else {
            return nil
        }

        let tabID = response.result?.tab?.tab_id ?? rootPane.tab_id ?? ""
        return (tabID: tabID, paneID: rootPane.pane_id)
    }

    /// Command to run an arbitrary shell command in a specific Herdr pane.
    public static func makeRunCommand(paneID: String, command: String) -> String {
        "\(pathPrefix); herdr pane run \(POSIXShell.quote(paneID)) \(POSIXShell.quote(command))"
    }

    /// Formats the agent launch command with the recommended model, effort, and auto-approval flags.
    public static func makeLaunchCommand(
        provider: String,
        model: String,
        effort: String,
        autoApprove: Bool,
        transcriptPath: String?,
        project: String
    ) -> String {
        let p = provider.lowercased()
        let transcriptArg = transcriptPath.map { " at \($0)" } ?? ""
        let taskPrompt = "Continue previous task from session\(transcriptArg) in \(project). Inspect prior turns and proceed."

        if p.contains("codex") {
            let yoloFlag = autoApprove ? "--yolo " : ""
            return "codex --model \(model) -c model_effort=\(effort) \(yoloFlag)\"\(taskPrompt)\""
        } else if p.contains("claude") {
            let yoloFlag = autoApprove ? "--dangerously-skip-permissions " : ""
            return "claude --model \(model) \(yoloFlag)\"\(taskPrompt)\""
        } else if p.contains("anti") || p.contains("agy") {
            let yoloFlag = autoApprove ? "--yolo " : ""
            return "agy --model \(model) \(yoloFlag)\"\(taskPrompt)\""
        } else if p.contains("hermes") {
            let yoloFlag = autoApprove ? "--yolo " : ""
            return "hermes chat -q \"\(taskPrompt)\" \(yoloFlag)-m \(model)"
        } else {
            return "\(provider) \"\(taskPrompt)\""
        }
    }

    /// Generates a command that opens or focuses the "monitor" Herdr workspace and runs the monitor dashboard.
    public static func makeOpenMonitorWorkspaceCommand() -> String {
        let script = """
        import subprocess, json, os

        home = os.path.expanduser("~")
        local_bin = os.path.join(home, ".local", "bin")
        if local_bin not in os.environ.get("PATH", ""):
            os.environ["PATH"] = local_bin + ":" + os.environ.get("PATH", "")

        # Queries herdr workspace list
        res = subprocess.run(["herdr", "workspace", "list"], capture_output=True, text=True)
        ws_id = None
        try:
            data = json.loads(res.stdout)
            for ws in data.get("result", {}).get("workspaces", []):
                if ws.get("label") == "monitor":
                    ws_id = ws.get("workspace_id")
                    break
        except Exception:
            pass

        pane_id = None
        if ws_id:
            # herdr workspace focus <workspace_id>
            subprocess.run(["herdr", "workspace", "focus", ws_id])
        else:
            # herdr workspace create --label monitor --focus
            c_res = subprocess.run(["herdr", "workspace", "create", "--label", "monitor", "--focus"], capture_output=True, text=True)
            try:
                c_data = json.loads(c_res.stdout)
                pane_id = c_data.get("result", {}).get("root_pane", {}).get("pane_id")
            except Exception:
                pass

        if not pane_id:
            try:
                p_res = subprocess.run(["herdr", "pane", "current"], capture_output=True, text=True)
                p_data = json.loads(p_res.stdout)
                pane_id = p_data.get("result", {}).get("pane", {}).get("pane_id")
            except Exception:
                pass

        # herdr pane run --current "$HOME/.local/bin/msam-host-agent" monitor
        target = pane_id if pane_id else "--current"
        agent_bin = f"{home}/.local/bin/msam-host-agent" if os.path.exists(f"{home}/.local/bin/msam-host-agent") else "$HOME/.local/bin/msam-host-agent"
        subprocess.run(["herdr", "pane", "run", target, agent_bin, "monitor"])
        """
        let encoded = Data(script.utf8).base64EncodedString()
        return "\(pathPrefix); python3 -c \"import base64;exec(base64.b64decode('\(encoded)'))\""
    }
}
