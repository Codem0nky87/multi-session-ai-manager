import sys

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'r') as f:
    code = f.read()

code = code.replace("disk_id = fs.split('/')[2].split('s')[0]", "import re; disk_id = re.match(r'/dev/(disk\\\\d+)', fs).group(1) if re.match(r'/dev/(disk\\\\d+)', fs) else fs")

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'w') as f:
    f.write(code)

