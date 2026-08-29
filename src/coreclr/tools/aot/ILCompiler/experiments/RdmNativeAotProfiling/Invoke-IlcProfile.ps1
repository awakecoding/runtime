[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $IlcPath,

    [Parameter(Mandatory)]
    [string] $ResponseFile,

    [Parameter(Mandatory)]
    [string] $WorkingDirectory,

    [Parameter(Mandatory)]
    [string] $RunRoot,

    [string[]] $Experiments = @(),

    [int] $SampleIntervalMilliseconds = 1000,

    [switch] $ProfileMethods,

    [int] $MinimumFreeMemoryGiB = 0,

    [int] $MaximumCpuLoadPercent = 100,

    [int] $GuardSampleCount = 3,

    [int] $GuardSampleIntervalSeconds = 5,

    [int] $GuardTimeoutSeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($SampleIntervalMilliseconds -lt 100)
{
    throw 'SampleIntervalMilliseconds must be at least 100.'
}
if ($GuardSampleCount -lt 1 -or $GuardSampleIntervalSeconds -lt 1 -or $GuardTimeoutSeconds -lt 1)
{
    throw 'Guard sample count, interval, and timeout must be positive.'
}

function Get-MachineSnapshot
{
    $operatingSystem = Get-CimInstance Win32_OperatingSystem
    $processors = @(Get-CimInstance Win32_Processor)
    $processorPerformance = Get-CimInstance `
        Win32_PerfFormattedData_Counters_ProcessorInformation `
        -Filter "Name='_Total'" `
        -ErrorAction SilentlyContinue
    $thermalZones = @(
        Get-CimInstance `
            -Namespace root/wmi `
            -ClassName MSAcpi_ThermalZoneTemperature `
            -ErrorAction SilentlyContinue
    )

    [pscustomobject] @{
        TimestampUtc = [DateTime]::UtcNow
        FreePhysicalMemoryBytes = [UInt64]$operatingSystem.FreePhysicalMemory * 1KB
        CpuLoadPercent = ($processors | Measure-Object LoadPercentage -Average).Average
        CurrentClockSpeedMHz = ($processors | Measure-Object CurrentClockSpeed -Average).Average
        MaximumClockSpeedMHz = ($processors | Measure-Object MaxClockSpeed -Average).Average
        PerformanceClockSpeedMHz = if ($processorPerformance) { $processorPerformance.ProcessorFrequency } else { $null }
        PercentMaximumFrequency = if ($processorPerformance) { $processorPerformance.PercentofMaximumFrequency } else { $null }
        ThermalZoneCelsius = @(
            $thermalZones |
                ForEach-Object { ($_.CurrentTemperature / 10) - 273.15 }
        )
    }
}

$ilcPath = (Resolve-Path -LiteralPath $IlcPath).Path
$responseFile = (Resolve-Path -LiteralPath $ResponseFile).Path
$workingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$runRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (Test-Path $runRoot)
{
    throw "Run root already exists: $runRoot"
}

New-Item -ItemType Directory -Path $runRoot | Out-Null
$guardSamples = [System.Collections.Generic.List[object]]::new()
$guardStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$consecutiveGuardSamples = 0
$requiredGuardSamples =
    if ($MinimumFreeMemoryGiB -gt 0 -or $MaximumCpuLoadPercent -lt 100) { $GuardSampleCount } else { 1 }
do
{
    $machineSnapshot = Get-MachineSnapshot
    $guardAccepted =
        $machineSnapshot.FreePhysicalMemoryBytes -ge $MinimumFreeMemoryGiB * 1GB -and
        $machineSnapshot.CpuLoadPercent -le $MaximumCpuLoadPercent
    $guardSamples.Add([pscustomobject] @{
        TimestampUtc = $machineSnapshot.TimestampUtc
        FreePhysicalMemoryBytes = $machineSnapshot.FreePhysicalMemoryBytes
        CpuLoadPercent = $machineSnapshot.CpuLoadPercent
        CurrentClockSpeedMHz = $machineSnapshot.CurrentClockSpeedMHz
        MaximumClockSpeedMHz = $machineSnapshot.MaximumClockSpeedMHz
        PerformanceClockSpeedMHz = $machineSnapshot.PerformanceClockSpeedMHz
        PercentMaximumFrequency = $machineSnapshot.PercentMaximumFrequency
        ThermalZoneCelsius = $machineSnapshot.ThermalZoneCelsius -join ';'
        Accepted = $guardAccepted
    })
    $consecutiveGuardSamples = if ($guardAccepted) { $consecutiveGuardSamples + 1 } else { 0 }

    if ($consecutiveGuardSamples -lt $requiredGuardSamples)
    {
        if ($guardStopwatch.Elapsed.TotalSeconds -ge $GuardTimeoutSeconds)
        {
            $guardSamples |
                Export-Csv -LiteralPath (Join-Path $runRoot 'machine-guard.csv') -NoTypeInformation
            throw "Machine guard timed out after $GuardTimeoutSeconds seconds."
        }
        Start-Sleep -Seconds $GuardSampleIntervalSeconds
    }
}
while ($consecutiveGuardSamples -lt $requiredGuardSamples)
$guardStopwatch.Stop()
$guardSamples | Export-Csv -LiteralPath (Join-Path $runRoot 'machine-guard.csv') -NoTypeInformation
$machineBefore = $machineSnapshot

