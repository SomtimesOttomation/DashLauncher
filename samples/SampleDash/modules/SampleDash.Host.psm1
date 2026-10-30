<#
.SYNOPSIS
    Sample dash backend for DashLauncher contract version 1. Contacts nothing: its "servers" are made up.
.DESCRIPTION
    Windows PowerShell 5.1. The starting point for a new dash, built the way NBADash and NHLDash are, with the data
    source swapped for a fake one:

      - The page asks for data by key ("score:2026-10-29", "week:2026-10-26", "team:AUR", "standings"). Keys are checked
        against a fixed list here, never turned into URLs by the page.
      - A worker runspace "downloads" each key one at a time from pretend servers (*.sample.invalid; the .invalid name
        can never reach the internet), waits a little like a real request, saves a copy in the cache folder and queues
        the JSON for the page. Receive-DashEvents hands it over. Traffic is counted per server, with the last 40 requests.
      - A season sync queues one request per week and reports real progress to the page and to the launcher's rail.
      - Settings live in %APPDATA%\SampleDash, cache and WebView2 profile in %LOCALAPPDATA%\SampleDash: never inside
        the dash's own folder, so an update (from the dash or from DashLauncher) never wipes them.
      - The updater (Update-SampleDash.ps1 + Apply-Update.ps1) is the same as NHLDash's. It only talks to GitHub, and only
        when the person clicks the version or turns "check on start" on (off by default in the Sample).

    Sample tools (Settings page): pretend live games, an update or a problem for the launcher's tab badges, and pretend
    that downloads fail, to see the failed-request rule (a failed item waits for Refresh).

    To start a real dash: replace Invoke-FakeServer in the worker with real downloads (Get-Bytes in NHLDash), list the
    real sources in dash.json, and rename SampleDash / sample everywhere (see README.md).
#>

$script:Ctx = $null
$script:Root = Split-Path $PSScriptRoot
$script:Mutex = $null
$script:Version = '0.0.0'
$script:CacheDir = ''
$script:WebViewDataDir = ''
$script:SettingsFile = ''
$script:Settings = $null
$script:Visible = $false
$script:Watch = @()
$script:NextAuto = [datetime]::MaxValue
$script:SyncKeys = $null
$script:SyncTotal = 1
$script:LastSyncPct = -1
$script:Shared = $null
$script:Queue = $null
$script:Out = $null
$script:Worker = $null
$script:WorkerHandle = $null
# Sample tools: in-memory only
$script:Pretend = @{ Live = 0; Update = $false; Problem = $false }

# The made-up league. A real dash gets its teams from its data source.
$script:TeamCodes = @('AUR', 'BAY', 'CED', 'DUN', 'EMB', 'FOX', 'GLA', 'HAR', 'IRO', 'JUN', 'KES', 'LAN')

function New-DefaultSettings {
    return [ordered]@{ theme = 'system'; autoRefresh = $false; autoAck = $false; refreshSeconds = 60; favorites = @(); updateCheck = $false }
}

# ---------------------------------------------------------------- page messages
function Send-Page {
    param([string]$Json)
    try { if ($script:Ctx -and $script:Ctx.Post) { & $script:Ctx.Post $Json } } catch { }
}
function Reply { param($Id, [string]$DataJson = 'null') Send-Page ('{{"id":{0},"ok":true,"data":{1}}}' -f [int]$Id, $DataJson) }
function ReplyError { param($Id, [string]$Message) Send-Page ('{{"id":{0},"ok":false,"error":{1}}}' -f [int]$Id, (ConvertTo-Json -InputObject $Message -Compress)) }
function ConvertTo-PageJson { param($Object) return (ConvertTo-Json -InputObject $Object -Depth 6 -Compress) }

# ---------------------------------------------------------------- settings
function Read-Settings {
    $s = New-DefaultSettings
    try {
        if (Test-Path $script:SettingsFile) {
            $j = [IO.File]::ReadAllText($script:SettingsFile) | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = $j.$k } }
        }
    } catch { }
    $s.autoRefresh = [bool]$s.autoRefresh; $s.autoAck = [bool]$s.autoAck; $s.updateCheck = [bool]$s.updateCheck
    $s.refreshSeconds = Limit-Seconds $s.refreshSeconds
    if (@('system', 'light', 'dark') -notcontains [string]$s.theme) { $s.theme = 'system' }
    $s.favorites = Limit-Teams $s.favorites
    return $s
}
function Save-Settings {
    try { [IO.File]::WriteAllText($script:SettingsFile, (ConvertTo-Json -InputObject $script:Settings -Compress)) } catch { }
}
function Limit-Teams {
    # Several favourites, in the order they were starred; only known team codes.
    param($Value)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($t in @($Value)) { $v = [string]$t; if ($script:TeamCodes -ccontains $v -and -not $out.Contains($v)) { $out.Add($v) } }
    return , $out.ToArray()
}
function Limit-Seconds { param($Value) $n = 60; try { $n = [int]$Value } catch { }; return [Math]::Max(20, [Math]::Min(600, $n)) }

# ---------------------------------------------------------------- data keys
function Get-SeasonStart {
    # The pretend season always started on the Monday six weeks ago, so the Sample has a few weeks to show.
    $d = (Get-Date).Date.AddDays(-42)
    while ($d.DayOfWeek -ne 'Monday') { $d = $d.AddDays(-1) }
    return $d
}
function Get-SeasonWeeks {
    $d = Get-SeasonStart
    $list = @()
    while ($d -le (Get-Date).Date) { $list += $d.ToString('yyyy-MM-dd'); $d = $d.AddDays(7) }
    return , $list
}

