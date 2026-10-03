import SwiftUI

struct NetworkMetricsDetailView: View {
    var metrics: NetworkMetrics
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(HerdrTheme.subtext)
                Spacer()
                Text("Network")
                    .font(.headline)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Image(systemName: "command")
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .padding(.bottom, 8)
            
            HStack(spacing: 32) {
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(numberString(metrics.downloadString))
                            .font(.system(size: 32, weight: .regular))
                        Text(unitString(metrics.downloadString))
                            .font(.headline)
                    }
                    HStack {
                        Circle().fill(.blue).frame(width: 10, height: 10)
                        Text("Download")
                            .font(HerdrTheme.mono(.subheadline))
                    }
                }
                
                VStack(spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(numberString(metrics.uploadString))
                            .font(.system(size: 32, weight: .regular))
                        Text(unitString(metrics.uploadString))
                            .font(.headline)
                    }
                    HStack {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("Upload")
                            .font(HerdrTheme.mono(.subheadline))
                    }
                }
            }
            .padding(.bottom, 16)
            
            Divider().background(HerdrTheme.selection)
            Text("INTERFACE")
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
            
            VStack(spacing: 8) {
                detailRow(label: "Total upload:", value: "14.13 TB", color: .red)
                detailRow(label: "Total download:", value: "9.89 TB", color: .blue)
                
                HStack {
                    Text("Status:")
                        .font(HerdrTheme.mono(.subheadline))
                    Spacer()
                    Text("UP")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .cornerRadius(4)
                }
                
                HStack {
                    Text("Internet connection:")
                        .font(HerdrTheme.mono(.subheadline))
                    Spacer()
                    Text("UP")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .foregroundStyle(.white)
                        .cornerRadius(4)
                }
            }
        }
        .padding()
        .frame(width: 320)
        .background(HerdrTheme.background)
    }
    
    private func detailRow(label: String, value: String, color: Color? = nil) -> some View {
        HStack {
            if let c = color {
                RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10)
            }
            Text(label)
                .font(HerdrTheme.mono(.subheadline))
                .foregroundStyle(HerdrTheme.text)
            Spacer()
            Text(value)
                .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                .foregroundStyle(HerdrTheme.text)
        }
    }
    
    private func numberString(_ s: String) -> String {
        s.components(separatedBy: " ").first ?? "0"
    }
    
    private func unitString(_ s: String) -> String {
        let parts = s.components(separatedBy: " ")
        if parts.count > 1 { return parts[1] }
        return "KB/s"
    }
}