$localResponse = Join-Path $runRoot 'input.ilc.rsp'
$objectPath = Join-Path $runRoot 'output.obj'
$profilePath = Join-Path $runRoot 'ilc-profile.csv'
$responseLines = @(Get-Content -LiteralPath $responseFile)
$outputArgumentCount = @($responseLines | Where-Object { $_ -like '-o:*' }).Count
if ($outputArgumentCount -ne 1)
{
    throw "Expected one ILC output argument; found $outputArgumentCount."
}

$outputPrefixes = @(
    '-o:',
    '--dgmllog:',
    '--exportsfile:',
    '--ildump:',
    '--map:',
    '--metadatalog:',
    '--mstat:',
    '--scandgmllog:',
    '--sourcelink:'
)
$relocatedOutputs = [System.Collections.Generic.List[string]]::new()
$responseLines |
    ForEach-Object {
        foreach ($prefix in $outputPrefixes)
        {
            if ($_.StartsWith($prefix, [StringComparison]::Ordinal))
            {
                $sourcePath = $_.Substring($prefix.Length).Trim('"')
                $destination = if ($prefix -eq '-o:')
                {
                    $objectPath
                }
                else
                {
                    Join-Path $runRoot ([System.IO.Path]::GetFileName($sourcePath))
                }
                $relocatedOutputs.Add($destination)
                return '{0}"{1}"' -f $prefix, $destination
            }
        }

        return $_
    } |
        Set-Content -LiteralPath $localResponse -Encoding utf8NoBOM

$environment = @{}
foreach ($name in @(
    'DOTNET_ROOT',
    'DOTNET_MULTILEVEL_LOOKUP',
    'DOTNET_ILC_EXPERIMENTS',
    'DOTNET_ILC_PROFILE_PATH',
    'DOTNET_ILC_PROFILE_METHODS'))
{
    $environment[$name] = [pscustomobject] @{
        Exists = Test-Path "Env:$name"
        Value = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
}

$standardOutput = Join-Path $runRoot 'ilc.stdout.log'
$standardError = Join-Path $runRoot 'ilc.stderr.log'
$samples = [System.Collections.Generic.List[object]]::new()
$startedUtc = [DateTime]::UtcNow
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$argument = '@"{0}"' -f $localResponse
$process = $null

try
{
    $env:DOTNET_ROOT = Split-Path -Parent (Get-Command dotnet).Source
    $env:DOTNET_MULTILEVEL_LOOKUP = '0'
    if ($Experiments.Count -gt 0)
    {
        $env:DOTNET_ILC_EXPERIMENTS = $Experiments -join ';'
    }
    else
    {
        Remove-Item Env:DOTNET_ILC_EXPERIMENTS -ErrorAction SilentlyContinue
    }
    $env:DOTNET_ILC_PROFILE_PATH = $profilePath
    $env:DOTNET_ILC_PROFILE_METHODS = $ProfileMethods.IsPresent.ToString()

    $process = Start-Process `
        -FilePath $ilcPath `
        -ArgumentList $argument `
        -WorkingDirectory $workingDirectory `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -PassThru

    do
    {
        $timestampUtc = [DateTime]::UtcNow
        $process.Refresh()
        if (-not $process.HasExited)
        {
            $cimProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -ErrorAction SilentlyContinue
            $samples.Add([pscustomobject] @{
                TimestampUtc = $timestampUtc
                SecondsSinceStart = ($timestampUtc - $startedUtc).TotalSeconds
                CpuSeconds = $process.TotalProcessorTime.TotalSeconds
                WorkingSetBytes = $process.WorkingSet64
                PeakWorkingSetBytes = $process.PeakWorkingSet64
                PrivateMemoryBytes = $process.PrivateMemorySize64
                PagedMemoryBytes = $process.PagedMemorySize64
                ThreadCount = @($process.Threads).Count
                ReadBytes = if ($cimProcess) { [UInt64] $cimProcess.ReadTransferCount } else { 0 }
                WriteBytes = if ($cimProcess) { [UInt64] $cimProcess.WriteTransferCount } else { 0 }
                ReadOperations = if ($cimProcess) { [UInt64] $cimProcess.ReadOperationCount } else { 0 }
                WriteOperations = if ($cimProcess) { [UInt64] $cimProcess.WriteOperationCount } else { 0 }
            })
        }
    }
    while (-not $process.WaitForExit($SampleIntervalMilliseconds))

    $process.WaitForExit()
    $process.Refresh()
    $stopwatch.Stop()
}
finally
{
    try
    {
        if ($process -and -not $process.HasExited)
        {
            Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
            $process.WaitForExit()
        }
    }
    finally
    {
        foreach ($name in $environment.Keys)
        {
            if ($environment[$name].Exists)
            {
                Set-Item "Env:$name" $environment[$name].Value
            }
            else
            {
                Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            }
        }
    }
}

if ($process.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $profilePath))
{
    throw "ILC completed without writing a profile. Confirm the profiling patch is applied: $profilePath"
}

