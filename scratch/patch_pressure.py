import sys

with open('app/MultiSessionAIManager/UI/Metrics/MemoryMetricsDetailView.swift', 'r') as f:
    code = f.read()

mock_gauge = """                // Mock pressure gauge
                VStack {
                    ZStack {
                        Circle()
                            .trim(from: 0.5, to: 1.0)
                            .stroke(HerdrTheme.panel, lineWidth: 8)
                        Circle()
                            .trim(from: 0.5, to: 0.8)
                            .stroke(Color.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        Text("Warning")
                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                            .offset(y: 16)
                    }
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(180))
                }"""

real_gauge = """                // Real pressure gauge
                VStack {
                    ZStack {
                        Circle()
                            .trim(from: 0.5, to: 1.0)
                            .stroke(HerdrTheme.panel, lineWidth: 8)
                        Circle()
                            .trim(from: 0.5, to: 0.5 + (metrics.usagePercent / 100.0) * 0.5)
                            .stroke(metrics.usagePercent > 80 ? Color.red : (metrics.usagePercent > 60 ? Color.orange : Color.green), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        
                        Text(metrics.usagePercent > 80 ? "Critical" : (metrics.usagePercent > 60 ? "Warning" : "Normal"))
                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                            .foregroundStyle(metrics.usagePercent > 80 ? Color.red : (metrics.usagePercent > 60 ? Color.orange : Color.green))
                            .rotationEffect(.degrees(180))
                            .offset(y: -16)
                    }
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(180))
                }"""

code = code.replace(mock_gauge, real_gauge)

with open('app/MultiSessionAIManager/UI/Metrics/MemoryMetricsDetailView.swift', 'w') as f:
    f.write(code)

