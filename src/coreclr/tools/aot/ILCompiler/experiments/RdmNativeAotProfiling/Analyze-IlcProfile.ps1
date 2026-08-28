[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RunRoot,

    [double] $ControlWallSeconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runRoot = (Resolve-Path -LiteralPath $RunRoot).Path
$profile = @(Import-Csv -LiteralPath (Join-Path $runRoot 'ilc-profile.csv'))
$metadata = Get-Content -LiteralPath (Join-Path $runRoot 'run-metadata.json') -Raw |
    ConvertFrom-Json

$phases = @(
    $profile |
        Where-Object Kind -eq 'phase' |
        ForEach-Object {
            [pscustomobject] @{
                Name = $_.Name
                Count = [long] $_.Count
                TotalSeconds = [double] $_.TotalMilliseconds / 1000
                MaxSeconds = [double] $_.MaxMilliseconds / 1000
            }
        }
)
$compilerSeconds = ($phases | Where-Object Name -eq 'compiler-total').TotalSeconds
$phaseRows = @(
    $phases |
        ForEach-Object {
            [pscustomobject] @{
                Name = $_.Name
                Count = $_.Count
                TotalSeconds = $_.TotalSeconds
                PercentOfCompiler = 100 * $_.TotalSeconds / $compilerSeconds
                MaxSeconds = $_.MaxSeconds
            }
        }
)
$phaseRows |
    Sort-Object TotalSeconds -Descending |
    Export-Csv -LiteralPath (Join-Path $runRoot 'phase-summary.csv') -NoTypeInformation

$counterRows = @(
    $profile |
        Where-Object Kind -eq 'counter' |
        ForEach-Object {
            [pscustomobject] @{
                Name = $_.Name
                Value = [long] $_.Value
            }
        }
)
$counterRows |
    Export-Csv -LiteralPath (Join-Path $runRoot 'counter-summary.csv') -NoTypeInformation

$assemblyRows = @(
    $profile |
        Where-Object Kind -eq 'assembly' |
        ForEach-Object {
            [pscustomobject] @{
                Assembly = $_.Name
                InvocationCount = [long] $_.Count
                WallSumSeconds = [double] $_.TotalMilliseconds / 1000
                MaxSeconds = [double] $_.MaxMilliseconds / 1000
                FallbackCount = [long] $_.FallbackCount
            }
        }
)
$assemblyRows |
    Export-Csv -LiteralPath (Join-Path $runRoot 'assembly-summary.csv') -NoTypeInformation

$profile |
    Where-Object Kind -eq 'type' |
    Export-Csv -LiteralPath (Join-Path $runRoot 'top-types.csv') -NoTypeInformation
$profile |
    Where-Object Kind -eq 'method' |
    Export-Csv -LiteralPath (Join-Path $runRoot 'top-methods.csv') -NoTypeInformation

$workerSamples = @(
    $profile |
        Where-Object Kind -eq 'worker-sample' |
        ForEach-Object {
            [pscustomobject] @{
                ElapsedSeconds = [double] $_.TotalMilliseconds / 1000
                ActiveWorkers = [int] $_.Count
            }
        }
)
$workerDistribution = @(
    $workerSamples |
        Group-Object ActiveWorkers |
        Sort-Object { [int] $_.Name } |
        ForEach-Object {
            [pscustomobject] @{
                ActiveWorkers = [int] $_.Name
                Samples = $_.Count
                Percent = 100 * $_.Count / $workerSamples.Count
            }
        }
)
$workerDistribution |
    Export-Csv -LiteralPath (Join-Path $runRoot 'worker-distribution.csv') -NoTypeInformation

$samples = @(
    Import-Csv -LiteralPath (Join-Path $runRoot 'ilc-samples.csv') |
        ForEach-Object {
            [pscustomobject] @{
                Seconds = [double] $_.SecondsSinceStart
                CpuSeconds = [double] $_.CpuSeconds
                WorkingSetBytes = [double] $_.WorkingSetBytes
                ReadBytes = [double] $_.ReadBytes
                WriteBytes = [double] $_.WriteBytes
            }
        } |
        Sort-Object Seconds
)
$sampleIntervals = [System.Collections.Generic.List[object]]::new()
for ($index = 1; $index -lt $samples.Count; $index++)
{
    $duration = $samples[$index].Seconds - $samples[$index - 1].Seconds
    if ($duration -le 0)
    {
        continue
    }

    $sampleIntervals.Add([pscustomobject] @{
        Seconds = $samples[$index - 1].Seconds
        Duration = $duration
        LogicalCores = ($samples[$index].CpuSeconds - $samples[$index - 1].CpuSeconds) / $duration
        WorkingSetBytes = $samples[$index].WorkingSetBytes
        ReadBytes = $samples[$index].ReadBytes - $samples[$index - 1].ReadBytes
        WriteBytes = $samples[$index].WriteBytes - $samples[$index - 1].WriteBytes
    })
}
$resourceMinutes = @(
    $sampleIntervals |
        Group-Object { [Math]::Floor($_.Seconds / 60) } |
        ForEach-Object {
            $duration = ($_.Group | Measure-Object Duration -Sum).Sum
            $cpu = (
                $_.Group |
                    ForEach-Object { $_.LogicalCores * $_.Duration } |
                    Measure-Object -Sum
            ).Sum
            [pscustomobject] @{
                Minute = [int] $_.Name
                AverageLogicalCores = $cpu / $duration
                MaxWorkingSetGB = ($_.Group | Measure-Object WorkingSetBytes -Maximum).Maximum / 1GB
                ReadGB = ($_.Group | Measure-Object ReadBytes -Sum).Sum / 1GB
                WriteGB = ($_.Group | Measure-Object WriteBytes -Sum).Sum / 1GB
            }
        }
)
$resourceMinutes |
    Export-Csv -LiteralPath (Join-Path $runRoot 'resource-minutes.csv') -NoTypeInformation

$methodAggregate = $profile | Where-Object Kind -eq 'aggregate' | Select-Object -First 1
$methodBatch = $phases | Where-Object Name -eq 'method-codegen-batches-wall'
$graphAndCodegen = $phases | Where-Object Name -eq 'dependency-graph-and-codegen'
$methodSummary = if ($methodAggregate)
{
    $methodWallSumSeconds = [double] $methodAggregate.TotalMilliseconds / 1000
    [pscustomobject] @{
        InvocationCount = [long] $methodAggregate.Count
        WallSumSeconds = $methodWallSumSeconds
        BatchWallSeconds = $methodBatch.TotalSeconds
        AverageConcurrencyDuringBatches = if ($methodBatch.TotalSeconds -gt 0)
        {
            $methodWallSumSeconds / $methodBatch.TotalSeconds
        }
        else
        {
            0
        }
        GraphTimeOutsideMethodBatchesSeconds = $graphAndCodegen.TotalSeconds - $methodBatch.TotalSeconds
        GraphTimeOutsideMethodBatchesPercent = if ($graphAndCodegen.TotalSeconds -gt 0)
        {
            100 * ($graphAndCodegen.TotalSeconds - $methodBatch.TotalSeconds) / $graphAndCodegen.TotalSeconds
        }
        else
        {
            0
        }
        MaximumMethodSeconds = [double] $methodAggregate.MaxMilliseconds / 1000
        FallbackCount = [long] $methodAggregate.FallbackCount
    }
}
else
{
    $null
}

$workerSummary = if ($workerSamples.Count -gt 0)
{
    $activeSamples = @($workerSamples | Where-Object ActiveWorkers -gt 0)
    [pscustomobject] @{
        SampleCount = $workerSamples.Count
        AverageActiveWorkers = ($workerSamples | Measure-Object ActiveWorkers -Average).Average
        AverageActiveWorkersWhenBusy = if ($activeSamples.Count -gt 0)
        {
            ($activeSamples | Measure-Object ActiveWorkers -Average).Average
        }
        else
        {
            0
        }
        MaximumActiveWorkers = ($workerSamples | Measure-Object ActiveWorkers -Maximum).Maximum
        PercentIdle = 100 * @($workerSamples | Where-Object ActiveWorkers -eq 0).Count / $workerSamples.Count
    }
}
else
{
    $null
}

function Get-CoffCardinality([string] $Path)
{
    if (-not (Test-Path -LiteralPath $Path))
    {
        return $null
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try
    {
        $reader = [System.IO.BinaryReader]::new($stream)
        $signature1 = $reader.ReadUInt16()
        $signature2 = $reader.ReadUInt16()
        if ($signature1 -eq 0 -and $signature2 -eq 0xFFFF)
        {
            $stream.Position = 44
            return [pscustomobject] @{
                Format = 'COFF BigObj'
                Sections = $reader.ReadUInt32()
                SymbolTableOffset = $reader.ReadUInt32()
                Symbols = $reader.ReadUInt32()
                ObjectBytes = $stream.Length
            }
        }

        $stream.Position = 2
        $sections = $reader.ReadUInt16()
        $stream.Position = 8
        return [pscustomobject] @{
            Format = 'COFF'
            Sections = $sections
            SymbolTableOffset = $reader.ReadUInt32()
            Symbols = $reader.ReadUInt32()
            ObjectBytes = $stream.Length
        }
    }
    finally
    {
        $stream.Dispose()
    }
}

$responseLines = @(Get-Content -LiteralPath $metadata.ResponseFile)
$responseSummary = [pscustomobject] @{
    InputAssemblies = @($responseLines | Where-Object { $_ -and $_[0] -ne '-' }).Count
    References = @($responseLines | Where-Object { $_ -like '-r:*' }).Count
    ExplicitRoots = @($responseLines | Where-Object { $_ -like '--root:*' -or $_ -like '--conditionalroot:*' }).Count
    TrimmedAssemblies = @($responseLines | Where-Object { $_ -like '--trim:*' }).Count
    Optimize = $responseLines.Contains('-O')
    ScanReflection = $responseLines.Contains('--scanreflection')
    MethodBodyFolding = @($responseLines | Where-Object { $_ -like '--methodbodyfolding:*' })
}

$summary = [pscustomobject] @{
    WallSeconds = $metadata.WallSeconds
    CpuSeconds = $metadata.CpuSeconds
    AverageLogicalCores = $metadata.AverageLogicalCores
    PeakWorkingSetGB = $metadata.PeakWorkingSetBytes / 1GB
    ObjectBytes = $metadata.ObjectBytes
    ControlWallSeconds = $ControlWallSeconds
    WallDeltaPercent = if ($ControlWallSeconds -gt 0)
    {
        100 * ($metadata.WallSeconds - $ControlWallSeconds) / $ControlWallSeconds
    }
    else
    {
        $null
    }
    Phases = $phaseRows
    Counters = $counterRows
    MethodSummary = $methodSummary
    WorkerSummary = $workerSummary
    Response = $responseSummary
    Coff = Get-CoffCardinality $metadata.ObjectPath
    TopAssemblies = @($assemblyRows | Select-Object -First 20)
}
$summary |
    ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $runRoot 'analysis.json') -Encoding utf8
$summary
