# Run with powershell.exe or pwsh. Only OS boundaries are fixtures.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../app/MultiSessionAIManager/Resources/msam-metrics.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $source), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
function Assert-Equal($actual, $expected, $label) {
    if ($actual -ne $expected) { throw "$label : expected $expected, got $actual" }
}
$script:failSensors = $false
function Get-PhysicalDisk {
    @([pscustomobject]@{DeviceId='0'; UniqueId='drive-a'; FriendlyName='SSD A'; Size=200GB},
      [pscustomobject]@{DeviceId='1'; UniqueId='pool-member'; FriendlyName='SSD B'; Size=300GB})
}
function Get-Disk {
    [pscustomobject]@{Number=4; UniqueId='drive-a'} # DeviceId is NOT a disk number.
}
function Get-Partition { param($DiskNumber) if ($DiskNumber -eq 4) { [pscustomobject]@{DiskNumber=4} } }
function Get-Volume {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)]$Partition)
    process {
        [pscustomobject]@{DriveType='Fixed'; DriveLetter='C'; FileSystemLabel='System'; Size=100GB; SizeRemaining=18GB; UniqueId='vol-c'}
        if (!$Partition) {
            [pscustomobject]@{DriveType='Fixed'; DriveLetter='D'; FileSystemLabel='Pool'; Size=200GB; SizeRemaining=80GB; UniqueId='vol-d'}
        }
    }
}
function Get-StorageReliabilityCounter {
    [CmdletBinding()] param([Parameter(ValueFromPipeline=$true)]$Disk)
    process { if ($script:failSensors) { throw 'Access denied' }; [pscustomobject]@{Temperature=42} }
}
$result = Get-Disks
Assert-Equal $result.physicalDisks.Count 2 'physical inventory'
Assert-Equal $result.physicalDisks[0].totalGB 200 'hardware size'
Assert-Equal $result.physicalDisks[0].availableGB 18 'matched volume free'
Assert-Equal $result.physicalDisks[0].temperature 42 'sensor'
Assert-Equal $result.physicalDisks[1].availableGB $null 'pool free is not allocated to a member'
Assert-Equal $result.disks[0].volumes.Count 2 'logical volumes'
Assert-Equal $result.disks[0].volumes[0].isCriticalMount $true 'system mount'
Assert-Equal $result.disks[0].volumes[1].isCriticalMount $false 'data mount'
$script:failSensors = $true
$result = Get-Disks
Assert-Equal $result.physicalDisks.Count 2 'sensor failure retains inventory'
Assert-Equal $result.physicalDisks[0].temperature $null 'missing temperature is not zero'
function Get-CimInstance {
    [CmdletBinding()] param($ClassName)
    @([pscustomobject]@{Name='0,10'; PercentProcessorTime=90; PercentUserTime=80; PercentPrivilegedTime=10},
      [pscustomobject]@{Name='_Total'; PercentProcessorTime=99},
      [pscustomobject]@{Name='0,2'; PercentProcessorTime=10; PercentUserTime=8; PercentPrivilegedTime=2})
}
$cpu = Get-CPUActivity
Assert-Equal ($cpu.perCoreUsage -join ',') '10,90' 'numeric processor order'
Assert-Equal $cpu.utilization 50 'total CPU capacity'
function Get-CimInstance {
    [CmdletBinding()] param($ClassName)
    switch ($ClassName) {
        'Win32_Processor' { [pscustomobject]@{LoadPercentage=25; NumberOfLogicalProcessors=1} }
        'Win32_OperatingSystem' {
            [pscustomobject]@{FreePhysicalMemory=4MB; TotalVisibleMemorySize=8MB; LastBootUpTime=(Get-Date).AddDays(-1)}
        }
        'Win32_PerfFormattedData_Counters_ProcessorInformation' {
            [pscustomobject]@{Name='0,0'; PercentProcessorTime=25; PercentUserTime=20; PercentPrivilegedTime=5}
        }
        'Win32_VideoController' { [pscustomobject]@{Name='Fixture GPU'} }
    }
}
function Get-NetAdapter { param([switch]$Physical) @() }
function Get-Counter { [CmdletBinding()] param($Counter) throw 'GPU counters unavailable in fixture' }
function Get-Command { [CmdletBinding()] param($Name) $null }
$payload = Get-Metrics | ConvertFrom-Json
if ($payload.cpu.perCoreUsage -isnot [array]) { throw 'Single-core payload must serialize perCoreUsage as a JSON array' }
Assert-Equal $payload.cpu.perCoreUsage.Count 1 'single-core count'
Assert-Equal $payload.cpu.perCoreUsage[0] 25 'single-core load'
Write-Output 'Windows metrics fixtures passed (inventory, pooled storage, sensors, logical cores).'
