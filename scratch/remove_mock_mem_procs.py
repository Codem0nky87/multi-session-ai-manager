import sys

with open('app/MultiSessionAIManager/UI/Metrics/MemoryMetricsDetailView.swift', 'r') as f:
    code = f.read()

start_idx = code.find('Divider().background(HerdrTheme.selection)')
# Find the second instance of Divider()
start_idx = code.find('Divider().background(HerdrTheme.selection)', start_idx + 1)

end_idx = code.find('        .padding()', start_idx)

if start_idx != -1 and end_idx != -1:
    code = code[:start_idx] + code[end_idx:]

with open('app/MultiSessionAIManager/UI/Metrics/MemoryMetricsDetailView.swift', 'w') as f:
    f.write(code)

