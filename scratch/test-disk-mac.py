import json, subprocess, os

def get_mac_disks():
    disks = {}
    
    # Run df -k to get mount points and usage
    try:
        df_out = subprocess.check_output(['df', '-k']).decode('utf-8')
        for line in df_out.split('\n')[1:]:
            parts = line.split()
            if len(parts) >= 9 and parts[0].startswith('/dev/'):
                fs = parts[0]
                total_kb = int(parts[1])
                used_kb = int(parts[2])
                mount_point = " ".join(parts[8:])
                
                # Get volume name by splitting fs or just using mount point name
                name = os.path.basename(mount_point) if mount_point != '/' else 'Macintosh HD'
                
                # physical disk name is just the base, e.g. /dev/disk3s1 -> disk3
                disk_id = fs.split('/')[2].split('s')[0]
                
                if disk_id not in disks:
                    disks[disk_id] = {
                        "id": disk_id,
                        "model": "Apple APFS Container" if disk_id != "disk0" else "Apple SSD",
                        "volumes": []
                    }
                    
                disks[disk_id]["volumes"].append({
                    "id": fs,
                    "name": name,
                    "mountPoint": mount_point,
                    "totalGB": total_kb / (1024**2),
                    "usedGB": used_kb / (1024**2)
                })
    except Exception as e:
        print(e)
        
    return list(disks.values())

print(json.dumps(get_mac_disks(), indent=2))
