<#
.SYNOPSIS
    Data-source probe template (Windows PowerShell 5.1). Run it once per candidate source BEFORE building any feed.
.DESCRIPTION
    Copy, rename (Probe-<Source>.ps1) and fill in $Calls and $Keep for one candidate source. It:
      - makes a short, paced list of requests (keep it to about 15-25, one per second by default);
      - takes an API key, if the source needs one, from an environment variable or a hidden prompt. The key is never
        printed, never written to a file, and never put in a URL that gets printed;
      - writes only to .\probe-output\ (git-ignored, never committed, never in a release zip);
      - prints and saves only the fields listed in $Keep (a whitelist), so odds or betting fields never appear;
      - redacts account details: some sources return the account name or e-mail in a header or the body
        (football-data.org does both), so known account fields and headers are replaced with [REDACTED].
    Read the report it writes, check probe-output for anything personal, and only then share it.
    The findings go into the source report (see DATA-SOURCE-CHECK.md next to this script).
.EXAMPLE
    $env:PROBE_KEY = '<your key>'      # optional; or leave it unset and use -AskKey
    powershell -ExecutionPolicy Bypass -File .\Probe-Source.ps1
    powershell -ExecutionPolicy Bypass -File .\Probe-Source.ps1 -AskKey -DelayMs 1500
#>
[CmdletBinding()]
param(
    [int]$DelayMs = 1000,          # one request a second; slower if the source's terms ask for it
    [int]$MaxRequests = 25,
    [switch]$AskKey,               # prompt for the key without echoing it
    [string]$KeyEnv = 'PROBE_KEY',
    [string]$KeyHeader = ''        # e.g. 'X-Auth-Token' if the source takes the key in a header
)
$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---- fill these in -------------------------------------------------------------------------------------------
$Source = 'Example source'
$UA = 'SampleDash-Probe/0.1'        # say who you are; never your name or e-mail
$Calls = @(
    # Name                         Url (no key in it)
    @{ Name = 'competitions';      Url = 'https://example.invalid/v1/competitions' }
    @{ Name = 'fixtures-one-day';  Url = 'https://example.invalid/v1/matches?date=2026-11-07' }
)
# Fields to keep (dotted paths, * for "every item of a list"). Anything not listed is dropped before printing or saving.
$Keep = @('competitions.*.id', 'competitions.*.name', 'matches.*.id', 'matches.*.status', 'matches.*.homeTeam.name', 'matches.*.awayTeam.name', 'matches.*.score')
# Field names that are never kept even if a path above matches them (betting and account data).
$Never = @('odds', 'hasOdds', 'betting', 'lines', 'spread', 'overUnder', 'moneyline', 'account', 'user', 'email', 'name_of_account')
# Response headers that may carry account details; they are redacted in the report.
$AccountHeaders = @('X-Authenticated-Client', 'X-Account', 'X-User', 'X-Client-Name')
# ------------------------------------------------------------------------------------------------------------------

$base = $PSScriptRoot; if (-not $base) { $base = (Get-Location).Path }
$OutDir = Join-Path $base 'probe-output'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }

# The key lives only in this variable. It is never printed, logged or saved.
$key = [Environment]::GetEnvironmentVariable($KeyEnv)
if (-not $key -and $AskKey) {
    $sec = Read-Host -AsSecureString "Key for $Source (input hidden)"
    $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
function Hide-Secret([string]$Text) {
    if ($key -and $Text) { $Text = $Text.Replace($key, '[KEY]') }
    return $Text
}

function Select-Kept($Obj, [string]$Path) {
    # Keeps only whitelisted paths; drops anything in $Never at any depth.
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IList] -and $Obj -isnot [string]) {
        $p = if ($Path) { "$Path.*" } else { '*' }
        return , @($Obj | ForEach-Object { Select-Kept $_ $p } | Where-Object { $null -ne $_ })
    }
    if ($Obj -is [pscustomobject]) {
        $out = [ordered]@{}
        foreach ($prop in $Obj.PSObject.Properties) {
            if ($Never -contains $prop.Name) { continue }
            $p = if ($Path) { "$Path.$($prop.Name)" } else { $prop.Name }
            $wanted = $Keep | Where-Object { $_ -eq $p -or $_.StartsWith("$p.") }
            if ($wanted) { $v = Select-Kept $prop.Value $p; if ($null -ne $v) { $out[$prop.Name] = $v } }
        }
        if ($out.Count) { return [pscustomobject]$out } else { return $null }
    }
    if ($Keep -contains $Path) { return $Obj } else { return $null }
}

$rows = New-Object System.Collections.ArrayList
$n = 0
foreach ($c in $Calls) {
    if ($n -ge $MaxRequests) { Write-Host "Stopped at $MaxRequests requests."; break }
    $n++
    $headers = @{ 'User-Agent' = $UA; 'Accept' = 'application/json' }
    if ($key -and $KeyHeader) { $headers[$KeyHeader] = $key }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $row = [ordered]@{ Name = $c.Name; Status = 0; Ms = 0; Bytes = 0; Note = '' }
    try {
        $r = Invoke-WebRequest -Uri $c.Url -Headers $headers -UseBasicParsing -TimeoutSec 30
        $row.Status = [int]$r.StatusCode; $row.Bytes = $r.RawContentLength
        foreach ($hn in $AccountHeaders) { if ($r.Headers[$hn]) { $row.Note += "$hn=[REDACTED] " } }
        foreach ($hn in @('X-RateLimit-Limit', 'X-RateLimit-Remaining', 'X-Requests-Available-Minute', 'Retry-After', 'Cache-Control')) { if ($r.Headers[$hn]) { $row.Note += "$hn=$($r.Headers[$hn]) " } }
        $kept = Select-Kept ($r.Content | ConvertFrom-Json) ''
        $json = Hide-Secret (ConvertTo-Json -InputObject $kept -Depth 12)
        [IO.File]::WriteAllText((Join-Path $OutDir "$($c.Name).json"), $json, (New-Object Text.UTF8Encoding($false)))
    } catch {
        $row.Note = Hide-Secret $_.Exception.Message
        try { $row.Status = [int]$_.Exception.Response.StatusCode } catch { }
    }
    $row.Ms = $sw.ElapsedMilliseconds
    [void]$rows.Add([pscustomobject]$row)
    Write-Host ('{0,-24} {1,4} {2,7} ms {3,9} bytes {4}' -f $row.Name, $row.Status, $row.Ms, $row.Bytes, $row.Note)
    Start-Sleep -Milliseconds $DelayMs
}
$report = Join-Path $OutDir 'probe-report.csv'
$rows | Export-Csv -NoTypeInformation -Path $report
Write-Host ''
Write-Host "Saved $($rows.Count) results to $OutDir. Check them for anything personal before sharing; never commit this folder."
