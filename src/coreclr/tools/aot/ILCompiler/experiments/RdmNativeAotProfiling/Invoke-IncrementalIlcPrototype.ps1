[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $IlcPath,

    [Parameter(Mandatory)]
    [string] $BaseResponseFile,

    [Parameter(Mandatory)]
    [string] $UpdatedResponseFile,

    [Parameter(Mandatory)]
    [string] $BaseAssembly,

    [Parameter(Mandatory)]
    [string] $UpdatedAssembly,

    [Parameter(Mandatory)]
    [string] $WorkingDirectory,

    [Parameter(Mandatory)]
    [string] $RunRoot,

    [string[]] $Experiments = @(),

    [int] $MinimumFreeMemoryGiB = 0,

    [int] $MaximumCpuLoadPercent = 100,

    [int] $GuardSampleCount = 3,

    [int] $GuardSampleIntervalSeconds = 5,

    [int] $GuardTimeoutSeconds = 1800,

    [switch] $AllowUnsafeBodyShapesForTesting,

    [switch] $SkipCleanValidation,

    [switch] $FastObjectPatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($AllowUnsafeBodyShapesForTesting -and $SkipCleanValidation)
{
    throw '-AllowUnsafeBodyShapesForTesting requires clean differential validation.'
}

$ilcPath = (Resolve-Path -LiteralPath $IlcPath).Path
$baseResponseFile = (Resolve-Path -LiteralPath $BaseResponseFile).Path
$updatedResponseFile = (Resolve-Path -LiteralPath $UpdatedResponseFile).Path
$baseAssembly = (Resolve-Path -LiteralPath $BaseAssembly).Path
$updatedAssembly = (Resolve-Path -LiteralPath $UpdatedAssembly).Path
$workingDirectory = (Resolve-Path -LiteralPath $WorkingDirectory).Path
$runRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (Test-Path -LiteralPath $runRoot)
{
    throw "Run root already exists: $runRoot"
}

$profileScript = Join-Path $PSScriptRoot 'Invoke-IlcProfile.ps1'
$pwsh = (Get-Command pwsh).Source
$attemptRoot = Join-Path $runRoot 'incremental-attempt'
$fallbackRoot = Join-Path $runRoot 'clean-fallback'
$validationRoot = Join-Path $runRoot 'clean-validation'
$incrementalObject = Join-Path $attemptRoot 'incremental-output.obj'
$incrementalStatus = Join-Path $attemptRoot 'incremental-status.txt'
$environmentNames = @(
    'DOTNET_ILC_INCREMENTAL_REEMIT_PATH',
    'DOTNET_ILC_INCREMENTAL_BASE_ASSEMBLY',
    'DOTNET_ILC_INCREMENTAL_UPDATED_ASSEMBLY',
    'DOTNET_ILC_INCREMENTAL_STATUS_PATH',
    'DOTNET_ILC_INCREMENTAL_CANDIDATES_PATH',
    'DOTNET_ILC_INCREMENTAL_ALLOW_UNSAFE_BODY_SHAPES',
    'DOTNET_ILC_INCREMENTAL_FAST_OBJECT_PATCH',
    'DOTNET_ILC_INCREMENTAL_BASE_ASSEMBLY_2',
    'DOTNET_ILC_INCREMENTAL_REEMIT_PATH_2',
    'DOTNET_ILC_INCREMENTAL_UPDATED_ASSEMBLY_2',
    'DOTNET_ILC_INCREMENTAL_FORCE_GC_BETWEEN_UPDATES'
)
$environment = @{}
foreach ($name in $environmentNames)
{
    $environment[$name] = [pscustomobject] @{
        Exists = Test-Path "Env:$name"
        Value = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
}

function Get-NormalizedResponse
{
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $outputPrefixes = @(
        '-o:',
        '--out:',
        '--dgmllog:',
        '--exportsfile:',
        '--ildump:',
        '--map:',
        '--metadatalog:',
        '--mstat:',
        '--scandgmllog:',
        '--sourcelink:'
    )
    $result = foreach ($line in Get-Content -LiteralPath $Path)
    {
        $normalizedLine = $line.Replace(
            $baseAssembly,
            '<changed-assembly>',
            [StringComparison]::OrdinalIgnoreCase)
        $normalizedLine = $normalizedLine.Replace(
            $updatedAssembly,
            '<changed-assembly>',
            [StringComparison]::OrdinalIgnoreCase)
        foreach ($prefix in $outputPrefixes)
        {
            if ($normalizedLine.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))
            {
                $normalizedLine = "$prefix<output>"
                break
            }
        }
        $normalizedLine
    }

    return [string]::Join("`n", $result)
}

function Invoke-ProfileProcess
{
    param(
        [Parameter(Mandatory)]
        [string] $ResponseFile,

        [Parameter(Mandatory)]
        [string] $ProfileRunRoot,

        [Parameter(Mandatory)]
        [string] $ConsoleLog
    )

    $arguments = @(
        '-NoProfile',
        '-File', $profileScript,
        '-IlcPath', $ilcPath,
        '-ResponseFile', $ResponseFile,
        '-WorkingDirectory', $workingDirectory,
        '-RunRoot', $ProfileRunRoot,
        '-MinimumFreeMemoryGiB', $MinimumFreeMemoryGiB,
        '-MaximumCpuLoadPercent', $MaximumCpuLoadPercent,
        '-GuardSampleCount', $GuardSampleCount,
        '-GuardSampleIntervalSeconds', $GuardSampleIntervalSeconds,
        '-GuardTimeoutSeconds', $GuardTimeoutSeconds
    )
    if ($Experiments.Count -gt 0)
    {
        $arguments += @('-Experiments', ($Experiments -join ','))
    }

    & $pwsh @arguments *> $ConsoleLog
    return $LASTEXITCODE
}

function Clear-IncrementalEnvironment
{
    foreach ($name in $environmentNames)
    {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
}

$normalizedBaseResponse = Get-NormalizedResponse -Path $baseResponseFile
$normalizedUpdatedResponse = Get-NormalizedResponse -Path $updatedResponseFile
$baseResponseText = Get-Content -LiteralPath $baseResponseFile -Raw
$updatedResponseText = Get-Content -LiteralPath $updatedResponseFile -Raw
if (!$baseResponseText.Contains(
    $baseAssembly,
    [StringComparison]::OrdinalIgnoreCase))
{
    throw 'Base response does not reference the base assembly.'
}
if (!$updatedResponseText.Contains(
    $updatedAssembly,
    [StringComparison]::OrdinalIgnoreCase))
{
    throw 'Updated response does not reference the updated assembly.'
}

$responseFallbackReason = if ($normalizedBaseResponse -ne $normalizedUpdatedResponse)
{
    'response-semantics-changed'
}
else
{
    $null
}

New-Item -ItemType Directory -Path $runRoot | Out-Null

try
{
    $status = @{}
    $validationExitCode = $null
    $validationObject = $null
    $validationObjectSha256 = $null
    $incrementalObjectSha256 = $null
    $cleanValidationMatched = $null
    if ($responseFallbackReason)
    {
        $status['result'] = 'fallback'
        $status['reason'] = $responseFallbackReason
        $status['changed-method-definitions'] = '0'
        $status['recompiled-code-nodes'] = '0'
        $attemptExitCode = $null
    }
    else
    {
        Clear-IncrementalEnvironment
        $env:DOTNET_ILC_INCREMENTAL_REEMIT_PATH = $incrementalObject
        $env:DOTNET_ILC_INCREMENTAL_BASE_ASSEMBLY = $baseAssembly
        $env:DOTNET_ILC_INCREMENTAL_UPDATED_ASSEMBLY = $updatedAssembly
        $env:DOTNET_ILC_INCREMENTAL_STATUS_PATH = $incrementalStatus
        if ($AllowUnsafeBodyShapesForTesting)
        {
            $env:DOTNET_ILC_INCREMENTAL_ALLOW_UNSAFE_BODY_SHAPES = '1'
        }
        else
        {
            Remove-Item Env:DOTNET_ILC_INCREMENTAL_ALLOW_UNSAFE_BODY_SHAPES -ErrorAction SilentlyContinue
        }
        if ($FastObjectPatch)
        {
            $env:DOTNET_ILC_INCREMENTAL_FAST_OBJECT_PATCH = '1'
        }
        else
        {
            Remove-Item Env:DOTNET_ILC_INCREMENTAL_FAST_OBJECT_PATCH -ErrorAction SilentlyContinue
        }

        $attemptExitCode = Invoke-ProfileProcess `
            -ResponseFile $baseResponseFile `
            -ProfileRunRoot $attemptRoot `
            -ConsoleLog (Join-Path $runRoot 'incremental-attempt.console.log')

        if (Test-Path -LiteralPath $incrementalStatus)
        {
            foreach ($line in Get-Content -LiteralPath $incrementalStatus)
            {
                $separator = $line.IndexOf('=')
                if ($separator -ge 0)
                {
                    $status[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
                }
            }
        }
    }

    if ($responseFallbackReason)
    {
        Clear-IncrementalEnvironment

        $fallbackExitCode = Invoke-ProfileProcess `
            -ResponseFile $updatedResponseFile `
            -ProfileRunRoot $fallbackRoot `
            -ConsoleLog (Join-Path $runRoot 'clean-fallback.console.log')
        if ($fallbackExitCode -ne 0)
        {
            throw "Clean fallback failed with exit code $fallbackExitCode."
        }

        $result = 'clean-fallback'
        $resultObject = Join-Path $fallbackRoot 'output.obj'
    }
    elseif ($attemptExitCode -eq 0)
    {
        if ($status['result'] -ne 'success' -or -not (Test-Path -LiteralPath $incrementalObject))
        {
            throw 'Incremental ILC exited successfully without a valid success status and output.'
        }

        $result = 'incremental-hit'
        $resultObject = $incrementalObject
        $fallbackExitCode = $null
        if (!$SkipCleanValidation)
        {
            Clear-IncrementalEnvironment
            $validationExitCode = Invoke-ProfileProcess `
                -ResponseFile $updatedResponseFile `
                -ProfileRunRoot $validationRoot `
                -ConsoleLog (Join-Path $runRoot 'clean-validation.console.log')
            if ($validationExitCode -ne 0)
            {
                throw "Clean validation failed with exit code $validationExitCode."
            }

            $validationObject = Join-Path $validationRoot 'output.obj'
            $incrementalObjectLength = (Get-Item $incrementalObject).Length
            $validationObjectLength = (Get-Item $validationObject).Length
            $incrementalObjectSha256 = (Get-FileHash $incrementalObject -Algorithm SHA256).Hash
            $validationObjectSha256 = (Get-FileHash $validationObject -Algorithm SHA256).Hash
            $cleanValidationMatched =
                $incrementalObjectLength -eq $validationObjectLength -and
                $incrementalObjectSha256 -eq $validationObjectSha256
            if (!$cleanValidationMatched)
            {
                throw (
                    'Incremental output does not match the clean updated compilation. ' +
                    "Incremental: $incrementalObjectLength bytes/$incrementalObjectSha256; " +
                    "clean: $validationObjectLength bytes/$validationObjectSha256.")
            }
        }
    }
    elseif ($status['result'] -eq 'fallback')
    {
        Clear-IncrementalEnvironment

        $fallbackExitCode = Invoke-ProfileProcess `
            -ResponseFile $updatedResponseFile `
            -ProfileRunRoot $fallbackRoot `
            -ConsoleLog (Join-Path $runRoot 'clean-fallback.console.log')
        if ($fallbackExitCode -ne 0)
        {
            throw "Clean fallback failed with exit code $fallbackExitCode."
        }

        $result = 'clean-fallback'
        $resultObject = Join-Path $fallbackRoot 'output.obj'
    }
    else
    {
        throw "Incremental ILC failed without an explicit fallback status. Exit code: $attemptExitCode."
    }

    $attemptProfilePath = Join-Path $attemptRoot 'ilc-profile.csv'
    $attemptProfile = if (Test-Path -LiteralPath $attemptProfilePath)
    {
        @(Import-Csv -LiteralPath $attemptProfilePath)
    }
    else
    {
        @()
    }
    $attemptMetadataPath = Join-Path $attemptRoot 'run-metadata.json'
    $attemptMetadata = if (Test-Path -LiteralPath $attemptMetadataPath)
    {
        Get-Content -LiteralPath $attemptMetadataPath | ConvertFrom-Json
    }
    else
    {
        $null
    }
    $fallbackMetadataPath = Join-Path $fallbackRoot 'run-metadata.json'
    $fallbackMetadata = if (Test-Path -LiteralPath $fallbackMetadataPath)
    {
        Get-Content -LiteralPath $fallbackMetadataPath | ConvertFrom-Json
    }
    else
    {
        $null
    }
    $validationMetadataPath = Join-Path $validationRoot 'run-metadata.json'
    $validationMetadata = if (Test-Path -LiteralPath $validationMetadataPath)
    {
        Get-Content -LiteralPath $validationMetadataPath | ConvertFrom-Json
    }
    else
    {
        $null
    }
    $resultObjectSha256 = if ($resultObject -eq $incrementalObject -and $incrementalObjectSha256)
    {
        $incrementalObjectSha256
    }
    else
    {
        (Get-FileHash $resultObject -Algorithm SHA256).Hash
    }

    $metadata = [pscustomobject] @{
        Result = $result
        FallbackReason = $status['reason']
        AttemptExitCode = $attemptExitCode
        FallbackExitCode = $fallbackExitCode
        BaseAssembly = $baseAssembly
        BaseAssemblySha256 = (Get-FileHash $baseAssembly -Algorithm SHA256).Hash
        UpdatedAssembly = $updatedAssembly
        UpdatedAssemblySha256 = (Get-FileHash $updatedAssembly -Algorithm SHA256).Hash
        ResultObject = $resultObject
        ResultObjectBytes = (Get-Item $resultObject).Length
        ResultObjectSha256 = $resultObjectSha256
        CleanValidationSkipped = if ($result -eq 'incremental-hit') { [bool]$SkipCleanValidation } else { $null }
        CleanValidationExitCode = $validationExitCode
        CleanValidationWallMilliseconds = if ($validationMetadata) { $validationMetadata.WallSeconds * 1000 } else { $null }
        CleanValidationObject = $validationObject
        CleanValidationObjectSha256 = $validationObjectSha256
        CleanValidationMatched = $cleanValidationMatched
        ChangedMethodDefinitions = $status['changed-method-definitions']
        RecompiledCodeNodes = $status['recompiled-code-nodes']
        AttemptWallMilliseconds = if ($attemptMetadata) { $attemptMetadata.WallSeconds * 1000 } else { $null }
        FallbackWallMilliseconds = if ($fallbackMetadata) { $fallbackMetadata.WallSeconds * 1000 } else { $null }
        IncrementalUpdateMilliseconds = (
            $attemptProfile |
                Where-Object { $_.kind -eq 'phase' -and $_.name -eq 'incremental-update-total' } |
                Select-Object -ExpandProperty totalMilliseconds -First 1
        )
        IncrementalShapeValidationMilliseconds = (
            $attemptProfile |
                Where-Object { $_.kind -eq 'phase' -and $_.name -eq 'incremental-shape-validation' } |
                Select-Object -ExpandProperty totalMilliseconds -First 1
        )
        IncrementalChangedNodeSelectionMilliseconds = (
            $attemptProfile |
                Where-Object { $_.kind -eq 'phase' -and $_.name -eq 'incremental-select-changed-nodes' } |
                Select-Object -ExpandProperty totalMilliseconds -First 1
        )
        IncrementalCodegenMilliseconds = (
            $attemptProfile |
                Where-Object { $_.kind -eq 'phase' -and $_.name -eq 'incremental-method-codegen' } |
                Select-Object -ExpandProperty totalMilliseconds -First 1
        )
        IncrementalValidationMilliseconds = (
            $attemptProfile |
                Where-Object { $_.kind -eq 'phase' -and $_.name -eq 'incremental-validate-codegen' } |
                Select-Object -ExpandProperty totalMilliseconds -First 1
        )
        IncrementalReemitMilliseconds = (
            $attemptProfile |
                Where-Object { $_.kind -eq 'phase' -and $_.name -eq 'incremental-reemit-object' } |
                Select-Object -ExpandProperty totalMilliseconds -First 1
        )
        IncrementalObjectPatchMilliseconds = (
            $attemptProfile |
                Where-Object { $_.kind -eq 'phase' -and $_.name -eq 'incremental-patch-object' } |
                Select-Object -ExpandProperty totalMilliseconds -First 1
        )
        IncrementalPatchedObjectBytes = (
            $attemptProfile |
                Where-Object { $_.kind -eq 'counter' -and $_.name -eq 'incremental-patched-object-bytes' } |
                Select-Object -ExpandProperty value -First 1
        )
        IncrementalAllocatedBytes = (
            $attemptProfile |
                Where-Object { $_.kind -eq 'counter' -and $_.name -eq 'incremental-allocated-bytes' } |
                Select-Object -ExpandProperty value -First 1
        )
    }
    $metadata |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath (Join-Path $runRoot 'incremental-result.json') -Encoding utf8
    $metadata
}
finally
{
    foreach ($name in $environmentNames)
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