function Resolve-DataKey {
    <# Turns a page key into a request spec, or $null if the key is not allowed. The page never supplies a URL. #>
    param([string]$Key)
    $k = [string]$Key
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($k -match '^score:(\d{4}-\d{2}-\d{2})$') {
        $ttl = if ($Matches[1] -lt $today) { 3600 } else { 15 }
        return @{ Key = $k; Url = 'https://scores.sample.invalid/day/' + $Matches[1]; File = "score-$($Matches[1]).json"; Ttl = $ttl }
    }
    if ($k -match '^week:(\d{4}-\d{2}-\d{2})$') {
        $d = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        if ($d.DayOfWeek -ne 'Monday') { return $null }
        $ttl = if ($d.AddDays(8) -lt (Get-Date).Date) { 2592000 } else { 600 }     # finished weeks never change
        return @{ Key = $k; Url = 'https://scores.sample.invalid/week/' + $Matches[1]; File = "week-$($Matches[1]).json"; Ttl = $ttl }
    }
    if ($k -cmatch '^team:([A-Z]{3})$' -and $script:TeamCodes -ccontains $Matches[1]) {
        return @{ Key = $k; Url = 'https://teams.sample.invalid/team/' + $Matches[1]; File = "team-$($Matches[1]).json"; Ttl = 1800 }
    }
    if ($k -eq 'standings') { return @{ Key = $k; Url = 'https://scores.sample.invalid/standings'; File = 'standings.json'; Ttl = 600 } }
    return $null
}

function Get-CacheAge {
    param([string]$File)
    $p = Join-Path $script:CacheDir $File
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    return ((Get-Date) - (Get-Item -LiteralPath $p).LastWriteTime).TotalSeconds
}

function New-DataEvent {
    <# The page event from a cached file. #>
    param($Spec, [bool]$FromCache)
    $p = Join-Path $script:CacheDir $Spec.File
    $at = (Get-Item -LiteralPath $p).LastWriteTimeUtc.ToString('o')
    return ('{{"event":"data","data":{{"key":{0},"ok":true,"cached":{1},"at":"{2}","body":' -f (ConvertTo-Json $Spec.Key), $FromCache.ToString().ToLower(), $at) + [IO.File]::ReadAllText($p) + '}}'
}

function Request-Data {
    <# Answers from the cache when it is fresh enough, otherwise queues a download. Returns 'cached', 'queued' or 'busy'. #>
    param($Spec, [bool]$Force)
    $age = Get-CacheAge $Spec.File
    if (-not $Force -and $null -ne $age -and $age -lt $Spec.Ttl) {
        try { $script:Out.Enqueue((New-DataEvent $Spec $true)); return 'cached' } catch { }
    }
    if ($script:Shared.Pending.ContainsKey($Spec.Key)) { return 'busy' }
    $script:Shared.Pending[$Spec.Key] = $true
    $item = @{} + $Spec
    $item.Gen = $script:Shared.Gen
    $script:Queue.Add($item)
    return 'queued'
}

