import sys

with open('app/MultiSessionAIManager/UI/Metrics/GPUMetricsDetailView.swift', 'r') as f:
    code = f.read()

old_gauges = '''            HStack(spacing: 24) {
                CircularGaugeView(value: metrics.usagePercent, max: 100, title: "\\(Int(metrics.usagePercent))%", color: .blue)
                    .scaleEffect(1.2)
            }'''

new_gauges = '''            HStack(spacing: 24) {
                if metrics.temperature > 0 {
                    CircularGaugeView(value: metrics.temperature, max: 100, title: "\\(Int(metrics.temperature))°C", color: .blue)
                }
                
                CircularGaugeView(value: metrics.usagePercent, max: 100, title: "\\(Int(metrics.usagePercent))%", color: .blue)
                    .scaleEffect(1.2)
                    
                if metrics.memoryTotal > 0 {
                    let memPercent = (metrics.memoryUsed / metrics.memoryTotal) * 100.0
                    CircularGaugeView(value: memPercent, max: 100, title: "\\(Int(memPercent))%", color: .blue)
                }
            }'''

code = code.replace(old_gauges, new_gauges)

# Also add Memory to Details section
old_details = '''                detailRow(label: "Utilization:", value: "\\(Int(metrics.usagePercent))%")
            }'''

new_details = '''                detailRow(label: "Utilization:", value: "\\(Int(metrics.usagePercent))%")
                if metrics.memoryTotal > 0 {
                    detailRow(label: "VRAM Used:", value: String(format: "%.1f / %.1f GB", metrics.memoryUsed / 1024.0, metrics.memoryTotal / 1024.0))
                }
            }'''

code = code.replace(old_details, new_details)

with open('app/MultiSessionAIManager/UI/Metrics/GPUMetricsDetailView.swift', 'w') as f:
    f.write(code)

