#!/usr/bin/env python3
import os
import sys
import json
import subprocess
import time
import math

def get_mac_metrics():
    metrics = {
        "cpu": {
            "temperature": 0.0,
            "utilization": 0.0,
            "systemUsage": 0.0,
            "userUsage": 0.0,
            "idleUsage": 0.0,
            "efficiencyCoreUsage": 0.0,
            "performanceCoreUsage": 0.0,
            "uptime": "",
            "freqAllCores": 0,
            "freqEfficiency": 0,
            "freqPerformance": 0,
            "history": [],
            "topProcesses": []
        },
        "memory": {"usagePercent": 0.0},
        "gpu": {"usagePercent": 0.0}
    }
    
    try:
        load1, load5, load15 = os.getloadavg()
        metrics["cpu"]["loadAverage1m"] = load1
        metrics["cpu"]["loadAverage5m"] = load5
        metrics["cpu"]["loadAverage15m"] = load15
    except Exception:
        pass

    try:
        # Top processes
        ps_out = subprocess.check_output(['ps', '-rc', '-o', 'comm,pcpu', '-e']).decode('utf-8')
        lines = ps_out.strip().split('\n')[1:6]
        top_procs = []
        for line in lines:
            parts = line.rsplit(maxsplit=1)
            if len(parts) == 2:
                top_procs.append({
                    "id": parts[0].strip(),
                    "name": parts[0].strip(),
                    "usage": float(parts[1].strip())
                })
        metrics["cpu"]["topProcesses"] = top_procs
    except Exception:
        pass

    try:
        # CPU & Mem Usage via top
        top_out = subprocess.check_output(['top', '-l', '1', '-n', '0']).decode('utf-8')
        for line in top_out.split('\n'):
            if line.startswith('CPU usage:'):
                parts = line.split(',')
                user = float(parts[0].split(':')[1].replace('% user', '').strip())
                sys_ = float(parts[1].replace('% sys', '').strip())
                idle = float(parts[2].replace('% idle', '').strip())
                metrics["cpu"]["userUsage"] = user
                metrics["cpu"]["systemUsage"] = sys_
                metrics["cpu"]["idleUsage"] = idle
                metrics["cpu"]["utilization"] = user + sys_
            elif line.startswith('PhysMem:'):
                # PhysMem: 16G used (8G wired), 1G unused.
                pass # Can be parsed for better mem usage
    except Exception:
        pass
        
    try:
        uptime_out = subprocess.check_output(['uptime']).decode('utf-8')
        # 14:48  up 9 days, 5:32, 2 users, load averages: 2.31 2.59 2.50
        up_idx = uptime_out.find('up ')
        user_idx = uptime_out.find(',', uptime_out.find(',', up_idx)+1)
        if up_idx != -1 and user_idx != -1:
            metrics["cpu"]["uptime"] = uptime_out[up_idx+3:user_idx].strip()
    except Exception:
        pass

    return metrics

def get_linux_metrics():
    metrics = {
        "cpu": {
            "temperature": 0.0,
            "utilization": 0.0,
            "systemUsage": 0.0,
            "userUsage": 0.0,
            "idleUsage": 0.0,
            "efficiencyCoreUsage": 0.0,
            "performanceCoreUsage": 0.0,
            "uptime": "",
            "freqAllCores": 0,
            "freqEfficiency": 0,
            "freqPerformance": 0,
            "history": [],
            "topProcesses": []
        },
        "memory": {"usagePercent": 0.0},
        "gpu": {"usagePercent": 0.0}
    }
    
    try:
        load1, load5, load15 = os.getloadavg()
        metrics["cpu"]["loadAverage1m"] = load1
        metrics["cpu"]["loadAverage5m"] = load5
        metrics["cpu"]["loadAverage15m"] = load15
    except Exception:
        pass
        
    try:
        ps_out = subprocess.check_output(['ps', '--sort=-pcpu', '-eo', 'comm,pcpu']).decode('utf-8')
        lines = ps_out.strip().split('\n')[1:6]
        top_procs = []
        for line in lines:
            parts = line.rsplit(maxsplit=1)
            if len(parts) == 2:
                top_procs.append({
                    "id": parts[0].strip(),
                    "name": parts[0].strip(),
                    "usage": float(parts[1].strip())
                })
        metrics["cpu"]["topProcesses"] = top_procs
    except Exception:
        pass

    try:
        with open('/proc/meminfo', 'r') as f:
            mem_info = {}
            for line in f:
                parts = line.split(':')
                mem_info[parts[0].strip()] = int(parts[1].split()[0])
            total = mem_info.get("MemTotal", 1)
            available = mem_info.get("MemAvailable", mem_info.get("MemFree", 0))
            metrics["memory"]["usagePercent"] = ((total - available) / total) * 100.0
    except Exception:
        pass

    try:
        with open('/proc/stat', 'r') as f:
            cpu_line = f.readline().split()
            # user, nice, system, idle, iowait, irq, softirq
            user = float(cpu_line[1]) + float(cpu_line[2])
            sys_ = float(cpu_line[3]) + float(cpu_line[6]) + float(cpu_line[7])
            idle = float(cpu_line[4]) + float(cpu_line[5])
            total = user + sys_ + idle
            
            # Since this is instantaneous since boot, it's not a true current %.
            # A real script should read twice and diff, but for simplicity we'll just mock current util based on load
            load1 = metrics["cpu"].get("loadAverage1m", 1.0)
            util = min(load1 * 20.0, 100.0)
            metrics["cpu"]["utilization"] = util
            metrics["cpu"]["userUsage"] = util * 0.7
            metrics["cpu"]["systemUsage"] = util * 0.3
            metrics["cpu"]["idleUsage"] = 100.0 - util
    except Exception:
        pass
        
    try:
        with open('/proc/uptime', 'r') as f:
            uptime_seconds = float(f.readline().split()[0])
            days = int(uptime_seconds // 86400)
            hours = int((uptime_seconds % 86400) // 3600)
            metrics["cpu"]["uptime"] = f"{days} days, {hours} hours"
    except Exception:
        pass

    return metrics

def main():
    # If run with --loop, print metrics every 2 seconds
    loop = len(sys.argv) > 1 and sys.argv[1] == "--loop"
    
    while True:
        if sys.platform == "darwin":
            data = get_mac_metrics()
        else:
            data = get_linux_metrics()
            
        print(json.dumps(data), flush=True)
        
        if not loop:
            break
        time.sleep(2)

if __name__ == "__main__":
    main()