# ---------------------------------------------------------------- worker runspace
$script:WorkerScript = {
    param($Shared, $Queue, $Out, $CacheDir, $TeamCodes)
    $utf8 = New-Object Text.UTF8Encoding($false)

    # ---- the pretend servers. A real dash downloads here instead (NHLDash: Get-Bytes with HttpWebRequest). ----
    function Get-Seed([string]$Text) { $h = 17; foreach ($c in $Text.ToCharArray()) { $h = ($h * 31 + [int]$c) % 2147483647 }; return [int]$h }
    function Get-DayGames([datetime]$Day) {
        $rng = New-Object Random (Get-Seed $Day.ToString('yyyy-MM-dd'))
        $codes = @($TeamCodes | Sort-Object { $rng.Next() })
        $n = 3 + $rng.Next(3)
        $now = Get-Date
        $isToday = $Day.Date -eq $now.Date
        $games = @()
        for ($i = 0; $i -lt $n; $i++) {
            $aw = $codes[2 * $i]; $hm = $codes[2 * $i + 1]
            # today: one finished, one live, the rest later; other days: evening starts
            $start = if ($isToday) { @($now.AddHours(-3), $now.AddMinutes(-40), $now.AddHours($i))[[Math]::Min($i, 2)] } else { $Day.Date.AddHours(18 + $i).AddMinutes(30 * ($i % 2)) }
            $g = [ordered]@{ id = $Day.ToString('yyyyMMdd') + $i; start = $start.ToUniversalTime().ToString('o'); away = @{ code = $aw; score = $null; shots = $null }; home = @{ code = $hm; score = $null; shots = $null }; state = 'FUT'; clock = ''; ot = $false; venue = "$hm Arena" }
            $a = $rng.Next(6); $h = $rng.Next(6)
            if ($a -eq $h) { $h++; $g.ot = $true }
            $minutes = ($now - $start).TotalMinutes
            if ($Day.Date -lt $now.Date -or ($isToday -and $minutes -ge 150)) { $g.state = 'FINAL' }
            elseif ($isToday -and $minutes -ge 0) {
                $g.state = 'LIVE'; $part = [Math]::Min(3, 1 + [int][Math]::Floor($minutes / 45)); $g.clock = 'P{0} {1:00}:{2:00}' -f $part, (19 - [int]($minutes % 20)), $rng.Next(60)
                $a = [int][Math]::Floor($a * $minutes / 150); $h = [int][Math]::Floor($h * $minutes / 150); $g.ot = $false
            }
            if ($g.state -ne 'FUT') { $g.away.score = $a; $g.home.score = $h; $g.away.shots = 18 + $rng.Next(20); $g.home.shots = 18 + $rng.Next(20) }
            $games += $g
        }
        return , $games
    }
    function ConvertTo-Events($Games) {
        # NBADash's event shape, so the page code is NBADash's: state pre/in/post, sides with side, abbr and score.
        $out = foreach ($g in $Games) {
            $st = switch ($g.state) { 'LIVE' { 'in' } 'FINAL' { 'post' } default { 'pre' } }
            $period = 0; $clock = ''
            if ($g.state -eq 'LIVE' -and $g.clock -match '^P(\d) (.+)$') { $period = [int]$Matches[1]; $clock = $Matches[2] }
            if ($g.state -eq 'FINAL') { $period = $(if ($g.ot) { 4 } else { 3 }) }
            [ordered]@{ id = $g.id; state = $st; date = $g.start; period = $period; clock = $clock; detail = ''; venue = $g.venue
                        sides = @(@{ side = 'away'; abbr = $g.away.code; score = $(if ($null -ne $g.away.score) { [string]$g.away.score } else { $null }); leaders = @() },
                                  @{ side = 'home'; abbr = $g.home.code; score = $(if ($null -ne $g.home.score) { [string]$g.home.score } else { $null }); leaders = @() }) }
        }
        return , @($out)
    }
    function Get-Standings {
        $rec = @{}
        foreach ($c in $TeamCodes) { $rec[$c] = [ordered]@{ code = $c; gp = 0; w = 0; l = 0; otl = 0; pts = 0; gf = 0; ga = 0; last10 = @() } }
        $d = (Get-Date).Date.AddDays(-42); while ($d.DayOfWeek -ne 'Monday') { $d = $d.AddDays(-1) }
        while ($d -lt (Get-Date).Date) {
            foreach ($g in (Get-DayGames $d)) {
                foreach ($side in @(@($g.away, $g.home), @($g.home, $g.away))) {
                    $me = $side[0]; $op = $side[1]; $r = $rec[$me.code]
                    $r.gp++; $r.gf += $me.score; $r.ga += $op.score
                    if ($me.score -gt $op.score) { $r.w++; $r.pts += 2; $r.last10 += 'W' } elseif ($g.ot) { $r.otl++; $r.pts++; $r.last10 += 'O' } else { $r.l++; $r.last10 += 'L' }
                }
            }
            $d = $d.AddDays(1)
        }
        $list = foreach ($r in $rec.Values) {
            $l10 = @($r.last10 | Select-Object -Last 10)
            $r.l10 = '{0}-{1}-{2}' -f @($l10 | Where-Object { $_ -eq 'W' }).Count, @($l10 | Where-Object { $_ -eq 'L' }).Count, @($l10 | Where-Object { $_ -eq 'O' }).Count
            $r.Remove('last10')
            [pscustomobject]$r
        }
        return @{ teams = @($list | Sort-Object @{ Expression = 'pts'; Descending = $true }, @{ Expression = { $_.gf - $_.ga }; Descending = $true }) }
    }
    function Get-Team([string]$Code) {
        $rng = New-Object Random (Get-Seed $Code)
        $first = 'Alex', 'Sam', 'Jordan', 'Riley', 'Casey', 'Morgan', 'Jamie', 'Taylor', 'Drew', 'Quinn', 'Avery', 'Rowan', 'Emery', 'Parker'
        $last = 'Hale', 'Moreau', 'Lindqvist', 'Okafor', 'Brandt', 'Castell', 'Rook', 'Vance', 'Pike', 'Ferro', 'Holm', 'Sato', 'Weller', 'Dunmore'
        $players = for ($i = 0; $i -lt 12; $i++) {
            $gp = 10 + $rng.Next(8); $gl = $rng.Next(9); $as = $rng.Next(12)
            [ordered]@{ id = '{0}{1:00}' -f $Code, $i; name = '{0} {1}' -f $first[$rng.Next($first.Count)], $last[$rng.Next($last.Count)]; pos = @('F', 'F', 'D')[$i % 3]
                        gp = $gp; g = $gl; a = $as; pts = $gl + $as; pm = $rng.Next(15) - 7; sog = $gl * 4 + $rng.Next(25) }
        }
        return @{ code = $Code; players = @($players | Sort-Object { -$_.pts }) }
    }
    function Invoke-FakeServer($Item) {
        Start-Sleep -Milliseconds (120 + (Get-Random -Maximum 260))        # like a real request
        if ($Shared.FailDownloads) { throw 'Pretend download failure (Sample tools on the Settings page).' }
        $k = $Item.Key
        $body = if ($k -match '^score:(.+)$') { $d = [datetime]$Matches[1]; @{ date = $d.ToString('yyyyMMdd'); events = (ConvertTo-Events (Get-DayGames $d)) } }
                elseif ($k -match '^week:(.+)$') { $m = [datetime]$Matches[1]; @{ monday = $Matches[1]; days = @(0..6 | ForEach-Object { $d = $m.AddDays($_); @{ date = $d.ToString('yyyyMMdd'); events = (ConvertTo-Events (Get-DayGames $d)) } }) } }
                elseif ($k -match '^team:(.+)$') { Get-Team $Matches[1] }
                else { Get-Standings }
        return (ConvertTo-Json -InputObject $body -Depth 8 -Compress)
    }

    while (-not $Shared.Quit) {
        $item = $null
        if (-not $Queue.TryTake([ref]$item, 500)) { continue }
        try {
            if ($Shared.Halted -or $item.Gen -ne $Shared.Gen -or $Shared.Skip.ContainsKey($item.Key)) { continue }
            $Shared.Requests++
            $hostName = ([uri]$item.Url).Host
            $kind = ($item.Key -split ':')[0]
            if (-not $Shared.ByHost.ContainsKey($hostName)) { $Shared.ByHost[$hostName] = @{ requests = 0; bytes = [long]0; errors = 0 } }
            if (-not $Shared.ByKind.ContainsKey($kind)) { $Shared.ByKind[$kind] = @{ requests = 0; bytes = [long]0 } }
            $hs = $Shared.ByHost[$hostName]; $hs.requests++; $Shared.ByKind[$kind].requests++
            $t0 = Get-Date
            $text = Invoke-FakeServer $item
            $len = $utf8.GetByteCount($text)
            $Shared.Bytes += $len; $hs.bytes += $len; $Shared.ByKind[$kind].bytes += $len
            [void]$Shared.Last.Insert(0, @{ at = $t0.ToString('o'); key = $item.Key; host = $hostName; bytes = $len; ms = [int]((Get-Date) - $t0).TotalMilliseconds; ok = $true })
            while ($Shared.Last.Count -gt 40) { $Shared.Last.RemoveAt(40) }
            if ($Shared.Halted -or $item.Gen -ne $Shared.Gen) { continue }
            [IO.File]::WriteAllText((Join-Path $CacheDir $item.File), $text, $utf8)
            if ($item.Key -eq $Shared.TodayKey) { $Shared.Live = ([regex]::Matches($text, '"state":"in"')).Count }
            $head = '{{"event":"data","data":{{"key":"{0}","ok":true,"cached":false,"at":"{1}","body":' -f $item.Key, [datetime]::UtcNow.ToString('o')
            $Out.Enqueue($head + $text + '}}')
            $Shared.LastError = $null
        } catch {
            if ($item.Gen -eq $Shared.Gen -and -not $Shared.Halted) {
                $Shared.Errors++
                try { $hn = ([uri]$item.Url).Host; if ($Shared.ByHost.ContainsKey($hn)) { $Shared.ByHost[$hn].errors++ }; [void]$Shared.Last.Insert(0, @{ at = (Get-Date).ToString('o'); key = $item.Key; host = $hn; bytes = 0; ms = 0; ok = $false }) } catch { }
                $msg = $_.Exception.Message
                $Shared.LastError = $msg
                $Out.Enqueue('{"event":"data","data":{"key":' + (ConvertTo-Json $item.Key) + ',"ok":false,"error":' + (ConvertTo-Json -InputObject ([string]$msg) -Compress) + '}}')
            }
        } finally {
            if ($item) { $Shared.Pending.Remove($item.Key) }
        }
    }
}

