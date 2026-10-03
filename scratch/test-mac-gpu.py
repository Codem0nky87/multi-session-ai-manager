import subprocess
try:
    pm_gpu = subprocess.check_output(['sudo', 'powermetrics', '--samplers', 'gpu_power', '-n', '1', '-i', '1'], stderr=subprocess.DEVNULL).decode('utf-8')
    for line in pm_gpu.split('\n'):
        if 'active residency' in line and 'GPU' in line:
            parts = line.split(':')
            if len(parts) > 1:
                val = parts[1].strip().split('%')[0].strip()
                print(f"Found val: '{val}'")
                print(f"Float val: {float(val)}")
                break
except Exception as e:
    print(f"Error: {e}")
