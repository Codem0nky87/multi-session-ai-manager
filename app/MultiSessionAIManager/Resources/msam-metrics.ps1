param([switch]$loop)
$MetricsVersion = '2.4.1'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

function Get-Disks {
    $volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })
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
            availableGB = [double]$vol.SizeRemaining / 1GB
            isCriticalMount = $mountPoint -eq 'C:\'
        }
    }
    
    $physical = @()
    $temperatures = @()
    $osDisks = @(Get-Disk -ErrorAction SilentlyContinue)
    foreach ($device in @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId)) {
        $temperature = $null
        try {
            $counter = $device | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($counter.Temperature -gt 0 -and $counter.Temperature -lt 150) {
                $temperature = [double]$counter.Temperature
            }
        } catch {}
        $free = $null
        # DeviceId and disk number are different identifiers. Match stable IDs;
        # a Storage Spaces member must never inherit the virtual pool's free space.
        $matches = @($osDisks | Where-Object { $device.UniqueId -and $_.UniqueId -eq $device.UniqueId })
        if ($matches.Count -eq 1) {
            try {
                $mounted = @(Get-Partition -DiskNumber $matches[0].Number -ErrorAction Stop |
                    Get-Volume -ErrorAction Stop | Where-Object { $_.Size -gt 0 } |
                    Sort-Object UniqueId -Unique)
                if ($mounted.Count -gt 0) {
                    $free = [double](($mounted | Measure-Object SizeRemaining -Sum).Sum) / 1GB
                }
            } catch {}
        }
        $id = 'physical:' + $device.DeviceId
        $model = if ($device.FriendlyName) { [string]$device.FriendlyName } else { $id }
        $physical += @{
            id = $id; model = $model; volumes = @(); temperature = $temperature
            totalGB = [double]$device.Size / 1GB; availableGB = $free
        }
        if ($null -ne $temperature) {
            $temperatures += @{id=$id; model=$model; temperature=$temperature}
        }
    }

    return @{
        platform = 'win32'
        physicalDisks = $physical
        temperatures = $temperatures
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

function Get-CPUActivity {
    try {
        # CIM class/property names are stable on localized Windows installations.
        $cores = @(Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -ErrorAction Stop |
            Where-Object { $_.Name -match '^\d+,\d+$' } |
            Sort-Object @{Expression={ [int]($_.Name -split ',')[0] }}, @{Expression={ [int]($_.Name -split ',')[1] }})
        if ($cores.Count -gt 0) {
            $values = @($cores | ForEach-Object { [math]::Min(100, [math]::Max(0, [double]$_.PercentProcessorTime)) })
            return @{
                perCoreUsage = $values
                utilization = ($values | Measure-Object -Average).Average
                userUsage = ($cores | Measure-Object PercentUserTime -Average).Average
                systemUsage = ($cores | Measure-Object PercentPrivilegedTime -Average).Average
            }
        }
    } catch {}
    return $null
}

function Get-Metrics {
    $processors = Get-CimInstance Win32_Processor
    $cpuLoad = ($processors | Measure-Object -Property LoadPercentage -Average).Average
    $coreCount = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($null -eq $cpuLoad) { $cpuLoad = 0 }
    $activity = Get-CPUActivity
    if ($null -ne $activity) { $cpuLoad = $activity.utilization }
    
    $mem = Get-CimInstance Win32_OperatingSystem | Select-Object FreePhysicalMemory, TotalVisibleMemorySize,LastBootUpTime
    $memTotal = 0.0
    $memUsed = 0.0
    if ($mem.TotalVisibleMemorySize -gt 0) {
        $memTotal = [math]::Round($mem.TotalVisibleMemorySize / 1MB, 2)
        $memUsed = [math]::Round(($mem.TotalVisibleMemorySize - $mem.FreePhysicalMemory) / 1MB, 2)
    }
    
    $gpuUtil = 0.0
    $gpuAvailable = $false
    try {
        $gpuSamples = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop | Select-Object -ExpandProperty CounterSamples
        if ($null -ne $gpuSamples) {
            $gpuAvailable = $true
            $gpuUtil = ($gpuSamples | Measure-Object -Property CookedValue -Sum).Sum
            if ($gpuUtil -gt 100.0) { $gpuUtil = 100.0 }
        }
    } catch {}

    $gpuName = ""
    $gpuMemoryUsed = 0.0; $gpuMemoryTotal = 0.0; $gpuTemperature = 0.0
    try {
        $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
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
                $gpuAvailable = $true
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
            perCoreUsage = @(if ($activity) { $activity.perCoreUsage })
            systemUsage = if ($activity) { [double]$activity.systemUsage } else { 0.0 }
            userUsage = if ($activity) { [double]$activity.userUsage } else { 0.0 }
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
            utilizationAvailable = $gpuAvailable
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
