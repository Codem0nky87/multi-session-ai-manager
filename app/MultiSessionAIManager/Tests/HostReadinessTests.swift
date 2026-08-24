import Foundation
import Testing
@testable import MultiSessionAIManager

/// Reachability outcomes must map to something the user can act on. These are
/// deliberately transport-agnostic now: how the iPad reaches a host (WARP,
/// Tailscale, a VPN, plain LAN) is the user's own infrastructure, so no message
/// may name one.
@Suite struct HostReadinessTests {

    @Test func aReachableOrCancelledCheckIsNotAnIssue() {
        #expect(HostReadiness.issue(for: .reachable) == nil)
        #expect(HostReadiness.issue(for: .cancelled) == nil)
    }

    @Test func eachFailureMapsToADistinctActionableIssue() {
        #expect(HostReadiness.issue(for: .dnsFailure) == .routeUnavailable)
        #expect(HostReadiness.issue(for: .failed) == .routeUnavailable)
        #expect(HostReadiness.issue(for: .networkUnavailable) == .networkUnavailable)
        #expect(HostReadiness.issue(for: .refused) == .sshPortRefused)
        #expect(HostReadiness.issue(for: .timedOut) == .reachabilityTimedOut)
    }

    @Test func everyIssueHasATitleMessageAndAction() {
        let issues: [HostReadinessIssue] = [
            .routeUnavailable, .networkUnavailable, .sshPortRefused,
            .reachabilityTimedOut, .sshAuthenticationRequired, .herdrConfigurationMissing
        ]
        for issue in issues {
            #expect(!issue.title.isEmpty)
            #expect(!issue.message.isEmpty)
            #expect(issue.action?.isEmpty == false)
        }
    }

    @Test func noMessageNamesAParticularVPNVendor() {
        // The app used to hard-code Cloudflare One / WARP into its guidance.
        // Reaching the host is the user's own setup, whatever they chose.
        let issues: [HostReadinessIssue] = [
            .routeUnavailable, .networkUnavailable, .sshPortRefused,
            .reachabilityTimedOut, .sshAuthenticationRequired, .herdrConfigurationMissing
        ]
        for issue in issues {
            let text = (issue.title + issue.message + (issue.action ?? "")).lowercased()
            #expect(!text.contains("cloudflare"))
            #expect(!text.contains("warp"))
            #expect(!text.contains("tailscale"))
        }
    }
}
