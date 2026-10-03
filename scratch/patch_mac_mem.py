import sys

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'r') as f:
    code = f.read()

mac_logic = """
    try:
        page_size = int(subprocess.check_output(['sysctl', '-n', 'hw.pagesize']).decode('utf-8').strip())
        vm = subprocess.check_output(['vm_stat']).decode('utf-8')
        vm_dict = {}
        for line in vm.split('\\n'):
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
            metrics["memory"]["total"] = total_ram / (1024**3)
            metrics["memory"]["used"] = used_memory / (1024**3)
            metrics["memory"]["app"] = app_memory / (1024**3)
            metrics["memory"]["wired"] = wired_memory / (1024**3)
            metrics["memory"]["compressed"] = compressed_memory / (1024**3)
            metrics["memory"]["free"] = (total_ram - used_memory) / (1024**3)
            
        sys_swap = subprocess.check_output(['sysctl', '-n', 'vm.swapusage']).decode('utf-8').strip()
        # vm.swapusage: total = 2048.00M  used = 1024.00M  free = 1024.00M  (encrypted)
        if "used =" in sys_swap:
            used_str = sys_swap.split("used =")[1].split("M")[0].strip()
            metrics["memory"]["swap"] = float(used_str) / 1024.0
    except Exception:
        pass
"""

# Insert mac_logic before "# Try to read GPU utilization for macOS via powermetrics"
# Or just before the try-catch for Top processes
code = code.replace("    try:\n        # Top processes\n", mac_logic + "\n    try:\n        # Top processes\n", 1)

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'w') as f:
    f.write(code)

