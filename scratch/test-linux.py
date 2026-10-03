import sys
sys.path.append('app/MultiSessionAIManager/Resources')
with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'r') as f:
    code = f.read()
exec(code)
print(json.dumps(get_linux_metrics()))
