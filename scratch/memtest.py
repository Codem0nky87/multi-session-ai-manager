import subprocess
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

usage_percent = (used_memory / total_ram) * 100.0
print(f"Total: {total_ram}, Used: {used_memory}, Percent: {usage_percent}")
