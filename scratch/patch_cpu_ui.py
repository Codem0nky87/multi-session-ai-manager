import sys

with open('app/MultiSessionAIManager/UI/Metrics/CPUMetricsDetailView.swift', 'r') as f:
    code = f.read()

code = code.replace('detailRow(label: "Efficiency cores:", value: "\\(Int(metrics.efficiencyCoreUsage))%", color: .cyan)', 'if metrics.efficiencyCoreUsage > 0 || metrics.performanceCoreUsage > 0 { detailRow(label: "Efficiency cores:", value: "\\(Int(metrics.efficiencyCoreUsage))%", color: .cyan) }')
code = code.replace('detailRow(label: "Performance cores:", value: "\\(Int(metrics.performanceCoreUsage))%", color: .indigo)', 'if metrics.efficiencyCoreUsage > 0 || metrics.performanceCoreUsage > 0 { detailRow(label: "Performance cores:", value: "\\(Int(metrics.performanceCoreUsage))%", color: .indigo) }')

with open('app/MultiSessionAIManager/UI/Metrics/CPUMetricsDetailView.swift', 'w') as f:
    f.write(code)

