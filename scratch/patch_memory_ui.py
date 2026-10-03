import sys

with open('app/MultiSessionAIManager/UI/Metrics/MemoryMetricsDetailView.swift', 'r') as f:
    code = f.read()

# Replace the HStack(spacing: 32) block with just the centered CircularGaugeView
old_gauges = '''            HStack(spacing: 32) {
                // Real pressure gauge
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
                }
                
                CircularGaugeView(value: metrics.usagePercent, max: 100, title: "\\(Int(metrics.usagePercent))%", color: .blue)
                    .scaleEffect(1.2)
            }
            .padding(.bottom, 16)'''

new_gauges = '''            HStack(spacing: 24) {
                CircularGaugeView(value: metrics.usagePercent, max: 100, title: "\\(Int(metrics.usagePercent))%", color: .blue)
                    .scaleEffect(1.2)
            }
            .padding(.bottom, 16)'''

code = code.replace(old_gauges, new_gauges)

# Replace the GeometryReader for the bar chart
old_bar = '''                GeometryReader { geo in
                    HStack(spacing: 0) {
                        let totalShown = metrics.app + metrics.wired + metrics.compressed > 0 ? (metrics.app + metrics.wired + metrics.compressed) : metrics.used
                        let usedRatio = totalShown > 0 ? metrics.used / totalShown : 1.0
                        
                        if metrics.app > 0 || metrics.wired > 0 || metrics.compressed > 0 {
                            Rectangle().fill(.blue).frame(width: geo.size.width * (metrics.app / totalShown) * (metrics.used / metrics.total))
                            Rectangle().fill(.orange).frame(width: geo.size.width * (metrics.wired / totalShown) * (metrics.used / metrics.total))
                            Rectangle().fill(.red).frame(width: geo.size.width * (metrics.compressed / totalShown) * (metrics.used / metrics.total))
                        } else {
                            Rectangle().fill(.blue).frame(width: geo.size.width * (metrics.used / (metrics.total > 0 ? metrics.total : 1)))
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                }

                .frame(height: 8)'''

new_bar = '''                GeometryReader { geo in
                    let safeTotal = metrics.total > 0 ? metrics.total : 1
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(HerdrTheme.panel)
                            
                        HStack(spacing: 0) {
                            if metrics.app > 0 || metrics.wired > 0 || metrics.compressed > 0 {
                                Rectangle().fill(.blue).frame(width: geo.size.width * (metrics.app / safeTotal))
                                Rectangle().fill(.orange).frame(width: geo.size.width * (metrics.wired / safeTotal))
                                Rectangle().fill(.red).frame(width: geo.size.width * (metrics.compressed / safeTotal))
                            } else {
                                Rectangle().fill(.blue).frame(width: geo.size.width * (metrics.used / safeTotal))
                            }
                        }
                        .frame(height: 8)
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 8)'''

code = code.replace(old_bar, new_bar)

with open('app/MultiSessionAIManager/UI/Metrics/MemoryMetricsDetailView.swift', 'w') as f:
    f.write(code)

