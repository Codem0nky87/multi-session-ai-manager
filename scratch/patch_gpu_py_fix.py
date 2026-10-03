import sys

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'r') as f:
    code = f.read()

old_nvidia_logic = '''        nvidia_util = subprocess.check_output(['nvidia-smi', '--query-gpu=utilization.gpu', '--format=csv,noheader,nounits'], stderr=subprocess.DEVNULL).decode('utf-8')
        metrics["gpu"]["usagePercent"] = float(nvidia_util.strip().split('\\n')[0])
        
        nvidia_name = subprocess.check_output(['nvidia-smi', '--query-gpu=name', '--format=csv,noheader'], stderr=subprocess.DEVNULL).decode('utf-8')
        metrics["gpu"]["modelName"] = nvidia_name.strip().split('\\n')[0]'''

new_nvidia_logic = '''        gpu_out = subprocess.check_output(['nvidia-smi', '--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total', '--format=csv,noheader,nounits'], stderr=subprocess.DEVNULL).decode('utf-8')
        parts = gpu_out.strip().split('\\n')[0].split(',')
        metrics["gpu"]["usagePercent"] = float(parts[0].strip())
        metrics["gpu"]["temperature"] = float(parts[1].strip())
        metrics["gpu"]["memoryUsed"] = float(parts[2].strip())
        metrics["gpu"]["memoryTotal"] = float(parts[3].strip())
        
        nvidia_name = subprocess.check_output(['nvidia-smi', '--query-gpu=name', '--format=csv,noheader'], stderr=subprocess.DEVNULL).decode('utf-8')
        metrics["gpu"]["modelName"] = nvidia_name.strip().split('\\n')[0]'''

code = code.replace(old_nvidia_logic, new_nvidia_logic)

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'w') as f:
    f.write(code)