$machineAfter = Get-MachineSnapshot
$samples | Export-Csv -LiteralPath (Join-Path $runRoot 'ilc-samples.csv') -NoTypeInformation
$metadata = [pscustomobject] @{
    ExitCode = $process.ExitCode
    StartedUtc = $startedUtc
    WallSeconds = $stopwatch.Elapsed.TotalSeconds
    CpuSeconds = $process.TotalProcessorTime.TotalSeconds
    AverageLogicalCores = $process.TotalProcessorTime.TotalSeconds / $stopwatch.Elapsed.TotalSeconds
    LogicalProcessorCount = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
    PeakWorkingSetBytes = ($samples | Measure-Object PeakWorkingSetBytes -Maximum).Maximum
    PeakPrivateMemoryBytes = ($samples | Measure-Object PrivateMemoryBytes -Maximum).Maximum
    PeakPagedMemoryBytes = ($samples | Measure-Object PagedMemoryBytes -Maximum).Maximum
    MaximumThreadCount = ($samples | Measure-Object ThreadCount -Maximum).Maximum
    ReadBytes = ($samples | Measure-Object ReadBytes -Maximum).Maximum
    WriteBytes = ($samples | Measure-Object WriteBytes -Maximum).Maximum
    SampleCount = $samples.Count
    Experiments = $Experiments
    ProfileMethods = $ProfileMethods.IsPresent
    MachineGuard = [pscustomobject] @{
        MinimumFreeMemoryGiB = $MinimumFreeMemoryGiB
        MaximumCpuLoadPercent = $MaximumCpuLoadPercent
        RequiredConsecutiveSamples = $requiredGuardSamples
        WaitSeconds = $guardStopwatch.Elapsed.TotalSeconds
    }
    MachineBefore = $machineBefore
    MachineAfter = $machineAfter
    IlcPath = $ilcPath
    IlcExeSha256 = (Get-FileHash $ilcPath -Algorithm SHA256).Hash
    IlcDllSha256 = (Get-FileHash (Join-Path (Split-Path $ilcPath) 'ilc.dll') -Algorithm SHA256).Hash
    SourceResponseFile = $responseFile
    SourceResponseSha256 = (Get-FileHash $responseFile -Algorithm SHA256).Hash
    ResponseFile = $localResponse
    ResponseSha256 = (Get-FileHash $localResponse -Algorithm SHA256).Hash
    RelocatedOutputs = @($relocatedOutputs)
    ObjectPath = $objectPath
    ObjectBytes = if (Test-Path $objectPath) { (Get-Item $objectPath).Length } else { 0 }
    ObjectSha256 = if (Test-Path $objectPath) { (Get-FileHash $objectPath -Algorithm SHA256).Hash } else { '' }
    ProfilePath = $profilePath
}
$metadata |
    ConvertTo-Json -Depth 4 |
    Set-Content -LiteralPath (Join-Path $runRoot 'run-metadata.json') -Encoding utf8
$metadata

exit $process.ExitCode
