<#
.SYNOPSIS
    Checks a dashboard folder against DashLauncher's dash contract, without opening a window or fetching anything.
.DESCRIPTION
    1. Checks dash.json (the same rules the launcher uses).
    2. Loads the backend module and checks it exports the eight required functions.
    3. Unless -SkipInit: calls Initialize-Dash with a test context, then Get-DashStatus, Receive-DashEvents,
       Suspend-DashWorker, Stop-DashTraffic and Stop-Dash, and checks what they return. Start-DashWorker is never
       called, so the dash's worker does not run and nothing is fetched. Initialize-Dash creates the dash's usual
       settings and cache folders, as running the dash would, and the dash must be closed (it takes its host lock).
.EXAMPLE
    powershell -File tools\Test-DashContract.ps1 -Path modules\NBADash
#>
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$SkipInit
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'core\Launcher.Manifest.psm1') -Force
$script:Fail = 0
function Pass { param([string]$Text) Write-Host "  ok    $Text" -ForegroundColor Green }
function Fail { param([string]$Text) $script:Fail++; Write-Host "  FAIL  $Text" -ForegroundColor Red }
function Note { param([string]$Text) Write-Host "  note  $Text" -ForegroundColor Yellow }

$folder = (Resolve-Path -LiteralPath $Path).ProviderPath
Write-Host "Dash contract check: $folder"

# 1. manifest
$info = Read-DashManifest -Folder $folder
if (-not $info.Ok) { Fail "dash.json: $($info.Reason)"; exit 1 }
Pass ("dash.json: {0} ({1}) v{2}, contract {3}" -f $info.Title, $info.Id, $info.Version, $info.Contract)
if (-not @($info.DataSources).Count) { Note 'dash.json lists no dataSources. Fine for a dash that contacts nothing; otherwise list every third-party source and its terms.' }

# 2. backend exports
$required = @('Initialize-Dash', 'Start-DashWorker', 'Suspend-DashWorker', 'Invoke-DashCommand', 'Receive-DashEvents', 'Get-DashStatus', 'Stop-DashTraffic', 'Stop-Dash')
try {
    $mods = @(Import-Module -Name $info.Paths['backend'] -PassThru -Force -DisableNameChecking)
    $mod = $mods | Where-Object { $_.Path -eq $info.Paths['backend'] } | Select-Object -First 1
    if (-not $mod) { $mod = $mods[0] }
} catch { Fail "backend did not load: $($_.Exception.Message)"; exit 1 }
$missing = @($required | Where-Object { -not $mod.ExportedCommands[$_] })
if ($missing.Count) { Fail ("backend is missing: " + ($missing -join ', ')) } else { Pass 'backend exports all 8 required functions' }
if ($mod.ExportedCommands['Invoke-DashSync']) { Pass 'backend exports the optional Invoke-DashSync' } else { Note 'no Invoke-DashSync (optional; the master sync would skip this dash)' }
$text = [IO.File]::ReadAllText($info.Paths['backend'])
if ($text -match 'Microsoft\.Web\.WebView2|Windows\.Forms\.Form\b') { Fail 'backend mentions WebView2 or creates a Form; only the host may do that' } else { Pass 'backend creates no window and does not load WebView2' }
$nonAscii = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Include *.ps1, *.psm1, *.bat -ErrorAction SilentlyContinue | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '[^\x00-\x7F]' })
if ($nonAscii.Count) { Fail ('non-ASCII characters in: ' + (($nonAscii | ForEach-Object { $_.Name }) -join ', ')) } else { Pass 'scripts are ASCII-only' }
if ($missing.Count -or $SkipInit) { Write-Host ("Done: {0} problem(s)." -f $script:Fail); exit ([int]($script:Fail -gt 0)) }

