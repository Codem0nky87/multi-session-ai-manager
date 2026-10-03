import sys, subprocess, os, re, json

def get_unix_disks():
    metrics = {
        "usagePercent": 0.0,
        "totalGB": 0.0,
        "usedGB": 0.0,
        "disks": []
    }
    
    try:
        df_out = subprocess.check_output(['df', '-k']).decode('utf-8')
        disks = {}
        for line in df_out.split('\n')[1:]:
            parts = line.split()
            if len(parts) >= 9 and parts[0].startswith('/dev/'):
                fs = parts[0]
                total_kb = int(parts[1])
                used_kb = int(parts[2])
                mount_point = " ".join(parts[8:])
                name = os.path.basename(mount_point) if mount_point != '/' else 'Root'
                
                m = re.match(r'/dev/([a-zA-Z]+)\d*', fs)
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
        print("df error", e)
        
    return metrics

print(json.dumps(get_unix_disks(), indent=2))
