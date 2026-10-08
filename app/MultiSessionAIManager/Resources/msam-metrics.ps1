param([switch]$loop)
$MetricsVersion = '2.1.1'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Get-Disks {
    $volumes = Get-Volume | Where-Object DriveType -eq 'Fixed' | Select-Object DriveLetter,FileSystemLabel,Size,SizeRemaining,UniqueId
    $vols = @()
    $totalGB = 0.0
    $usedGB = 0.0
    foreach ($vol in $volumes) {
        $id = if ($vol.DriveLetter) { $vol.DriveLetter + ':' } else { $vol.UniqueId }
        $name = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { 'Local Disk' }
        $mountPoint = if ($vol.DriveLetter) { $vol.DriveLetter + ':\' } else { '' }
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
                model = "Windows Disks"
                volumes = $vols
            }
        )
    }
}

function Get-Metrics {
    $processors = Get-CimInstance Win32_Processor
    $cpuLoad = ($processors | Measure-Object -Property LoadPercentage -Average).Average
    $coreCount = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($null -eq $cpuLoad) { $cpuLoad = 0 }
    
    $mem = Get-CimInstance Win32_OperatingSystem | Select-Object FreePhysicalMemory, TotalVisibleMemorySize,LastBootUpTime
    $memTotal = 0.0
    $memUsed = 0.0
    if ($mem.TotalVisibleMemorySize -gt 0) {
        $memTotal = [math]::Round($mem.TotalVisibleMemorySize / 1MB, 2)
        $memUsed = [math]::Round(($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / 1MB, 2)
    }
    
    $gpuUtil = 0.0
    try {
        $gpuSamples = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | Where-Object { $_.CookedValue -gt 0 }
        if ($null -ne $gpuSamples) {
            $gpuUtil = ($gpuSamples | Measure-Object -Property CookedValue -Sum).Sum
            if ($gpuUtil -gt 100.0) { $gpuUtil = 100.0 }
        }
    } catch {}

    $gpuName = ""
    $gpuMemoryUsed = 0.0; $gpuMemoryTotal = 0.0; $gpuTemperature = 0.0
    try {
        $gpu = Get-WmiObject Win32_VideoController | Select-Object -First 1
        if ($null -ne $gpu) {
            $gpuName = $gpu.Name
        }
    } catch {}
    try {
        $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
        if ($smi) {
            $readings = @(& $smi.Source --query-gpu=name,utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits 2>$null)
            if ($LASTEXITCODE -eq 0 -and $readings.Count -gt 0) {
                $values = $readings[0] -split ',\s*'
                $gpuName = $values[0]; $gpuUtil = [double]$values[1]
                $gpuTemperature = [double]$values[2]; $gpuMemoryUsed = [double]$values[3]; $gpuMemoryTotal = [double]$values[4]
            }
        }
    } catch {}

    $networkCounters = @{}
    try {
        foreach ($adapter in (Get-NetAdapter -Physical | Where-Object Status -eq 'Up')) {
            $stats = $adapter | Get-NetAdapterStatistics
            $networkCounters[$adapter.InterfaceGuid.ToString()] = @{
                received = [double]$stats.ReceivedBytes; sent = [double]$stats.SentBytes
            }
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
            uptime = ('{0} days, {1} hours' -f ((Get-Date)-$mem.LastBootUpTime).Days, ((Get-Date)-$mem.LastBootUpTime).Hours)
            coreCount = [int]$coreCount
            freqAllCores = 0
            freqEfficiency = 0
            freqPerformance = 0
            history = @()
            topProcesses = @()
            loadAverage1m = 0.0
            loadAverage5m = 0.0
            loadAverage15m = 0.0
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
            temperature = $gpuTemperature
            memoryUsed = $gpuMemoryUsed
            memoryTotal = $gpuMemoryTotal
        }
        networkCounters = $networkCounters
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