function Start-WorkerRunspace {
    if ($script:Worker) { return }
    $ps = [PowerShell]::Create()
    $ps.Runspace = [RunspaceFactory]::CreateRunspace()
    $ps.Runspace.Open()
    [void]$ps.AddScript($script:WorkerScript).AddArgument($script:Shared).AddArgument($script:Queue).AddArgument($script:Out).AddArgument($script:CacheDir).AddArgument($script:TeamCodes)
    $script:WorkerHandle = $ps.BeginInvoke()
    $script:Worker = $ps
}

function Clear-Queue {
    $x = $null
    while ($script:Queue.TryTake([ref]$x)) { }
    $script:Shared.Pending.Clear()
}

function Get-Snapshot {
    return @{
        mode = [string]$script:Ctx.Mode; version = $script:Version; theme = [string]$script:Ctx.Theme
        launcherVersion = [string]$script:Ctx.LauncherVersion
        halted = [bool]$script:Shared.Halted; live = [int]$script:Shared.Live + $script:Pretend.Live
        error = $(if ($script:Pretend.Problem) { 'Pretend problem from the Sample dash.' } else { $script:Shared.LastError })
        settings = $script:Settings
        pretend = @{ live = $script:Pretend.Live; update = $script:Pretend.Update; problem = $script:Pretend.Problem; fail = [bool]$script:Shared.FailDownloads }
        today = (Get-Date).ToString('yyyy-MM-dd')
        traffic = @{ requests = [int]$script:Shared.Requests; bytes = [long]$script:Shared.Bytes; errors = [int]$script:Shared.Errors }
    }
}

function Reset-AutoTimer {
    if ($script:Settings.autoRefresh -and $script:Visible -and -not $script:Shared.Halted) {
        $script:NextAuto = (Get-Date).AddSeconds($script:Settings.refreshSeconds)
    } else { $script:NextAuto = [datetime]::MaxValue }
}

# ---------------------------------------------------------------- updater (child process, same as NBADash and NHLDash)
$script:UpdDir = ''
$script:UpdProc = $null
$script:UpdAction = ''
$script:LastUpdJson = ''
$script:UpdateAvailable = $null
$script:UpdateNote = $null
$script:UpdOut = ''