# 3. lifecycle without the worker
$posted = New-Object System.Collections.Generic.List[string]
$sink = $posted
$ctx = [pscustomobject]@{
    Mode = 'launcher'; Root = $folder
    Post = { param([string]$Json) $sink.Add($Json) }.GetNewClosure()
    Close = { }; Relaunch = '"C:\DashLauncher\Start-DashLauncher.bat" -Open ' + $info.Id
    HostPid = $PID; Theme = 'system'; LauncherVersion = '0.0.0-test'; Debug = $false
}
$call = { param([string]$Name, [hashtable]$P = @{}) $c = $mod.ExportedCommands[$Name]; & $c @P }
$initOk = $false
try {
    $init = & $call 'Initialize-Dash' @{ Context = $ctx }
    if (-not $init) { Fail 'Initialize-Dash returned nothing' }
    elseif (-not $init.Ok -and [string]$init.Reason -eq 'locked') { Fail 'Initialize-Dash says locked: close the dash (and DashLauncher) and run this again'; exit 1 }
    elseif (-not $init.Ok) { Fail "Initialize-Dash failed: $($init.Reason)" }
    else {
        $initOk = $true
        $bad = @('CacheDir', 'WebViewDataDir' | Where-Object { -not ($init.$_ -is [string]) -or -not $init.$_ })
        if ($bad.Count) { Fail ('Initialize-Dash did not return ' + ($bad -join ', ')) } else { Pass "Initialize-Dash: cache $($init.CacheDir)" }
        $again = & $call 'Initialize-Dash' @{ Context = $ctx }
        if ($again -and $again.Ok) { Pass 'Initialize-Dash can be called twice' } else { Note 'a second Initialize-Dash call did not return Ok' }
    }
} catch { Fail "Initialize-Dash threw: $($_.Exception.Message)" }

if ($initOk) {
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $s = & $call 'Get-DashStatus'
        $ms = $sw.ElapsedMilliseconds
        $keys = @('Live', 'Syncing', 'SyncPct', 'UpdateAvailable', 'Error', 'Traffic')
        $have = if ($s -is [hashtable]) { @($s.Keys) } else { @($s.PSObject.Properties.Name) }
        $miss = @($keys | Where-Object { $have -notcontains $_ })
        if ($miss.Count) { Fail ('Get-DashStatus is missing: ' + ($miss -join ', ')) } else { Pass "Get-DashStatus returns all keys ($ms ms)" }
        if ($s.Traffic -and $null -ne $s.Traffic.Requests -and $null -ne $s.Traffic.Bytes -and $null -ne $s.Traffic.Errors) { Pass 'Traffic has Requests, Bytes, Errors' } else { Fail 'Traffic must be @{ Requests; Bytes; Errors }' }
        if ($ms -gt 200) { Note 'Get-DashStatus took over 200 ms; it runs on the UI thread every 2 seconds' }
    } catch { Fail "Get-DashStatus threw: $($_.Exception.Message)" }
    try {
        $ev = @(& $call 'Receive-DashEvents')
        $nonString = @($ev | Where-Object { $_ -isnot [string] })
        if ($nonString.Count) { Fail 'Receive-DashEvents must return JSON strings' } elseif ($ev.Count -gt 25) { Fail 'Receive-DashEvents returned more than 25 items' } else { Pass "Receive-DashEvents returned $($ev.Count) message(s)" }
    } catch { Fail "Receive-DashEvents threw: $($_.Exception.Message)" }
    try {
        $r = @(& $call 'Invoke-DashCommand' @{ Message = [pscustomobject]@{ id = 999; cmd = 'no.such.command'; args = [pscustomobject]@{} } })
        $reply = @($posted | Where-Object { $_ -match '"id"\s*:\s*999' })
        if ($reply.Count -and $reply[0] -match '"ok"\s*:\s*false') { Pass 'an unknown command gets an error reply through Context.Post' } else { Fail 'an unknown command should be answered with {id, ok:false, error} through Context.Post' }
    } catch { Fail "Invoke-DashCommand threw on an unknown command: $($_.Exception.Message)" }
    foreach ($fn in 'Suspend-DashWorker', 'Stop-DashTraffic') {
        try { & $call $fn | Out-Null; Pass "$fn ran" } catch { Fail "$fn threw: $($_.Exception.Message)" }
    }
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $call 'Stop-Dash' | Out-Null
        if ($sw.ElapsedMilliseconds -gt 2500) { Fail "Stop-Dash took $($sw.ElapsedMilliseconds) ms (limit 2 s)" } else { Pass 'Stop-Dash ran within 2 seconds' }
    } catch { Fail "Stop-Dash threw: $($_.Exception.Message)" }
    try {
        $again = & $call 'Initialize-Dash' @{ Context = $ctx }
        if ($again -and $again.Ok) { Pass 'the host lock was released (initialized again after Stop-Dash)'; & $call 'Stop-Dash' | Out-Null }
        else { Fail 'could not initialize again after Stop-Dash: the host lock may not be released' }
    } catch { Fail "re-initialize after Stop-Dash threw: $($_.Exception.Message)" }
}
Write-Host ("Done: {0} problem(s)." -f $script:Fail)
exit ([int]($script:Fail -gt 0))
