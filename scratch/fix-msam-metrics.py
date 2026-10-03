import sys, re

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'r') as f:
    code = f.read()

new_unix_disks = '''def get_unix_disks():
    metrics = {
        "usagePercent": 0.0,
        "totalGB": 0.0,
        "usedGB": 0.0,
        "disks": []
    }
    
    try:
        import shutil
        usage = shutil.disk_usage("/")
        metrics["totalGB"] = usage.total / (1024**3)
        metrics["usedGB"] = usage.used / (1024**3)
        metrics["usagePercent"] = (usage.used / usage.total) * 100.0 if usage.total > 0 else 0.0
    except:
        pass
        
    try:
        import subprocess, os
        df_out = subprocess.check_output(['df', '-k'], stderr=subprocess.DEVNULL).decode('utf-8')
        disks = {}
        for line in df_out.split('\\n')[1:]:
            parts = line.split()
            if len(parts) >= 6 and parts[0].startswith('/dev/'):
                fs = parts[0]
                total_kb = int(parts[1])
                used_kb = int(parts[2])
                
                if sys.platform == "darwin":
                    mount_point = " ".join(parts[8:]) if len(parts) >= 9 else parts[-1]
                else:
                    mount_point = " ".join(parts[5:]) if len(parts) >= 6 else parts[-1]
                    
                name = os.path.basename(mount_point) if mount_point != '/' else 'Root'
                
                # Filter out macOS technical APFS volumes to keep it simple and clean
                if sys.platform == "darwin":
                    if mount_point in ['/System/Volumes/VM', '/System/Volumes/Preboot', '/System/Volumes/Update', 
                                       '/System/Volumes/xarts', '/System/Volumes/iSCPreboot', '/System/Volumes/Hardware',
                                       '/Volumes/Recovery']:
                        continue
                    if "cryptexd" in mount_point or "CoreSimulator" in mount_point:
                        continue
                    if name == "Root":
                        name = "Macintosh HD"
                
                if sys.platform == "darwin":
                    disk_id = fs.split('/')[2].split('s')[0]
                    model = "Apple SSD"
                else:
                    import re
                    m = re.match(r'/dev/(mapper/\\w+|nvme\\dn\\d|[a-zA-Z]+)\\d*', fs)
                    disk_id = m.group(1) if m else fs
                    model = "Linux Disk"
                
                if disk_id not in disks:
                    disks[disk_id] = {
                        "id": disk_id,
                        "model": model,
                        "volumes": []
                    }
                    
                if total_kb > 0 and (not fs.startswith('/dev/loop')):
                    disks[disk_id]["volumes"].append({
                        "id": fs,
                        "name": name,
                        "mountPoint": mount_point,
                        "totalGB": total_kb / (1024**2),
                        "usedGB": used_kb / (1024**2)
                    })
        
        valid_disks = [d for d in disks.values() if len(d["volumes"]) > 0]
        metrics["disks"] = valid_disks
    except Exception as e:
        pass
        
    return metrics'''

code = re.sub(r'def get_unix_disks\(\):.*?return metrics', lambda m: new_unix_disks, code, flags=re.DOTALL)

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'w') as f:
    f.write(code)

