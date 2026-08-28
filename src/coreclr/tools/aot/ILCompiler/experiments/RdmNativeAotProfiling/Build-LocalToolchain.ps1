[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RuntimeRoot,

    [ValidatePattern('^[A-Z]$')]
    [string] $DriveLetter = 'N',

    [switch] $ApplyProfilePatch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runtimeRoot = (Resolve-Path -LiteralPath $RuntimeRoot).Path
$buildDrive = "${DriveLetter}:"
$profilePatch = Join-Path $PSScriptRoot 'ilc-v10.0.11-profile.patch'
$expectedCommit = '79d0c463f1b55624c874a11585f7e47731e8d675'
$actualCommit = (git -C $runtimeRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0)
{
    throw "Could not resolve the runtime commit at $runtimeRoot"
}

if ($ApplyProfilePatch)
{
    if ($actualCommit -ne $expectedCommit)
    {
        throw "The profile patch requires runtime $expectedCommit; found $actualCommit."
    }

    git -C $runtimeRoot apply --unidiff-zero --reverse --check $profilePatch 2>$null
    if ($LASTEXITCODE -ne 0)
    {
        git -C $runtimeRoot apply --unidiff-zero --check $profilePatch
        if ($LASTEXITCODE -ne 0)
        {
            throw 'The ILC profile patch cannot be applied cleanly.'
        }

        git -C $runtimeRoot apply --unidiff-zero $profilePatch
        if ($LASTEXITCODE -ne 0)
        {
            throw 'Applying the ILC profile patch failed.'
        }
    }
}

$environment = @{}
foreach ($name in @('PATH', 'INCLUDE', 'LIB', 'LIBPATH'))
{
    $environment[$name] = [pscustomobject] @{
        Exists = Test-Path "Env:$name"
        Value = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
}

if (Test-Path "$buildDrive\")
{
    throw "Drive $buildDrive is already in use."
}

$logPath = Join-Path $runtimeRoot 'artifacts\log\rdm-nativeaot-toolchain.log'
try
{
    & subst.exe $buildDrive $runtimeRoot
    if ($LASTEXITCODE -ne 0)
    {
        throw "Could not map $buildDrive to $runtimeRoot"
    }

    $env:PATH = @(
        "$buildDrive\.dotnet",
        'C:\Program Files\dotnet',
        'C:\Program Files\Git\cmd',
        'C:\Program Files\CMake\bin',
        'C:\Program Files (x86)\Microsoft Visual Studio\Installer',
        "$env:SystemRoot\System32",
        $env:SystemRoot,
        "$env:SystemRoot\System32\Wbem",
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0"
    ) -join ';'
    Remove-Item Env:INCLUDE, Env:LIB, Env:LIBPATH -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null
    Push-Location "$buildDrive\"
    try
    {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        & .\build.cmd clr.aot+libs -rc Release -lc Release *> $logPath
        $exitCode = $LASTEXITCODE
        $stopwatch.Stop()
    }
    finally
    {
        Pop-Location
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

    & subst.exe $buildDrive /d | Out-Null
}

[pscustomobject] @{
    ExitCode = $exitCode
    Elapsed = $stopwatch.Elapsed
    RuntimeCommit = $actualCommit
    IlcPath = Join-Path $runtimeRoot 'artifacts\bin\coreclr\windows.x64.Release\ilc\ilc.exe'
    LogPath = $logPath
}

exit $exitCode
