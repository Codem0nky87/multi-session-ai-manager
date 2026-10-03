import sys

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'r') as f:
    code = f.read()

disk_functions = '''
def get_windows_disks():
    metrics = {
        "usagePercent": 0.0,
        "totalGB": 0.0,
        "usedGB": 0.0,
        "disks": []
    }
    try:
        ps_script = """
        $volumes = Get-Volume | Where-Object DriveType -eq 'Fixed' | Select-Object DriveLetter,FileSystemLabel,Size,SizeRemaining
        $result = @()
        foreach ($vol in $volumes) {
            $result += [PSCustomObject]@{
                id = if ($vol.DriveLetter) { $vol.DriveLetter + ':' } else { 'Vol' }
                name = $vol.FileSystemLabel
                mountPoint = if ($vol.DriveLetter) { $vol.DriveLetter + ':\\' } else { '' }
                totalGB = $vol.Size / 1GB
                usedGB = ($vol.Size - $vol.SizeRemaining) / 1GB
            }
        }
        $result | ConvertTo-Json
        """
        import subprocess, json
        out = subprocess.check_output(["powershell", "-NoProfile", "-Command", ps_script]).decode('utf-8')
        vols = json.loads(out)
        if isinstance(vols, dict):
            vols = [vols]
            
        disk_obj = {
            "id": "disk0",
            "model": "Windows Disks",
            "volumes": []
        }
        
        total_size = 0.0
        total_used = 0.0
        
        for v in vols:
            disk_obj["volumes"].append({
                "id": v.get("id", ""),
                "name": v.get("name", "") if v.get("name") else "Local Disk",
                "mountPoint": v.get("mountPoint", ""),
                "totalGB": v.get("totalGB", 0.0),
                "usedGB": v.get("usedGB", 0.0)
            })
            total_size += v.get("totalGB", 0.0)
            total_used += v.get("usedGB", 0.0)
            
        metrics["disks"] = [disk_obj]
        metrics["totalGB"] = total_size
        metrics["usedGB"] = total_used
        metrics["usagePercent"] = (total_used / total_size * 100.0) if total_size > 0 else 0.0
    except Exception:
        pass
    return metrics

def get_unix_disks():
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
            if len(parts) >= 9 and parts[0].startswith('/dev/'):
                fs = parts[0]
                total_kb = int(parts[1])
                used_kb = int(parts[2])
                mount_point = " ".join(parts[8:])
                name = os.path.basename(mount_point) if mount_point != '/' else 'Root'
                
                if sys.platform == "darwin":
                    disk_id = fs.split('/')[2].split('s')[0]
                    model = "Apple APFS Container" if disk_id != "disk0" else "Apple SSD"
                else:
                    import re
                    m = re.match(r'/dev/([a-zA-Z]+)\\d*', fs)
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
        
        # Filter out disks with 0 volumes
        valid_disks = [d for d in disks.values() if len(d["volumes"]) > 0]
        metrics["disks"] = valid_disks
    except Exception as e:
        pass
        
    return metrics
'''

if 'def get_windows_disks' not in code:
    code = code.replace('def get_mac_metrics():', disk_functions + '\ndef get_mac_metrics():')

code = code.replace('        "gpu": {', '        "disk": get_unix_disks(),\n        "gpu": {', 1)
code = code.replace('        "gpu": {', '        "disk": get_unix_disks(),\n        "gpu": {')

old_main = '''        if sys.platform == "darwin":
            data = get_mac_metrics()
        else:
            data = get_linux_metrics()'''
new_main = '''        if sys.platform == "darwin":
            data = get_mac_metrics()
        elif sys.platform == "win32":
            # For Windows, we might need a separate function, but for now we'll just mock CPU/RAM
            data = {
                "cpu": {"temperature": 0.0, "utilization": 0.0, "systemUsage": 0.0, "userUsage": 0.0, "idleUsage": 100.0, "efficiencyCoreUsage": 0.0, "performanceCoreUsage": 0.0, "uptime": "", "freqAllCores": 0, "freqEfficiency": 0, "freqPerformance": 0, "history": [], "topProcesses": [], "loadAverage1m": 0.0, "loadAverage5m": 0.0, "loadAverage15m": 0.0},
                "memory": {"usagePercent": 0.0},
                "gpu": {"usagePercent": 0.0, "modelName": "", "cores": 0, "temperature": 0.0, "memoryUsed": 0.0, "memoryTotal": 0.0},
                "disk": get_windows_disks()
            }
        else:
            data = get_linux_metrics()'''

if 'elif sys.platform == "win32":' not in code:
    code = code.replace(old_main, new_main)

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'w') as f:
    f.write(code)