function Get-ChildProgress {
    # Reads a child's console output: the last ##PROGRESS marker.
    param([string]$Path)
    $r = @{ pct = 0; text = '' }
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object IO.StreamReader($fs)
        while (($l = $sr.ReadLine()) -ne $null) {
            if ($l.Trim() -match '^##PROGRESS (\d+)\|(.*)$') { $r.pct = [int]$Matches[1]; $r.text = $Matches[2] }
        }
        $sr.Close(); $fs.Close()
    } catch { }
    return $r
}
function Read-UpdateJson {
    param([string]$Name)
    $p = Join-Path $script:UpdDir $Name
    if (Test-Path $p) { try { return ([IO.File]::ReadAllText($p) | ConvertFrom-Json) } catch { } }
    return $null
}
function Start-Updater {
    <# Update checks talk to GitHub only, so the pause switch leaves them alone. #>
    param([string]$Action)
    if ($script:UpdProc -and -not $script:UpdProc.HasExited) { return $false }
    $cur = if ($env:SAMPLEDASH_FAKE_VERSION) { $env:SAMPLEDASH_FAKE_VERSION } else { $script:Version }     # test hook: pretend to be older
    Remove-Item (Join-Path $script:UpdDir 'update-result.json') -Force -ErrorAction SilentlyContinue
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $script:Root 'Update-SampleDash.ps1')),
                  '-Action', $Action, '-CurrentVersion', $cur, '-WorkDir', ('"{0}"' -f $script:UpdDir))
    if ($env:SAMPLEDASH_UPDATE_API) { $argsList += '-ApiBase'; $argsList += $env:SAMPLEDASH_UPDATE_API }   # test hook
    $exe = if ($env:SAMPLEDASH_PS) { $env:SAMPLEDASH_PS } else { 'powershell.exe' }                         # test hook
    $script:UpdAction = $Action
    $sp = @{ FilePath = $exe; ArgumentList = $argsList; PassThru = $true; RedirectStandardOutput = $script:UpdOut }
    if ($IsWindows -ne $false) { $sp.WindowStyle = 'Hidden' }       # $IsWindows is $null in Windows PowerShell 5.1
    $script:UpdProc = Start-Process @sp
    $script:LastUpdJson = ''
    $script:Out.Enqueue((ConvertTo-PageJson @{ event = 'update'; data = @{ running = $true; action = $Action; pct = 0; text = 'Starting...' } }))
    return $true
}
function Get-UpdateEvents {
    $list = @()
    if (-not $script:UpdProc) { return $list }
    if ($script:UpdProc.HasExited) {
        $res = Read-UpdateJson 'update-result.json'
        if (-not $res) { $res = [pscustomobject]@{ status = 'error'; error = 'The update check ended without an answer.' } }
        $script:UpdProc = $null
        if ([string]$res.status -eq 'available' -or [string]$res.status -eq 'staged') { $script:UpdateAvailable = [string]$res.latest }
        elseif ([string]$res.status -eq 'current') { $script:UpdateAvailable = $null }
        $list += (ConvertTo-Json -InputObject @{ event = 'update'; data = @{ running = $false; action = $script:UpdAction; result = $res } } -Depth 6 -Compress)
    } else {
        $prog = Get-ChildProgress $script:UpdOut
        $json = ConvertTo-PageJson @{ event = 'update'; data = @{ running = $true; action = $script:UpdAction; pct = $prog.pct; text = $prog.text } }
        if ($json -ne $script:LastUpdJson) { $script:LastUpdJson = $json; $list += $json }
    }
    return $list
}

# ---------------------------------------------------------------- contract functions
function Initialize-Dash {
    <# Takes the host lock, loads settings and makes folders. Fetches nothing. #>
    param([Parameter(Mandatory)]$Context)
    if ($script:Ctx) { return @{ Ok = $true; Reason = ''; CacheDir = $script:CacheDir; WebViewDataDir = $script:WebViewDataDir } }
    $created = $false
    try { $m = New-Object System.Threading.Mutex($true, 'Local\DashHost-sample', [ref]$created) } catch { $m = $null }
    if (-not $m -or -not $created) {
        if ($m) { $m.Dispose() }
        return @{ Ok = $false; Reason = 'locked'; CacheDir = ''; WebViewDataDir = '' }
    }
    $script:Mutex = $m
    $script:Ctx = $Context
    if ($Context.Root) { $script:Root = [string]$Context.Root }
    try { $script:Version = ([IO.File]::ReadAllText((Join-Path $script:Root 'VERSION'))).Trim() } catch { }
    $local = Join-Path $env:LOCALAPPDATA 'SampleDash'
    $roam = Join-Path $env:APPDATA 'SampleDash'
    $script:CacheDir = Join-Path $local 'cache'
    $script:WebViewDataDir = Join-Path $local 'webview2'
    foreach ($d in @($script:CacheDir, $script:WebViewDataDir, $roam)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    $script:SettingsFile = Join-Path $roam 'settings.json'
    $script:UpdDir = Join-Path $local 'update'
    if (-not (Test-Path $script:UpdDir)) { New-Item -ItemType Directory -Path $script:UpdDir -Force | Out-Null }
    $script:UpdOut = Join-Path $script:UpdDir 'update.out'
    # After an update the helper leaves a "pending" note: report the result once; the page load confirms it worked.
    $script:UpdateNote = $null
    $pend = Read-UpdateJson 'update-pending.json'
    if ($pend -and [string]$pend.to -eq $script:Version) { $script:UpdateNote = @{ ok = $true; from = [string]$pend.from; to = [string]$pend.to } }
    $failed = Read-UpdateJson 'update-failed.json'
    if ($failed) {
        $script:UpdateNote = @{ ok = $false; from = [string]$failed.from; to = [string]$failed.to; reason = [string]$failed.reason }
        Remove-Item (Join-Path $script:UpdDir 'update-failed.json') -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:UpdDir 'update-pending.json') -Force -ErrorAction SilentlyContinue
    }
    $script:Settings = Read-Settings
    $script:Pretend = @{ Live = 0; Update = $false; Problem = $false }
    $script:Shared = [hashtable]::Synchronized(@{
        Quit = $false; Halted = $false; Gen = 0; Live = 0; Requests = 0; Bytes = [long]0; Errors = 0; LastError = $null; FailDownloads = $false
        Pending = [hashtable]::Synchronized(@{}); Skip = [hashtable]::Synchronized(@{}); ByHost = [hashtable]::Synchronized(@{}); ByKind = [hashtable]::Synchronized(@{})
        Last = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)); Started = Get-Date; TodayKey = 'score:' + (Get-Date).ToString('yyyy-MM-dd')
    })
    $script:Queue = New-Object 'System.Collections.Concurrent.BlockingCollection[object]'
    $script:Out = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:Visible = $false
    $script:Watch = @()
    $script:SyncKeys = $null
    return @{ Ok = $true; Reason = ''; CacheDir = $script:CacheDir; WebViewDataDir = $script:WebViewDataDir }
}

