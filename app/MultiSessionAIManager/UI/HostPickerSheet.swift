import SwiftUI

/// Behind the tab strip's `+`: pick a configured host and, optionally, name the
/// remote Herdr session to attach to. An empty name means Herdr's default session.
struct HostPickerSheet: View {
    let hosts: [Host]
    let onSelect: (UUID, String?) -> Void

    @State private var sessionName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Session name (optional)") {
                    TextField("default", text: $sessionName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("host.picker.session")
                }
                Section("Host") {
                    if hosts.isEmpty {
                        Text("No hosts configured. Add one in MSAM Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("host.picker.empty")
                    }
                    ForEach(hosts) { host in
                        Button {
                            onSelect(host.id, sessionName)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(host.name)
                                Text("\(host.username)@\(host.address):\(host.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: HerdrChromeMetrics.minimumHitTarget, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("host.picker.host.\(host.id.uuidString)")
                    }
                }
            }
            .navigationTitle("Open Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
