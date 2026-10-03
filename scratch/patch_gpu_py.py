import sys

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'r') as f:
    code = f.read()

# Replace GPU dict in get_linux_metrics
old_gpu_dict = '''        "gpu": {
            "usagePercent": 0.0,
            "modelName": "",
            "cores": 0
        }'''
new_gpu_dict = '''        "gpu": {
            "usagePercent": 0.0,
            "modelName": "",
            "cores": 0,
            "temperature": 0.0,
            "memoryUsed": 0.0,
            "memoryTotal": 0.0
        }'''
code = code.replace(old_gpu_dict, new_gpu_dict)

# In get_linux_metrics, update the nvidia-smi logic
old_nvidia_logic = '''        try:
            gpu_out = subprocess.check_output(['nvidia-smi', '--query-gpu=utilization.gpu', '--format=csv,noheader,nounits']).decode('utf-8')
            metrics["gpu"]["usagePercent"] = float(gpu_out.strip())
            
            gpu_model = subprocess.check_output(['nvidia-smi', '--query-gpu=name', '--format=csv,noheader']).decode('utf-8')
            metrics["gpu"]["modelName"] = gpu_model.strip()
        except Exception:
            pass'''

new_nvidia_logic = '''        try:
            gpu_out = subprocess.check_output(['nvidia-smi', '--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total', '--format=csv,noheader,nounits']).decode('utf-8')
            parts = gpu_out.strip().split(',')
            metrics["gpu"]["usagePercent"] = float(parts[0].strip())
            metrics["gpu"]["temperature"] = float(parts[1].strip())
            metrics["gpu"]["memoryUsed"] = float(parts[2].strip())
            metrics["gpu"]["memoryTotal"] = float(parts[3].strip())
            
            gpu_model = subprocess.check_output(['nvidia-smi', '--query-gpu=name', '--format=csv,noheader']).decode('utf-8')
            metrics["gpu"]["modelName"] = gpu_model.strip()
        except Exception:
            pass'''
code = code.replace(old_nvidia_logic, new_nvidia_logic)

with open('app/MultiSessionAIManager/Resources/msam-metrics.py', 'w') as f:
    f.write(code)