function Start-DashWorker {
    <# Visible: the worker runs (it only ever fetches what was asked for); automatic refresh resumes if it is on. #>
    if (-not $script:Shared) { return }
    $script:Visible = $true
    if ($script:Shared.Halted) { return }
    Start-WorkerRunspace
    Reset-AutoTimer
}

function Suspend-DashWorker {
    <# Hidden: no timed refresh. Requests already queued (and a running sync) finish. #>
    if (-not $script:Shared) { return }
    $script:Visible = $false
    $script:NextAuto = [datetime]::MaxValue
}

function Invoke-DashCommand {
    param([Parameter(Mandatory)]$Message)
    $id = $Message.id
    $a = $Message.args
    try {
        switch ([string]$Message.cmd) {
            'init' {
                $snap = Get-Snapshot
                $snap.updateNote = $script:UpdateNote
                $snap.teams = $script:TeamCodes
                Reply $id (ConvertTo-PageJson $snap)
                if ($script:UpdateNote -and $script:UpdateNote.ok) {
                    # the page loaded: tell the update helper the new version works
                    try { [IO.File]::WriteAllText((Join-Path $script:UpdDir 'update-ok.json'), '{"ok":true}') } catch { }
                    Remove-Item (Join-Path $script:UpdDir 'update-pending.json') -Force -ErrorAction SilentlyContinue
                }
                $script:UpdateNote = $null
            }
            'update.check' { Reply $id ((Start-Updater 'Check').ToString().ToLower()) }
            'update.stage' { Reply $id ((Start-Updater 'Stage').ToString().ToLower()) }
            'update.cancel' {
                try { if ($script:UpdProc -and -not $script:UpdProc.HasExited) { $script:UpdProc.Kill() } } catch { }
                Reply $id 'true'
            }
            'update.apply' {
                $st = Read-UpdateJson 'staged.json'
                $stage = Join-Path $script:UpdDir 'stage'
                if (-not $st -or -not (Test-Path (Join-Path $stage 'Start-SampleDash.ps1'))) { ReplyError $id 'There is no downloaded update to install. Download it again.'; return }
                # run the helper from a copy so replacing the app files cannot touch the running helper
                $runDir = Join-Path $script:UpdDir 'run'
                if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }
                $helper = Join-Path $runDir 'Apply-Update.ps1'
                Copy-Item (Join-Path $script:Root 'Apply-Update.ps1') $helper -Force
                # Context.Relaunch is passed through exactly as given (it may include arguments, e.g. -Open sample)
                $relaunch = if ($script:Ctx.Relaunch) { [string]$script:Ctx.Relaunch } else { '"' + (Join-Path $script:Root 'Start-SampleDash.bat') + '"' }
                $relaunchB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($relaunch))
                $hostPid = if ($script:Ctx.HostPid) { [int]$script:Ctx.HostPid } else { $PID }
                $h = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $helper), '-AppDir', ('"{0}"' -f $script:Root), '-StageDir', ('"{0}"' -f $stage),
                       '-WorkDir', ('"{0}"' -f $script:UpdDir), '-ParentPid', [string]$hostPid, '-RelaunchB64', $relaunchB64,
                       '-OldVersion', $script:Version, '-NewVersion', [string]$st.version)
                Start-Process -FilePath 'powershell.exe' -ArgumentList $h -WindowStyle Hidden | Out-Null
                Reply $id 'true'
                if ($script:Ctx.Close) { & $script:Ctx.Close }
            }
            'data.get' {
                $spec = Resolve-DataKey ([string]$a.key)
                if (-not $spec) { ReplyError $id 'unknown data key'; return }
                if ($script:Shared.Halted) {
                    # Paused: saved copies still show, nothing is fetched.
                    if ($null -ne (Get-CacheAge $spec.File)) { $script:Out.Enqueue((New-DataEvent $spec $true)); Reply $id '"cached"' }
                    else { ReplyError $id 'Data traffic is paused.' }
                    return
                }
                if ([bool]$a.cacheOnly) {
                    if ($null -ne (Get-CacheAge $spec.File)) { $script:Out.Enqueue((New-DataEvent $spec $true)); Reply $id '"cached"' } else { Reply $id '"missing"' }
                    return
                }
                Start-WorkerRunspace
                Reply $id (ConvertTo-Json (Request-Data $spec ([bool]$a.force)))
            }
            'watch.set' {
                # what the opt-in refresh timer may refetch: at most 6 keys the open page shows
                $keys = @()
                foreach ($k in @($a.keys)) { if ($k -and (Resolve-DataKey ([string]$k))) { $keys += [string]$k } }
                $script:Watch = @($keys | Select-Object -First 6)
                Reply $id 'true'
            }
            'settings.set' {
                $s = $script:Settings
                switch ([string]$a.key) {
                    'autoRefresh' {
                        $on = [bool]$a.value
                        if ($on -and -not [bool]$a.ack -and -not $s.autoAck) { ReplyError $id 'Automatic refresh needs the warning acknowledged.'; return }
                        $s.autoRefresh = $on; if ($on) { $s.autoAck = $true }
                    }
                    'refreshSeconds' { $s.refreshSeconds = Limit-Seconds $a.value }
                    'favorites' { $s.favorites = Limit-Teams $a.value }
                    'updateCheck' { $s.updateCheck = [bool]$a.value }
                    'theme' { if (@('system', 'light', 'dark') -contains [string]$a.value) { $s.theme = [string]$a.value } }
                    default { ReplyError $id 'unknown setting'; return }
                }
                Save-Settings
                Reset-AutoTimer
                Reply $id (ConvertTo-PageJson (Get-Snapshot))
            }
            'sample.set' {
                # Sample tools: pretend states for the launcher's tab badges, and pretend download failures
                switch ([string]$a.key) {
                    'live' { $n = 0; try { $n = [int]$a.value } catch { }; $script:Pretend.Live = [Math]::Max(0, [Math]::Min(15, $n)) }
                    'update' { $script:Pretend.Update = [bool]$a.value }
                    'problem' { $script:Pretend.Problem = [bool]$a.value }
                    'fail' { $script:Shared.FailDownloads = [bool]$a.value }
                    default { ReplyError $id 'unknown setting'; return }
                }
                Reply $id (ConvertTo-PageJson (Get-Snapshot))
            }
            'season.weeks' {
                $weeks = foreach ($w in (Get-SeasonWeeks)) { @{ monday = $w; cached = ($null -ne (Get-CacheAge "week-$w.json")) } }
                Reply $id (ConvertTo-Json -InputObject @($weeks) -Compress)
            }
            'sync.run' {
                if ($script:Shared.Halted) { ReplyError $id 'Data traffic is paused. Resume first.'; return }
                if ($script:SyncKeys) { Reply $id 'false'; return }
                Start-WorkerRunspace
                $script:Shared.Skip.Clear()
                $weeks = Get-SeasonWeeks
                $keys = @()
                for ($i = 0; $i -lt $weeks.Count; $i++) {
                    $spec = Resolve-DataKey ('week:' + $weeks[$i])
                    $r = Request-Data $spec ($i -eq $weeks.Count - 1)     # finished weeks come from the cache when saved
                    if ($r -ne 'cached') { $keys += $spec.Key }
                }
                if ((Request-Data (Resolve-DataKey 'standings') $true) -ne 'cached') { $keys += 'standings' }
                $script:SyncKeys = $keys
                $script:SyncTotal = [Math]::Max(1, $keys.Count)
                $script:LastSyncPct = -1
                Reply $id (ConvertTo-Json @{ started = $true; requests = $keys.Count; weeks = $weeks.Count } -Compress)
            }
            'sync.cancel' {
                if ($script:SyncKeys) { foreach ($k in $script:SyncKeys) { $script:Shared.Skip[$k] = $true } }
                Reply $id 'true'
            }
            'traffic.get' {
                $s = $script:Shared
                $hosts = @{}
                foreach ($h in @($s.ByHost.Keys)) { $hosts[$h] = $s.ByHost[$h] }
                $kinds = @{}
                foreach ($k in @($s.ByKind.Keys)) { $kinds[$k] = $s.ByKind[$k] }
                $list = @($s.Last.ToArray())
                $lastText = $(if ($list.Count) { '{0} ({1})' -f $list[0].key, ([datetime]$list[0].at).ToString('T') } else { '' })
                # NBADash's fields (bytes, byKind, last) plus per-server counts and the last 40 requests
                $obj = @{ uptimeSec = [int]((Get-Date) - $s.Started).TotalSeconds; requests = [int]$s.Requests; bytes = [long]$s.Bytes; wireBytes = [long]$s.Bytes; errors = [int]$s.Errors
                          byKind = $kinds; byHost = $hosts; last = $lastText; lastList = $list }
                Reply $id (ConvertTo-Json -InputObject $obj -Depth 5 -Compress)
            }
            'cache.clear' {
                Get-ChildItem -LiteralPath $script:CacheDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '\.json$' } | Remove-Item -Force -ErrorAction SilentlyContinue
                Reply $id 'true'
            }
            'traffic.stop' {
                Stop-DashTraffic
                Reply $id (ConvertTo-PageJson (Get-Snapshot))
            }
            'traffic.resume' {
                $script:Shared.Halted = $false
                $script:Shared.LastError = $null
                if ($script:Visible) { Start-WorkerRunspace }
                Reset-AutoTimer
                Send-Page '{"event":"traffic","data":{"stopped":false}}'
                Reply $id (ConvertTo-PageJson (Get-Snapshot))
            }
            default { ReplyError $id ('unknown command: ' + [string]$Message.cmd) }
        }
    } catch { ReplyError $id $_.Exception.Message }
}

