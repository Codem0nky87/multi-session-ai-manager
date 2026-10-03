import sys, re

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'r') as f:
    code = f.read()

new_code = '''
                # Filter out macOS technical APFS volumes to keep it simple and clean
                if sys.platform == "darwin":
                    if mount_point in ['/System/Volumes/VM', '/System/Volumes/Preboot', '/System/Volumes/Update', 
                                       '/System/Volumes/xarts', '/System/Volumes/iSCPreboot', '/System/Volumes/Hardware',
                                       '/Volumes/Recovery']:
                        continue
                    if "cryptexd" in mount_point or "CoreSimulator" in mount_point:
                        continue
                    if name == "Data" and mount_point == "/System/Volumes/Data":
                        continue # Hide Data volume to keep UI simple
                    if name == "Root":
                        name = "Macintosh HD"
                        try:
                            import shutil
                            usage = shutil.disk_usage("/")
                            used_kb = usage.used / 1024
                            total_kb = usage.total / 1024
                        except:
                            pass
'''

code = re.sub(r'# Filter out macOS technical APFS volumes to keep it simple and clean.*?if name == "Root":.*?name = "Macintosh HD"', new_code.strip(), code, flags=re.DOTALL)

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'w') as f:
    f.write(code)

