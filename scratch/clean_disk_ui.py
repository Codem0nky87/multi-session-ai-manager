import sys, re

with open('app/MultiSessionAIManager/UI/Metrics/DiskMetricsDetailView.swift', 'r') as f:
    code = f.read()

# Remove the mountPoint text block
code = re.sub(r'\s*if !volume\.mountPoint\.isEmpty \{.*?\}', '', code, flags=re.DOTALL)

with open('app/MultiSessionAIManager/UI/Metrics/DiskMetricsDetailView.swift', 'w') as f:
    f.write(code)

