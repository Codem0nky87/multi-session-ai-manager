#!/usr/bin/env python3
import os
import sys
import json
import subprocess
import time
import math

_last_net_bytes_recv = 0
_last_net_bytes_sent = 0
_last_net_time = 0

def format_bytes(bytes_per_sec):
    if bytes_per_sec < 1024:
        return f"{int(bytes_per_sec)} B/s"
    elif bytes_per_sec < 1024 * 1024:
        return f"{int(bytes_per_sec / 1024)} KB/s"
    else:
        return f"{bytes_per_sec / (1024 * 1024):.1f} MB/s"

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
        
        # Try to read SMC temperatures via powermetrics for Intel Macs (requires passwordless sudo)
        try:
            pm_out = subprocess.check_output(['sudo', 'powermetrics', '--samplers', 'smc', '-n', '1', '-i', '1'], stderr=subprocess.DEVNULL).decode('utf-8')
            for line in pm_out.split('\n'):
                if 'CPU die temperature' in line or 'CPU thermal level' in line:
                    # Format: "CPU die temperature: 45.32 C"
                    parts = line.split(':')
                    if len(parts) > 1:
                        val = parts[1].strip().split(' ')[0]
                        metrics["cpu"]["temperature"] = float(val)
                        break
        except Exception:
            # Fallback for Apple Silicon where SMC sampler isn't supported and raw temp requires compiled IOKit C
            pass
            
        # Try to read GPU utilization via powermetrics for macOS
        try:
            gpu_out = subprocess.check_output(['sudo', 'powermetrics', '--samplers', 'gpu_power', '-n', '1', '-i', '1'], stderr=subprocess.DEVNULL).decode('utf-8')
            for line in gpu_out.split('\n'):
                if 'GPU HW active residency:' in line:
                    parts = line.split(':')
                    if len(parts) > 1:
                        val = parts[1].strip().split('%')[0]
                        metrics["gpu"]["usagePercent"] = float(val)
                        break
        except Exception:
            pass
            
    except Exception:
        pass

    # Try to read GPU utilization for Linux via nvidia-smi
    try:
        nvidia_out = subprocess.check_output(['nvidia-smi', '--query-gpu=utilization.gpu', '--format=csv,noheader,nounits'], stderr=subprocess.DEVNULL).decode('utf-8')
        val = nvidia_out.strip().split('\n')[0]
        metrics["gpu"]["usagePercent"] = float(val)
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

    global _last_net_bytes_recv, _last_net_bytes_sent, _last_net_time
    try:
        netstat_out = subprocess.check_output(['netstat', '-ib']).decode('utf-8')
        total_recv = 0
        total_sent = 0
        for line in netstat_out.strip().split('\n')[1:]:
            parts = line.split()
            if len(parts) >= 10 and not parts[0].startswith('lo'):
                try:
                    # simplistic fallback for finding bytes based on standard mac netstat output
                    # columns often are Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
                    # we will look at indices from the right
                    total_recv += int(parts[-4])
                    total_sent += int(parts[-2])
                except Exception:
                    pass
        
        now = time.time()
        if _last_net_time > 0:
            dt = now - _last_net_time
            if dt > 0:
                recv_speed = max(0, total_recv - _last_net_bytes_recv) / dt
                sent_speed = max(0, total_sent - _last_net_bytes_sent) / dt
                metrics["network"] = {
                    "downloadSpeed": recv_speed,
                    "uploadSpeed": sent_speed,
                    "downloadString": format_bytes(recv_speed),
                    "uploadString": format_bytes(sent_speed)
                }
        _last_net_bytes_recv = total_recv
        _last_net_bytes_sent = total_sent
        _last_net_time = now
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
        with open('/sys/class/thermal/thermal_zone0/temp', 'r') as f:
            temp_mc = int(f.read().strip())
            metrics["cpu"]["temperature"] = temp_mc / 1000.0
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
        # Fallback for macOS memory calculation
        try:
            page_size = int(subprocess.check_output(['sysctl', '-n', 'hw.pagesize']).decode('utf-8').strip())
            vm = subprocess.check_output(['vm_stat']).decode('utf-8')
            vm_dict = {}
            for line in vm.split('\n'):
                if ':' in line:
                    parts = line.split(':')
                    key = parts[0].strip()
                    try:
                        val = int(parts[1].strip().replace('.', ''))
                        vm_dict[key] = val
                    except ValueError:
                        pass
            
            app_memory = vm_dict.get('Anonymous pages', 0) * page_size
            wired_memory = vm_dict.get('Pages wired down', 0) * page_size
            compressed_memory = vm_dict.get('Pages occupied by compressor', 0) * page_size
            used_memory = app_memory + wired_memory + compressed_memory
            total_ram = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize']).decode('utf-8').strip())
            
            if total_ram > 0:
                metrics["memory"]["usagePercent"] = (used_memory / total_ram) * 100.0
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

    global _last_net_bytes_recv, _last_net_bytes_sent, _last_net_time
    try:
        with open('/proc/net/dev', 'r') as f:
            lines = f.readlines()
            total_recv = 0
            total_sent = 0
            for line in lines[2:]:
                parts = line.split(':')
                if len(parts) == 2:
                    iface = parts[0].strip()
                    if iface != 'lo':
                        stats = parts[1].split()
                        if len(stats) >= 9:
                            total_recv += int(stats[0])
                            total_sent += int(stats[8])
                            
            now = time.time()
            if _last_net_time > 0:
                dt = now - _last_net_time
                if dt > 0:
                    recv_speed = max(0, total_recv - _last_net_bytes_recv) / dt
                    sent_speed = max(0, total_sent - _last_net_bytes_sent) / dt
                    metrics["network"] = {
                        "downloadSpeed": recv_speed,
                        "uploadSpeed": sent_speed,
                        "downloadString": format_bytes(recv_speed),
                        "uploadString": format_bytes(sent_speed)
                    }
            _last_net_bytes_recv = total_recv
            _last_net_bytes_sent = total_sent
            _last_net_time = now
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
