import re

with open("app/MultiSessionAIManager/Core/MSAMMetricsInstaller.swift", "r") as f:
    code = f.read()

win_script = '''    static let windowsScript = """
param([switch]$loop)

function Get-Disks {
    $volumes = Get-Volume | Where-Object DriveType -eq 'Fixed' | Select-Object DriveLetter,FileSystemLabel,Size,SizeRemaining
    $vols = @()
    $totalGB = 0.0
    $usedGB = 0.0
    foreach ($vol in $volumes) {
        $id = if ($vol.DriveLetter) { $vol.DriveLetter + ':' } else { 'Vol' }
        $name = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { 'Local Disk' }
        $mountPoint = if ($vol.DriveLetter) { $vol.DriveLetter + ':\\\\' } else { '' }
        $tGB = 0.0
        $uGB = 0.0
        if ($vol.Size -gt 0) {
            $tGB = [math]::Round($vol.Size / 1GB, 2)
            $uGB = [math]::Round(($vol.Size - $vol.SizeRemaining) / 1GB, 2)
        }
        $totalGB += $tGB
        $usedGB += $uGB
        $vols += @{
            id = $id
            name = $name
            mountPoint = $mountPoint
            totalGB = $tGB
            usedGB = $uGB
        }
    }
    
    return @{
        usagePercent = if ($totalGB -gt 0) { [math]::Round(($usedGB / $totalGB) * 100, 2) } else { 0.0 }
        totalGB = $totalGB
        usedGB = $usedGB
        disks = @(
            @{
                id = "win_disks"
                name = "Windows Disks"
                volumes = $vols
            }
        )
    }
}

function Get-Metrics {
    $cpuLoad = (Get-WmiObject Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    if ($null -eq $cpuLoad) { $cpuLoad = 0 }
    
    $mem = Get-WmiObject Win32_OperatingSystem | Select-Object FreePhysicalMemory, TotalVisibleMemorySize
    $memTotal = 0.0
    $memUsed = 0.0
    if ($mem.TotalVisibleMemorySize -gt 0) {
        $memTotal = [math]::Round($mem.TotalVisibleMemorySize / 1MB, 2)
        $memUsed = [math]::Round(($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / 1MB, 2)
    }
    
    $gpuUtil = 0.0
    try {
        $gpuSamples = Get-Counter '\\\\GPU Engine(*)\\\\Utilization Percentage' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | Where-Object { $_.CookedValue -gt 0 }
        if ($null -ne $gpuSamples) {
            $gpuUtil = ($gpuSamples | Measure-Object -Property CookedValue -Sum).Sum
            if ($gpuUtil -gt 100.0) { $gpuUtil = 100.0 }
        }
    } catch {}

    $gpuName = ""
    try {
        $gpu = Get-WmiObject Win32_VideoController | Select-Object -First 1
        if ($null -ne $gpu) {
            $gpuName = $gpu.Name
        }
    } catch {}

    $data = @{
        cpu = @{
            temperature = 0.0
            utilization = [math]::Round($cpuLoad, 2)
            systemUsage = 0.0
            userUsage = 0.0
            idleUsage = [math]::Round(100.0 - $cpuLoad, 2)
            efficiencyCoreUsage = 0.0
            performanceCoreUsage = 0.0
            uptime = ""
            freqAllCores = 0
            freqEfficiency = 0
            freqPerformance = 0
            history = @()
            topProcesses = @()
        }
        memory = @{
            usagePercent = if ($memTotal -gt 0) { [math]::Round(($memUsed / $memTotal) * 100, 2) } else { 0.0 }
            total = $memTotal
            used = $memUsed
            app = $memUsed
            wired = 0.0
            compressed = 0.0
            free = if ($memTotal -gt 0) { [math]::Round($memTotal - $memUsed, 2) } else { 0.0 }
            swap = 0.0
        }
        disk = Get-Disks
        gpu = @{
            usagePercent = [math]::Round($gpuUtil, 2)
            modelName = $gpuName
            cores = 0
            temperature = 0.0
            memoryUsed = 0.0
            memoryTotal = 0.0
        }
    }
    
    return $data | ConvertTo-Json -Depth 10 -Compress
}

do {
    $out = Get-Metrics
    [Console]::WriteLine($out)
    [Console]::Out.Flush()
    if ($loop) {
        Start-Sleep -Seconds 2
    }
} while ($loop)
"""
'''

replacement = win_script + """
    static func install(using service: SSHService) async throws {
        let isWindows = service.isWindows
        
        let scriptData: Data
        if isWindows {
            scriptData = windowsScript.data(using: .utf8)!
        } else {
            guard let scriptURL = Bundle.main.url(forResource: "msam-metrics", withExtension: "py") else {
                throw Failure.scriptNotFound
            }
            do {
                scriptData = try Data(contentsOf: scriptURL)
            } catch {
                throw Failure.uploadFailed("Could not read msam-metrics.py from bundle: \\(error)")
            }
        }
"""

code = re.sub(r'    static func install\(using service: SSHService\) async throws \{\n        let isWindows = service.isWindows.*?(?=        let home: String)', replacement.strip('\n') + '\n', code, flags=re.DOTALL)

with open("app/MultiSessionAIManager/Core/MSAMMetricsInstaller.swift", "w") as f:
    f.write(code)
