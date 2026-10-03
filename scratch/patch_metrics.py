import sys

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'r') as f:
    code = f.read()

mem_keys = """        "memory": {
            "usagePercent": 0.0,
            "total": 0.0,
            "used": 0.0,
            "app": 0.0,
            "wired": 0.0,
            "compressed": 0.0,
            "free": 0.0,
            "swap": 0.0
        },"""

code = code.replace('        "memory": {"usagePercent": 0.0},', mem_keys)

mac_mem_logic = """
            if total_ram > 0:
                metrics["memory"]["usagePercent"] = (used_memory / total_ram) * 100.0
                metrics["memory"]["total"] = total_ram / (1024**3)
                metrics["memory"]["used"] = used_memory / (1024**3)
                metrics["memory"]["app"] = app_memory / (1024**3)
                metrics["memory"]["wired"] = wired_memory / (1024**3)
                metrics["memory"]["compressed"] = compressed_memory / (1024**3)
                metrics["memory"]["free"] = (total_ram - used_memory) / (1024**3)
"""
code = code.replace("""
            if total_ram > 0:
                metrics["memory"]["usagePercent"] = (used_memory / total_ram) * 100.0
""", mac_mem_logic)


linux_mem_logic = """
            total = mem_info.get("MemTotal", 1)
            available = mem_info.get("MemAvailable", mem_info.get("MemFree", 0))
            metrics["memory"]["usagePercent"] = ((total - available) / total) * 100.0
            metrics["memory"]["total"] = total / (1024**2)
            metrics["memory"]["used"] = (total - available) / (1024**2)
            metrics["memory"]["free"] = available / (1024**2)
            
            swap_total = mem_info.get("SwapTotal", 0)
            swap_free = mem_info.get("SwapFree", 0)
            metrics["memory"]["swap"] = (swap_total - swap_free) / (1024**2)
"""
code = code.replace("""
            total = mem_info.get("MemTotal", 1)
            available = mem_info.get("MemAvailable", mem_info.get("MemFree", 0))
            metrics["memory"]["usagePercent"] = ((total - available) / total) * 100.0
""", linux_mem_logic)

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'w') as f:
    f.write(code)

