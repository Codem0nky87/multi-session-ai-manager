import Foundation

enum MSAMMetricsInstaller {
    static let scriptRelativePath = ".local/bin/msam-metrics"
    static let commandName = "msam-metrics"
    static let timeout = Duration.seconds(30)
    static let outputLimit = 64 * 1024

    enum Failure: Error, Equatable, LocalizedError {
        case notConnected
        case scriptNotFound
        case uploadFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConnected: "Connect to the host before installing hardware metrics."
            case .scriptNotFound: "The app is missing its bundled hardware metrics helper."
            case .uploadFailed(let message): "Could not install hardware metrics: \(message)"
            }
        }
    }

    static let windowsScript = """
param([switch]$loop)

function Get-Disks {
    $volumes = Get-Volume | Where-Object DriveType -eq 'Fixed' | Select-Object DriveLetter,FileSystemLabel,Size,SizeRemaining
    $vols = @()
    $totalGB = 0.0
    $usedGB = 0.0
    foreach ($vol in $volumes) {
        $id = if ($vol.DriveLetter) { $vol.DriveLetter + ':' } else { 'Vol' }
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
        $gpuSamples = Get-Counter '\\GPU Engine(*)\\Utilization Percentage' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty CounterSamples | Where-Object { $_.CookedValue -gt 0 }
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
                throw Failure.uploadFailed("Could not read msam-metrics.py from bundle: \(error)")
            }
        }
        let home: String
        do {
            if isWindows {
                let probe = try await service.runCommand("powershell -Command \"if (!(Test-Path $env:USERPROFILE\\.local\\bin)) { New-Item -ItemType Directory -Force -Path $env:USERPROFILE\\.local\\bin | Out-Null }; Write-Host -NoNewline $env:USERPROFILE\"")
                home = probe.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let probe = try await service.run(
                    "mkdir -p \"$HOME/.local/bin\" && printf %s \"$HOME\"",
                    timeout: timeout,
                    outputLimit: outputLimit
                )
                home = probe.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            throw Failure.uploadFailed("could not prepare ~/.local/bin: \(error)")
        }
        
        if !isWindows {
            guard home.hasPrefix("/") else {
                throw Failure.uploadFailed("the host did not report a home directory")
            }
        }

        let winPath = home + "\\.local\\bin\\msam-metrics.ps1"
        let posixPath = home + "/" + scriptRelativePath
        
        do {
            if isWindows {
                try await service.writeSetupFile(scriptData, to: winPath.replacingOccurrences(of: "\\", with: "/"))
            } else {
                try await service.writeSetupFile(scriptData, to: posixPath, permissions: 0o755)
            }
        } catch {
            throw Failure.uploadFailed("\(error)")
        }

        if !isWindows {
            do {
                _ = try await service.run("chmod 0755 \"$HOME/\(scriptRelativePath)\"", timeout: timeout, outputLimit: outputLimit)
            } catch {
                throw Failure.uploadFailed("could not make script executable: \(error)")
            }
        }
    }
    }
