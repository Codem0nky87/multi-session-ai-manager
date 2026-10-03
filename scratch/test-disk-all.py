import sys, os, subprocess, json

def get_disk_metrics():
    metrics = {
        "usagePercent": 0.0,
        "totalGB": 0.0,
        "usedGB": 0.0,
        "volumes": []
    }
    
    try:
        import shutil
        usage = shutil.disk_usage("/") if sys.platform != "win32" else shutil.disk_usage("C:\\")
        metrics["totalGB"] = usage.total / (1024**3)
        metrics["usedGB"] = usage.used / (1024**3)
        metrics["usagePercent"] = (usage.used / usage.total) * 100.0 if usage.total > 0 else 0.0
    except Exception as e:
        print("shutil error", e)
        pass
        
    try:
        if sys.platform == "win32":
            # Just test PowerShell output
            print("Windows not tested here")
        else:
            df_out = subprocess.check_output(['df', '-k']).decode('utf-8')
            for line in df_out.split('\n')[1:]:
                parts = line.split()
                if len(parts) >= 9 and parts[0].startswith('/dev/'):
                    fs = parts[0]
                    total_kb = int(parts[1])
                    used_kb = int(parts[2])
                    mount_point = " ".join(parts[8:])
                    name = os.path.basename(mount_point) if mount_point != '/' else 'Root'
                    
                    if total_kb > 0:
                        metrics["volumes"].append({
                            "id": fs,
                            "name": name,
                            "mountPoint": mount_point,
                            "totalGB": total_kb / (1024**2),
                            "usedGB": used_kb / (1024**2)
                        })
    except Exception as e:
        print("df error", e)
        pass
        
    return metrics

print(json.dumps(get_disk_metrics(), indent=2))
