[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $RdmRoot,

    [Parameter(Mandatory)]
    [string] $RuntimeRoot,

    [Parameter(Mandatory)]
    [string] $RunRoot,

    [string] $DotnetPath = 'C:\Program Files\dotnet\dotnet.exe'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$rdmRoot = (Resolve-Path -LiteralPath $RdmRoot).Path
$runtimeRoot = (Resolve-Path -LiteralPath $RuntimeRoot).Path
$runRoot = [System.IO.Path]::GetFullPath($RunRoot)
if (Test-Path $runRoot)
{
    throw "Run root already exists: $runRoot"
}

$project = Join-Path $rdmRoot 'Windows\RemoteDesktopManager\Program\RemoteDesktopManager.csproj'
$coreClr = Join-Path $runtimeRoot 'artifacts\bin\coreclr\windows.x64.Release'
$runtimePack = Join-Path $runtimeRoot 'artifacts\bin\microsoft.netcore.app.runtime.win-x64\Release\runtimes\win-x64'
$directoryBuildProps = Join-Path $PSScriptRoot 'RdmProfile.Directory.Build.props'
$properties = @(
    "-p:DirectoryBuildPropsPath=$directoryBuildProps",
    "-p:NativeAotProfileRoot=$runRoot",
    '-p:RdmNativeAotFast=true',
    '-p:IlcGenerateDgmlFile=false',
    '-p:IlcGenerateMstatFile=false',
    "-p:IlcToolsPath=$coreClr\ilc/",
    "-p:IlcSdkPath=$coreClr\aotsdk/",
    "-p:IlcFrameworkPath=$runtimePack\lib\net10.0/",
    "-p:IlcFrameworkNativePath=$runtimePack\native/"
)

New-Item -ItemType Directory -Path $runRoot | Out-Null
$environment = @{}
foreach ($name in @('DOTNET_ROOT', 'DOTNET_MULTILEVEL_LOOKUP'))
{
    $environment[$name] = [pscustomobject] @{
        Exists = Test-Path "Env:$name"
        Value = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
}

try
{
    $env:DOTNET_ROOT = Split-Path -Parent $DotnetPath
    $env:DOTNET_MULTILEVEL_LOOKUP = '0'

    Push-Location $rdmRoot
    try
    {
        $restoreLog = Join-Path $runRoot 'restore.log'
        & $DotnetPath restore $project -r win-x64 -v:minimal @properties *> $restoreLog
        if ($LASTEXITCODE -ne 0)
        {
            throw 'RDM restore failed.'
        }

        $arguments = @(
            'publish',
            $project,
            '-f',
            'net10.0-windows10.0.19041',
            '-c',
            'Debug',
            '-r',
            'win-x64',
            '--no-restore',
            '--nologo',
            '-m',
            '-v:minimal',
            '-o',
            (Join-Path $runRoot 'publish'),
            "/bl:$(Join-Path $runRoot 'publish.binlog')"
        ) + $properties

        @{
            FilePath = $DotnetPath
            WorkingDirectory = $rdmRoot
            Arguments = $arguments
        } | ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath (Join-Path $runRoot 'publish-command.json') -Encoding utf8

        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        & $DotnetPath @arguments *> (Join-Path $runRoot 'publish.log')
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
}

$responses = @(Get-ChildItem -LiteralPath $runRoot -Recurse -File -Filter '*.ilc.rsp')
[pscustomobject] @{
    ExitCode = $exitCode
    Elapsed = $stopwatch.Elapsed
    Binlog = Join-Path $runRoot 'publish.binlog'
    IlcResponseFiles = @($responses.FullName)
    PublishDirectory = Join-Path $runRoot 'publish'
}

exit $exitCode