function Receive-DashEvents {
    <# Every 250 ms: runs the opt-in refresh timer and drains up to 25 worker messages. #>
    if (-not $script:Shared) { return @() }
    $now = Get-Date
    $script:Shared.TodayKey = 'score:' + $now.ToString('yyyy-MM-dd')
    if ($now -ge $script:NextAuto) {
        if ($script:Visible -and $script:Settings.autoRefresh -and -not $script:Shared.Halted) {
            foreach ($k in $script:Watch) { $spec = Resolve-DataKey $k; if ($spec) { [void](Request-Data $spec $true) } }
        }
        Reset-AutoTimer
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($u in @(Get-UpdateEvents)) { if ($u) { $out.Add($u) } }
    if ($script:SyncKeys) {
        $left = @($script:SyncKeys | Where-Object { $script:Shared.Pending.ContainsKey($_) }).Count
        $pct = [int](100 * ($script:SyncTotal - $left) / $script:SyncTotal)
        if ($left -eq 0) { $script:SyncKeys = $null; $out.Add(('{{"event":"sync","data":{{"running":false,"pct":100,"exitCode":0,"summary":"{0} requests","lastRun":"{1}"}}}}' -f $script:SyncTotal, (Get-Date).ToString('o'))) }
        elseif ($pct -ne $script:LastSyncPct) { $script:LastSyncPct = $pct; $out.Add(('{{"event":"sync","data":{{"running":true,"pct":{0},"text":"Downloading {1} of {2}"}}}}' -f $pct, ($script:SyncTotal - $left), $script:SyncTotal)) }
    }
    $msg = $null
    while ($out.Count -lt 25 -and $script:Out.TryDequeue([ref]$msg)) { $out.Add($msg) }
    return $out.ToArray()       # unrolled: the caller gets one JSON string per item (wrap in @() for 0 or 1)
}

function Get-DashStatus {
    <# Every 2 seconds: no network, no disk. #>
    $s = $script:Shared
    if (-not $s) { return @{ Live = 0; Syncing = $false; SyncPct = $null; UpdateAvailable = $null; Error = $null; Traffic = @{ Requests = 0; Bytes = 0; Errors = 0 } } }
    $syncing = $false
    $syncPct = $null
    if ($script:SyncKeys) {
        $left = @($script:SyncKeys | Where-Object { $s.Pending.ContainsKey($_) }).Count
        if ($left -gt 0) { $syncing = $true; $syncPct = [int](100 * ($script:SyncTotal - $left) / $script:SyncTotal) }
    }
    return @{
        Live            = $(if ($s.Halted) { 0 } else { [int]$s.Live + $script:Pretend.Live })
        Syncing         = $syncing
        SyncPct         = $syncPct
        UpdateAvailable = $(if ($script:Pretend.Update) { '9.9.9' } else { $script:UpdateAvailable })
        Error           = $(if ($script:Pretend.Problem) { 'Pretend problem from the Sample dash.' } elseif ($s.Halted) { $null } else { $s.LastError })
        Traffic         = @{ Requests = [int]$s.Requests; Bytes = [long]$s.Bytes; Errors = [int]$s.Errors }
    }
}

function Stop-DashTraffic {
    <# Kill switch: drop queued requests, ignore the one in flight, stop the refresh timer. Settings are not changed. #>
    if (-not $script:Shared) { return }
    $script:Shared.Halted = $true
    $script:Shared.Gen++
    Clear-Queue
    if ($script:SyncKeys) { $script:Out.Enqueue('{"event":"sync","data":{"running":false,"pct":0,"cancelled":true}}') }
    $script:SyncKeys = $null
    $script:NextAuto = [datetime]::MaxValue
    Send-Page '{"event":"traffic","data":{"stopped":true}}'
}

function Stop-Dash {
    <# Closing: stop the worker and release the host lock within 2 seconds. #>
    try {
        if ($script:Shared) { $script:Shared.Quit = $true; $script:Shared.Gen++ }
        if ($script:Worker) {
            if (-not $script:WorkerHandle.AsyncWaitHandle.WaitOne(1200)) { try { $script:Worker.Stop() } catch { } }
            $script:Worker.Runspace.Dispose(); $script:Worker.Dispose()
        }
    } catch { }
    $script:Worker = $null; $script:WorkerHandle = $null
    try { if ($script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch { }
    $script:Mutex = $null
    $script:Ctx = $null
    $script:Shared = $null
}

function Invoke-DashSync {
    <# Optional (master sync, switched off in the launcher for now): today's scores and the standings. #>
    param([ValidateSet('quick')][string]$Scope = 'quick')
    if (-not $script:Shared -or $script:Shared.Halted) { return $false }
    if ($script:SyncKeys) { return $false }
    Start-WorkerRunspace
    $keys = @('score:' + (Get-Date).ToString('yyyy-MM-dd'), 'standings')
    foreach ($k in $keys) { [void](Request-Data (Resolve-DataKey $k) $true) }
    $script:SyncKeys = $keys
    $script:SyncTotal = $keys.Count
    $script:LastSyncPct = -1
    return $true
}

Export-ModuleMember -Function Initialize-Dash, Start-DashWorker, Suspend-DashWorker, Invoke-DashCommand, Receive-DashEvents, Get-DashStatus, Stop-DashTraffic, Stop-Dash, Invoke-DashSync
