import SwiftUI
import UIKit

/// The expanded part of a volume row in the storage detail: the files that
/// occupy the most space on it, or the scan that is finding them.
struct VolumeLargestFilesView: View {
    let mountPoint: String
    var usage: VolumeUsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().overlay(HerdrTheme.selection)
            switch usage.state(for: mountPoint) {
            case nil:
                // The tap that expanded the row starts the scan a moment later.
                progress("Scanning \(mountPoint)…")
            case .scanning(let since):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    progress("Scanning \(mountPoint)… \(Self.elapsed(from: since, to: context.date))")
                }
                note("Every folder on the volume is read once. A large volume can take a few minutes.")
            case .failed(let reason):
                note(reason, color: .orange)
                action("Try again", symbol: "arrow.clockwise", identifier: "metrics.disk.files.retry")
            case .loaded(let report, let at):
                results(report, at: at)
            }
        }
        .accessibilityIdentifier("metrics.disk.files")
    }

    @ViewBuilder
    private func results(_ report: VolumeUsageReport, at: Date) -> some View {
        Text(VolumeUsageFormat.headline(for: report).uppercased())
            .font(HerdrTheme.mono(.caption2, weight: .semibold))
            .foregroundStyle(HerdrTheme.subtext)
        ForEach(report.files) { file in
            HStack(alignment: .top, spacing: 10) {
                Text(VolumeUsageFormat.size(file.bytes))
                    .font(HerdrTheme.mono(.caption2, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .monospacedDigit()
                    .frame(width: 70, alignment: .trailing)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(HerdrTheme.mono(.caption, weight: .semibold))
                        .foregroundStyle(HerdrTheme.text)
                    Text(file.folder)
                        .font(HerdrTheme.mono(.caption2))
                        .foregroundStyle(HerdrTheme.subtext)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = file.path
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(file.name), \(VolumeUsageFormat.size(file.bytes)), in \(file.folder)")
        }
        ForEach(VolumeUsageFormat.caveats(for: report), id: \.self) { caveat in
            note(caveat, color: .orange)
        }
        HStack {
            note("Scanned \(at.formatted(date: .omitted, time: .shortened)). Hold a file to copy its path.")
            Spacer(minLength: 8)
            action("Rescan", symbol: "arrow.clockwise", identifier: "metrics.disk.files.rescan")
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).tint(HerdrTheme.accent)
            Text(text)
                .font(HerdrTheme.mono(.caption2))
                .foregroundStyle(HerdrTheme.subtext)
                .monospacedDigit()
        }
        .accessibilityIdentifier("metrics.disk.files.scanning")
    }

    private func note(_ text: String, color: Color = HerdrTheme.subtext) -> some View {
        Text(text)
            .font(HerdrTheme.mono(.caption2))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func action(_ title: String, symbol: String, identifier: String) -> some View {
        Button {
            Task { await usage.rescan(mountPoint) }
        } label: {
            Label(title, systemImage: symbol)
                .font(HerdrTheme.mono(.caption2, weight: .semibold))
                .foregroundStyle(HerdrTheme.accent)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    /// "8 s", then "1 min 05 s": a scan is watched for seconds or for minutes.
    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds) s" : String(format: "%d min %02d s", seconds / 60, seconds % 60)
    }
}
