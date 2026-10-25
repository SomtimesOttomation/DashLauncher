<#
.SYNOPSIS
    DashLauncher: one window with sports dashboards as tabs on the left side.
.DESCRIPTION
    Windows PowerShell 5.1 + WebView2. Finds dashboard modules in its modules folder (each has a dash.json) at start and
    when "Scan for modules" is pressed. Modules listed in catalog.json that are published on GitHub but not installed
    show as greyed tabs with a download link. It asks before loading a module that is not in the catalog, and hosts each in its own WebView2 through the dash contract (DASH-CONTRACT.md). Only the visible
    dashboard's worker runs; hidden ones are suspended. The launcher itself fetches nothing.
.PARAMETER Open
    Id of the dashboard to open first (used after a dashboard update relaunches the launcher).
.PARAMETER Debug
    Enables DevTools and context menus in every view.
#>
param(
    [string]$Open = '',
    [switch]$Debug
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Version = '0.0.0'
try { $Version = ([IO.File]::ReadAllText((Join-Path $Root 'VERSION'))).Trim() } catch { }
if ($Open -cnotmatch '^[a-z][a-z0-9]{1,19}$') { $Open = '' }

# WinForms + WebView2 need a single-threaded apartment.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $relaunch = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Open) { $relaunch += @('-Open', $Open) }
    if ($Debug) { $relaunch += '-Debug' }
    & powershell.exe @relaunch
    exit $LASTEXITCODE
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$AppName = 'DashLauncher'

# ---------------------------------------------------------------- WebView2 assemblies
$lib = Join-Path $Root 'lib'
$need = 'Microsoft.Web.WebView2.Core.dll', 'Microsoft.Web.WebView2.WinForms.dll', 'WebView2Loader.dll'
$missing = @($need | Where-Object { -not (Test-Path (Join-Path $lib $_)) })
if ($missing.Count) {
    [Windows.Forms.MessageBox]::Show("Missing WebView2 files in $lib :`n`n$($missing -join "`n")`n`nRun Setup-WebView2.ps1 once.", $AppName, 'OK', 'Warning') | Out-Null
    exit 1
}
Add-Type -Namespace DashLauncher -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetDllDirectory(string path);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsIconic(System.IntPtr hWnd);
'@
[DashLauncher.Native]::SetDllDirectory($lib) | Out-Null       # lets .NET find WebView2Loader.dll
Add-Type -Path (Join-Path $lib 'Microsoft.Web.WebView2.Core.dll')
Add-Type -Path (Join-Path $lib 'Microsoft.Web.WebView2.WinForms.dll')

# ---------------------------------------------------------------- one launcher at a time
$created = $false
$script:AppMutex = New-Object System.Threading.Mutex($true, 'Local\DashLauncher', [ref]$created)
if (-not $created) {
    [Windows.Forms.MessageBox]::Show('DashLauncher is already open.', $AppName, 'OK', 'Information') | Out-Null
    exit 1
}

Import-Module (Join-Path $Root 'core\Launcher.Manifest.psm1') -Force
Import-Module (Join-Path $Root 'core\Launcher.Catalog.psm1') -Force
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Required = @('Initialize-Dash', 'Start-DashWorker', 'Suspend-DashWorker', 'Invoke-DashCommand', 'Receive-DashEvents', 'Get-DashStatus', 'Stop-DashTraffic', 'Stop-Dash')

# ---------------------------------------------------------------- settings
$script:DataDir = Join-Path $env:LOCALAPPDATA 'DashLauncher'
$script:SettingsPath = Join-Path $env:APPDATA 'DashLauncher\settings.json'
foreach ($d in @($script:DataDir, (Split-Path $script:SettingsPath))) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$script:ModulesDir = Join-Path $Root 'modules'
if (-not (Test-Path $script:ModulesDir)) { New-Item -ItemType Directory -Path $script:ModulesDir -Force | Out-Null }
$script:Settings = [pscustomobject]@{
    settingsVersion = 2; scanFolders = @($script:ModulesDir); approved = @(); declined = @(); order = @(); lastTab = ''; theme = 'system'; bounds = $null
    catalogCheck = $true; updateCheck = $true
}
if (Test-Path $script:SettingsPath) {
    try {
        $loaded = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
        # scanFolders is never read back: it is always this copy's own modules folder, so a moved or second copy of
        # DashLauncher (they share these settings) never scans another copy's modules
        foreach ($k in 'approved', 'declined', 'order') { if ($null -ne $loaded.$k) { $script:Settings.$k = @($loaded.$k | Where-Object { $_ -is [string] }) } }
        if ($loaded.lastTab -is [string]) { $script:Settings.lastTab = $loaded.lastTab }
        if (@('system', 'light', 'dark') -contains [string]$loaded.theme) { $script:Settings.theme = [string]$loaded.theme }
        if ($loaded.bounds) { $script:Settings.bounds = $loaded.bounds }
        if ($loaded.catalogCheck -is [bool]) { $script:Settings.catalogCheck = $loaded.catalogCheck }
        if ($loaded.updateCheck -is [bool]) { $script:Settings.updateCheck = $loaded.updateCheck }
    } catch { }
}
function Save-Settings {
    $keep = $script:Settings | Select-Object -Property * -ExcludeProperty scanFolders
    try { [IO.File]::WriteAllText($script:SettingsPath, ($keep | ConvertTo-Json -Depth 5), $script:Utf8) } catch { }
}
# A dash is approved by id and folder together, so a different folder claiming the same id asks again.
function Get-ApprovalKey { param($Info) return ('{0}|{1}' -f $Info.Id, $Info.Folder.ToLowerInvariant()) }

# ---------------------------------------------------------------- catalog: known modules and their GitHub releases
# GitHub is asked at start (at most once an hour) and when "Scan for modules" is pressed (at most every 10 minutes),
# only while some catalog module is not installed. The answers are cached, so an offline start still shows them.
$script:Catalog = @(Read-Catalog -Path (Join-Path $Root 'catalog.json'))
$script:CatalogIds = @($script:Catalog | ForEach-Object { $_.Id })
$script:CatalogCachePath = Join-Path $script:DataDir 'catalog-cache.json'
$script:CatalogCache = @{ checkedAt = ''; ok = $false; results = @{} }
try {
    if (Test-Path $script:CatalogCachePath) {
        $c = Get-Content $script:CatalogCachePath -Raw | ConvertFrom-Json
        $script:CatalogCache.checkedAt = [string]$c.checkedAt
        $script:CatalogCache.ok = [bool]$c.ok
        foreach ($p in @($c.results.PSObject.Properties)) { $script:CatalogCache.results[$p.Name] = $p.Value }
    }
} catch { }
$script:CatalogLive = @{}            # this run's answers, by repo
$script:CatalogJob = $null
function Get-CatalogState {
    param($Entry)
    return (Resolve-CatalogEntry -Entry $Entry -Result $script:CatalogLive[$Entry.Repo] -Cached $script:CatalogCache.results[$Entry.Repo])
}
function Start-CatalogCheck {
    <# Asks GitHub in a background runspace, so the window never waits on the network. #>
    param([int]$MinMinutes)
    if (-not $script:Settings.catalogCheck -or $script:CatalogJob) { return }
    $installed = @($script:Tabs | Where-Object { $_.State -ne 'available' -and $_.State -ne 'broken' } | ForEach-Object { $_.Id })
    $repos = @($script:Catalog | Where-Object { $installed -notcontains $_.Id -and $_.Published -ne $false } | ForEach-Object { $_.Repo })
    if (-not $repos.Count) { return }
    $last = [datetime]::MinValue
    if ($script:CatalogCache.checkedAt) { try { $last = [datetime]::Parse($script:CatalogCache.checkedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
    if ($script:CatalogCache.ok -and ((Get-Date) - $last).TotalMinutes -lt $MinMinutes) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript("Import-Module '$((Join-Path $Root 'core\Launcher.Catalog.psm1') -replace "'", "''")' -Force; Get-ReleaseInfo -Repos `$args").AddArgument($repos)
    $script:CatalogJob = @{ Ps = $ps; Handle = $ps.BeginInvoke() }
}
function Complete-CatalogCheck {
    <# Called from the timer once the background check has finished. #>
    $j = $script:CatalogJob
    if (-not $j -or -not $j.Handle.IsCompleted) { return }
    $script:CatalogJob = $null
    $results = @()
    try { $results = @($j.Ps.EndInvoke($j.Handle)) } catch { }
    try { $j.Ps.Dispose() } catch { }
    $allOk = $results.Count -gt 0
    foreach ($r in $results) {
        if (-not $r -or -not $r.Repo) { continue }
        $script:CatalogLive[[string]$r.Repo] = $r
        if ($r.Status -ne 'error') { $script:CatalogCache.results[[string]$r.Repo] = $r } else { $allOk = $false }
    }
    $script:CatalogCache.checkedAt = (Get-Date).ToString('o')
    $script:CatalogCache.ok = $allOk
    try { [IO.File]::WriteAllText($script:CatalogCachePath, (ConvertTo-Json -InputObject $script:CatalogCache -Depth 6), $script:Utf8) } catch { }
    [void](Invoke-Rescan)
}

# ---------------------------------------------------------------- launcher updates (child process, like NBADash's)
# Update-DashLauncher.ps1 checks GitHub and downloads + verifies a release into the update folder; Apply-Update.ps1
# swaps the files after the launcher closes, relaunches it, and rolls back if the new version does not confirm.
# Neither ever touches the modules folder.
$script:UpdDir = Join-Path $script:DataDir 'update'
if (-not (Test-Path $script:UpdDir)) { New-Item -ItemType Directory -Path $script:UpdDir -Force | Out-Null }
$script:UpdProc = $null
$script:UpdAction = ''
$script:UpdOut = Join-Path $script:UpdDir 'update.out'
$script:UpdResultPath = Join-Path $script:UpdDir 'update-result.json'
$script:Upd = @{ status = 'idle'; current = $Version; latest = ''; notes = ''; published = ''; htmlUrl = ''; error = ''; pct = 0; text = ''; installable = $false }
function Read-UpdateJson {
    param([string]$Name)
    $p = Join-Path $script:UpdDir $Name
    if (Test-Path $p) { try { return (Get-Content $p -Raw | ConvertFrom-Json) } catch { } }
    return $null
}
function Set-UpdateFromResult {
    param($R)
    if (-not $R) { return }
    $script:Upd.status = [string]$R.status
    foreach ($k in 'latest', 'notes', 'published', 'htmlUrl', 'error') { $script:Upd[$k] = [string]$R.$k }
    $script:Upd.installable = [bool]$R.installable
    if ($script:Upd.status -eq 'staged') { $script:Upd.installable = $true }
}
# the last answer, so the rail can show "update available" before any new check
$prev = Read-UpdateJson 'update-result.json'
if ($prev -and [string]$prev.status -eq 'available' -and [string]$prev.current -eq $Version) { Set-UpdateFromResult $prev }
$staged = Read-UpdateJson 'staged.json'
if ($staged -and [string]$staged.from -eq $Version -and (Test-Path (Join-Path $script:UpdDir 'stage\Start-DashLauncher.ps1'))) { $script:Upd.status = 'staged'; $script:Upd.latest = [string]$staged.version; $script:Upd.installable = $true }

function Start-Updater {
    param([ValidateSet('Check', 'Stage')][string]$Action)
    if ($script:UpdProc -and -not $script:UpdProc.HasExited) { return $false }
    $cur = if ($env:DASHLAUNCHER_FAKE_VERSION) { $env:DASHLAUNCHER_FAKE_VERSION } else { $Version }     # test hook
    Remove-Item $script:UpdResultPath -Force -ErrorAction SilentlyContinue
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Root 'Update-DashLauncher.ps1')),
                  '-Action', $Action, '-CurrentVersion', $cur, '-WorkDir', ('"{0}"' -f $script:UpdDir))
    if ($env:DASHLAUNCHER_UPDATE_API) { $argsList += @('-ApiBase', $env:DASHLAUNCHER_UPDATE_API) }      # test hook
    $script:UpdAction = $Action
    $script:UpdProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:UpdOut
    $script:Upd.status = $(if ($Action -eq 'Check') { 'checking' } else { 'downloading' })
    $script:Upd.pct = 0; $script:Upd.text = 'Starting...'; $script:Upd.error = ''
    Send-UpdateState
    return $true
}
function Get-UpdaterProgress {
    $r = @{ pct = 0; text = '' }
    try {
        $fs = [IO.File]::Open($script:UpdOut, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object IO.StreamReader($fs)
        while (($l = $sr.ReadLine()) -ne $null) { if ($l -match '^##PROGRESS (\d+)\|(.*)$') { $r.pct = [int]$Matches[1]; $r.text = $Matches[2] } }
        $sr.Close()
    } catch { }
    return $r
}
$script:LastUpdJson = ''
function Send-UpdateState {
    $json = ConvertTo-Json -InputObject @{ event = 'update'; data = $script:Upd } -Depth 4 -Compress
    if ($json -ne $script:LastUpdJson) { $script:LastUpdJson = $json; Send-View $panelView $json; Push-RailState }
}
function Watch-Updater {
    # from the timer: progress while it runs, the result once it ends
    if (-not $script:UpdProc) { return }
    if (-not $script:UpdProc.HasExited) {
        $p = Get-UpdaterProgress
        $script:Upd.pct = $p.pct; $script:Upd.text = $p.text
        Send-UpdateState
        return
    }
    $script:UpdProc = $null
    $res = Read-UpdateJson 'update-result.json'
    if (-not $res) { $res = [pscustomobject]@{ status = 'error'; error = 'The update check ended without an answer.' } }
    $was = $script:Upd.status
    Set-UpdateFromResult $res
    Send-UpdateState
    if ($script:Upd.status -eq 'available' -and $was -eq 'checking' -and -not $script:PanelOverride) { Show-Toast ("DashLauncher v{0} is available. Click the version at the bottom of the tab rail." -f $script:Upd.latest) }
}
function Start-UpdateCheckIfDue {
    # at start: at most once a day, and only if the person has not turned it off
    if (-not $script:Settings.updateCheck) { return }
    if (@('staged', 'available') -contains $script:Upd.status) { return }
    $last = $null
    if ($prev -and $prev.checkedAt) { try { $last = [datetime]::Parse([string]$prev.checkedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { } }
    if ($last -and ((Get-Date) - $last).TotalHours -lt 24 -and [string]$prev.status -ne 'error') { return }
    [void](Start-Updater 'Check')
}
function Install-StagedUpdate {
    $st = Read-UpdateJson 'staged.json'
    $stage = Join-Path $script:UpdDir 'stage'
    if (-not $st -or -not (Test-Path (Join-Path $stage 'Start-DashLauncher.ps1'))) { return 'There is no downloaded update to install. Download it again.' }
    # run the helper from a copy, so replacing the launcher's files cannot touch the running helper
    $runDir = Join-Path $script:UpdDir 'run'
    if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }
    $helper = Join-Path $runDir 'Apply-Update.ps1'
    Copy-Item (Join-Path $Root 'Apply-Update.ps1') $helper -Force
    $relaunch = '"' + (Join-Path $Root 'Start-DashLauncher.bat') + '"'
    $b64 = [Convert]::ToBase64String($script:Utf8.GetBytes($relaunch))
    $h = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $helper), '-AppDir', ('"{0}"' -f $Root), '-StageDir', ('"{0}"' -f $stage),
           '-WorkDir', ('"{0}"' -f $script:UpdDir), '-ParentPid', [string]$PID, '-OldVersion', $Version, '-NewVersion', [string]$st.version, '-RelaunchB64', $b64)
    Start-Process -FilePath 'powershell.exe' -ArgumentList $h -WindowStyle Hidden | Out-Null
    return ''
}
# After an update: report the result once, and tell the helper this start worked (once the rail has loaded).
$script:UpdateNote = $null
$pend = Read-UpdateJson 'update-pending.json'
if ($pend -and [string]$pend.to -eq $Version) { $script:UpdateNote = @{ ok = $true; from = [string]$pend.from; to = [string]$pend.to } }
$failed = Read-UpdateJson 'update-failed.json'
if ($failed) {
    $script:UpdateNote = @{ ok = $false; from = [string]$failed.from; to = [string]$failed.to; reason = [string]$failed.reason }
    Remove-Item (Join-Path $script:UpdDir 'update-failed.json'), (Join-Path $script:UpdDir 'update-pending.json') -Force -ErrorAction SilentlyContinue
}
function Confirm-UpdateStarted {
    $n = $script:UpdateNote
    if (-not $n) { return }
    $script:UpdateNote = $null
    if ($n.ok) {
        try { [IO.File]::WriteAllText((Join-Path $script:UpdDir 'update-ok.json'), '{"ok":true}', $script:Utf8) } catch { }
        Remove-Item (Join-Path $script:UpdDir 'update-pending.json') -Force -ErrorAction SilentlyContinue
        $script:Upd.status = 'current'
        Show-Toast ("DashLauncher was updated to v{0}." -f $n.to)
    } else {
        Show-Toast ("The update to v{0} did not work, so DashLauncher is back on v{1}. {2}" -f $n.to, $n.from, $n.reason)
    }
}

# ---------------------------------------------------------------- one-click install of a catalog module (child process)
# Install-DashModule.ps1 downloads the release zip and its checksum, checks them, unpacks into modules and checks the
# dash.json id; the launcher then rescans and the greyed tab becomes a working one.
$script:InstallProc = $null
$script:InstallOut = Join-Path $script:DataDir 'install.out'
$script:InstallResult = Join-Path $script:DataDir 'install-result.json'
$script:Install = @{ id = ''; status = 'idle'; pct = 0; text = ''; error = '' }
$script:LastInstallJson = ''
function Send-InstallState {
    $json = ConvertTo-Json -InputObject @{ event = 'install'; data = $script:Install } -Depth 3 -Compress
    if ($json -ne $script:LastInstallJson) { $script:LastInstallJson = $json; Send-View $panelView $json }
}
function Start-ModuleInstall {
    param($Tab)
    if ($script:InstallProc -and -not $script:InstallProc.HasExited) { return 'Another module is installing. Wait for it to finish.' }
    $repo = $Tab.Catalog.Repo
    $zip = [string]$Tab.Release.Asset; $sha = [string]$Tab.Release.Sha
    if ($zip -notlike "https://github.com/$repo/releases/download/*" -or $sha -notlike "https://github.com/$repo/releases/download/*") { return 'This release has no package that can be installed automatically.' }
    Remove-Item $script:InstallResult -Force -ErrorAction SilentlyContinue
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Root 'Install-DashModule.ps1')),
                  '-Id', $Tab.Id, '-Repo', $repo, '-ZipUrl', ('"{0}"' -f $zip), '-ShaUrl', ('"{0}"' -f $sha),
                  '-ModulesDir', ('"{0}"' -f $script:ModulesDir), '-ResultFile', ('"{0}"' -f $script:InstallResult))
    $script:InstallProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput $script:InstallOut
    $script:Install = @{ id = $Tab.Id; status = 'installing'; pct = 0; text = 'Starting...'; error = '' }
    Send-InstallState
    return ''
}
function Watch-Install {
    # from the timer: progress while it runs, then rescan so the tab turns on
    if (-not $script:InstallProc) { return }
    if (-not $script:InstallProc.HasExited) {
        $p = @{ pct = 0; text = '' }
        try {
            $fs = [IO.File]::Open($script:InstallOut, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs)
            while (($l = $sr.ReadLine()) -ne $null) { if ($l -match '^##PROGRESS (\d+)\|(.*)$') { $p.pct = [int]$Matches[1]; $p.text = $Matches[2] } }
            $sr.Close()
        } catch { }
        $script:Install.pct = $p.pct; $script:Install.text = $p.text
        Send-InstallState
        return
    }
    $script:InstallProc = $null
    $res = $null
    try { $res = Get-Content $script:InstallResult -Raw | ConvertFrom-Json } catch { }
    $id = $script:Install.id
    $name = $(if ($script:ById.ContainsKey($id)) { $script:ById[$id].Name } else { $id })
    if ($res -and [string]$res.status -eq 'installed') {
        $script:Install = @{ id = $id; status = 'installed'; pct = 100; text = 'Installed'; error = '' }
        Send-InstallState
        Show-Toast ("{0} is installed." -f $name)
        [void](Invoke-Rescan)
        if ($script:ById.ContainsKey($id) -and $script:Active -ne $id) { $script:Active = ''; Select-Tab $id }
    } else {
        $why = $(if ($res -and $res.error) { [string]$res.error } else { 'The installer ended without an answer.' })
        $script:Install = @{ id = $id; status = 'error'; pct = 0; text = ''; error = $why }
        Send-InstallState
        if ($script:Active -eq $id) { Show-Notice }
    }
}

# ---------------------------------------------------------------- tabs
$script:Tabs = New-Object System.Collections.ArrayList
$script:ById = @{}
$script:Active = ''

function Get-IconData {
    # The rail page cannot read dash folders, so icons travel as data: URIs (200 KB max).
    param([string]$Path)
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 204800) { return '' }
        $mime = if ($Path -match '\.svg$') { 'image/svg+xml' } else { 'image/png' }
        return ('data:{0};base64,{1}' -f $mime, [Convert]::ToBase64String($bytes))
    } catch { return '' }
}

function New-Tab {
    param($Info, [string]$State, [string]$Id, [string]$Name, [string]$Message = '', $Catalog = $null, $Release = $null)
    $icon = ''
    if ($Info -and $Info.Ok) { $icon = Get-IconData $Info.Paths['icon'] }
    elseif ($Catalog -and $Catalog.Icon) { $icon = Get-IconData (Join-Path $Root $Catalog.Icon) }
    return [pscustomobject]@{
        Id = $Id; Name = $Name; Info = $Info; State = $State; Error = $Message; Catalog = $Catalog; Release = $Release
        Module = $null; Fn = @{}; Ctx = $null; Init = $null; WebView = $null; Status = $null; Icon = $icon
    }
}

function Approve-Dash {
    # Asks once per dash folder. Returns the tab state: 'unloaded' (approved) or 'declined'.
    param($Info)
    $key = Get-ApprovalKey $Info
    if ($script:Settings.declined -contains $key) { return 'declined' }
    if ($script:Settings.approved -contains $key) { return 'unloaded' }
    if ($script:CatalogIds -contains $Info.Id) {
        # a module from the catalog, installed by the person from its release: no extra question
        $script:Settings.approved = @($script:Settings.approved) + $key
        Save-Settings
        return 'unloaded'
    }
    $q = "Add this dashboard module to DashLauncher?`n`n{0} (version {1})`n{2}`n`nIts code will run inside DashLauncher. Only add modules you got from a source you trust." -f $Info.Title, $Info.Version, $Info.Folder
    $state = 'declined'
    if ([Windows.Forms.MessageBox]::Show($form, $q, $AppName, 'YesNo', 'Question') -eq 'Yes') { $script:Settings.approved = @($script:Settings.approved) + $key; $state = 'unloaded' }
    else { $script:Settings.declined = @($script:Settings.declined) + $key }
    Save-Settings
    return $state
}

function Update-Tabs {
    <#
    Scans the module folders and rebuilds the tab list. A running dash whose folder (or dash.json) is gone is shut down
    and its tab removed. Returns counts of modules added and removed.
    ById is cleared and refilled rather than replaced: each dash's Post closure holds a reference to it.
    #>
    $found = @(Find-Dashes -ScanFolders $script:Settings.scanFolders -Exclude @($Root))
    $before = @{}
    foreach ($t in $script:Tabs) { if ($t.Info -and $t.State -ne 'broken') { $before[(Get-ApprovalKey $t.Info)] = $true } }
    $loaded = @{}
    foreach ($t in $script:Tabs) {
        if (-not ($t.Module -or $t.Init)) { continue }
        if ($t.Info -and (Test-Path -LiteralPath (Join-Path $t.Info.Folder 'dash.json') -PathType Leaf)) { $loaded[$t.Id] = $t }
        else { Close-Tab $t }                                         # removed or moved: shut it down
    }
    $order = @($script:Settings.order)
    $ok = @($found | Where-Object { $_.Ok } | Sort-Object @{ Expression = { $i = [array]::IndexOf($order, $_.Id); if ($i -lt 0) { 10000 } else { $i } } }, Folder)
    $newTabs = New-Object System.Collections.ArrayList
    $added = 0
    $seen = @{}
    foreach ($info in $ok) {
        $key = Get-ApprovalKey $info
        $seen[$key] = $true
        if ($loaded.ContainsKey($info.Id)) { [void]$newTabs.Add($loaded[$info.Id]); $loaded.Remove($info.Id); continue }
        if (-not $before.ContainsKey($key)) { $added++ }
        $state = Approve-Dash $info
        [void]$newTabs.Add((New-Tab -Info $info -State $state -Id $info.Id -Name $info.Name))
    }
    foreach ($t in $loaded.Values) { Close-Tab $t }                 # its dash.json no longer passes the checks
    $have = @($newTabs | ForEach-Object { $_.Id })
    foreach ($entry in $script:Catalog) {
        if ($have -contains $entry.Id) { continue }
        $st = Get-CatalogState $entry
        if ($st.Show) { [void]$newTabs.Add((New-Tab -Info $null -State 'available' -Id $entry.Id -Name $entry.Name -Catalog $entry -Release $st)) }
    }
    $n = 0
    foreach ($info in @($found | Where-Object { -not $_.Ok })) {
        $n++
        $leaf = Split-Path $info.Folder -Leaf
        if ($leaf.Length -gt 12) { $leaf = $leaf.Substring(0, 12) }
        [void]$newTabs.Add((New-Tab -Info $info -State 'broken' -Id ('broken' + $n) -Name $leaf -Message $info.Reason))
    }
    foreach ($t in $newTabs) { if (($t.Module -or $t.Init) -and $t.Info) { $seen[(Get-ApprovalKey $t.Info)] = $true } }
    $removed = @($before.Keys | Where-Object { -not $seen.ContainsKey($_) }).Count
    $script:Tabs.Clear()
    $script:ById.Clear()
    foreach ($t in $newTabs) { [void]$script:Tabs.Add($t); $script:ById[$t.Id] = $t }
    return @{ added = $added; removed = $removed; broken = $n; total = @($newTabs | Where-Object { @('broken', 'available') -notcontains $_.State }).Count }
}

function ConvertTo-TabJson {
    param($T)
    $s = $T.Status
    return @{
        id = $T.Id; name = $T.Name; state = $T.State; icon = $T.Icon; error = $T.Error
        title = $(if ($T.Info) { $T.Info.Title } elseif ($T.Catalog) { $T.Catalog.Title } else { '' })
        version = $(if ($T.Info) { $T.Info.Version } elseif ($T.Release) { $T.Release.Version } else { '' })
        live = $(if ($s) { [int]$s.Live } else { 0 }); syncing = $(if ($s) { [bool]$s.Syncing } else { $false })
        syncPct = $(if ($s) { $s.SyncPct } else { $null }); update = $(if ($s) { $s.UpdateAvailable } else { $null })
        statusError = $(if ($s) { $s.Error } else { $null })
    }
}

# ---------------------------------------------------------------- window
$form = New-Object Windows.Forms.Form
$form.Text = $AppName
$form.MinimumSize = New-Object Drawing.Size(900, 600)
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(1600, 1000)
$b = $script:Settings.bounds
if ($b -and $b.w -ge 900 -and $b.h -ge 600) {
    $rect = New-Object Drawing.Rectangle([int]$b.x, [int]$b.y, [int]$b.w, [int]$b.h)
    if (@([Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.IntersectsWith($rect) }).Count) {
        $form.StartPosition = 'Manual'
        $form.Bounds = $rect
        if ($b.max) { $form.WindowState = 'Maximized' }
    }
}

$launcherProfile = Join-Path $script:DataDir 'webview2'
function New-LauncherView {
    param([string]$DockStyle)
    $v = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $p = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    $p.UserDataFolder = $launcherProfile
    $v.CreationProperties = $p
    $v.Dock = $DockStyle
    return $v
}
$content = New-Object Windows.Forms.Panel
$content.Dock = 'Fill'
$form.Controls.Add($content)
$rail = New-LauncherView 'Left'
$rail.Width = 76
$form.Controls.Add($rail)
$content.BringToFront()                       # docks last, so it fills what the rail leaves
$panelView = New-LauncherView 'Fill'
$panelView.Visible = $false
$content.Controls.Add($panelView)

# ---------------------------------------------------------------- toast: bottom right, over whichever view is showing
# Same look as NBADash's toasts (dark rounded box, 18 px from the corner, 3.5 seconds). A native control, because a
# page's HTML cannot draw over the other WebView2s.
$script:Toast = New-Object Windows.Forms.Label
$script:Toast.AutoSize = $true
$script:Toast.MaximumSize = New-Object Drawing.Size(420, 0)
$script:Toast.Padding = New-Object Windows.Forms.Padding(14, 10, 14, 10)
$script:Toast.Font = New-Object Drawing.Font('Segoe UI', 10)
$script:Toast.Anchor = 'Bottom, Right'
$script:Toast.Visible = $false
$content.Controls.Add($script:Toast)
$script:ToastTimer = New-Object Windows.Forms.Timer
$script:ToastTimer.Interval = 3500
$script:ToastTimer.add_Tick({ $script:ToastTimer.Stop(); $script:Toast.Visible = $false })
function Set-ToastShape {
    $t = $script:Toast; $d = 20
    if ($t.Width -lt $d -or $t.Height -lt $d) { return }
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($t.Width - $d, 0, $d, $d, 270, 90)
    $path.AddArc($t.Width - $d, $t.Height - $d, $d, $d, 0, 90); $path.AddArc(0, $t.Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $t.Region = New-Object Drawing.Region($path)
}
function Move-Toast {
    $t = $script:Toast
    $t.Location = New-Object Drawing.Point(($content.ClientSize.Width - $t.Width - 18), ($content.ClientSize.Height - $t.Height - 18))
}
function Test-DarkTheme {
    if ($script:Settings.theme -eq 'dark') { return $true }
    if ($script:Settings.theme -eq 'light') { return $false }
    try { return ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).AppsUseLightTheme -eq 0) } catch { return $false }
}
function Show-Toast {
    param([string]$Text)
    if (-not $Text) { return }
    $t = $script:Toast
    if (Test-DarkTheme) { $t.BackColor = [Drawing.Color]::FromArgb(232, 236, 244); $t.ForeColor = [Drawing.Color]::FromArgb(13, 16, 23) }
    else { $t.BackColor = [Drawing.Color]::FromArgb(19, 23, 34); $t.ForeColor = [Drawing.Color]::FromArgb(244, 245, 248) }
    $t.Text = $Text
    Set-ToastShape
    Move-Toast
    $t.Visible = $true
    $t.BringToFront()
    $script:ToastTimer.Stop(); $script:ToastTimer.Start()
}
$script:Toast.add_SizeChanged({ Set-ToastShape; Move-Toast })
$content.add_Resize({ if ($script:Toast.Visible) { Move-Toast } })

function Send-View {
    param($View, [string]$Json)
    try { if ($View -and $View.CoreWebView2) { $View.CoreWebView2.PostWebMessageAsJson($Json) } } catch { }
}
function Send-Event {
    param($View, [string]$Name, $Data)
    Send-View $View (ConvertTo-Json -InputObject @{ event = $Name; data = $Data } -Depth 8 -Compress)
}
$script:LastRailJson = ''
function Push-RailState {
    $upd = $(if (@('available', 'staged', 'downloading') -contains $script:Upd.status) { $script:Upd.latest } else { '' })
    $obj = @{ tabs = @($script:Tabs | ForEach-Object { ConvertTo-TabJson $_ }); active = $script:Active; theme = $script:Settings.theme; launcherUpdate = $upd; overlay = [string]$script:PanelOverride }
    $json = ConvertTo-Json -InputObject @{ event = 'tabs'; data = $obj } -Depth 8 -Compress
    if ($json -ne $script:LastRailJson) { $script:LastRailJson = $json; Send-View $rail $json }
}

# ---------------------------------------------------------------- notices (locked, error, broken, declined, empty)
$script:Notice = $null
$script:PanelOverride = ''
function Get-Notice {
    if ($script:PanelOverride -eq 'update') { return @{ kind = 'update'; update = $script:Upd; updateCheck = [bool]$script:Settings.updateCheck } }
    $t = $script:ById[$script:Active]
    if (-not $t) {
        $sample = Join-Path $Root 'samples\SampleDash'
        return @{ kind = 'empty'; modulesDir = $script:ModulesDir; scanFolders = @($script:Settings.scanFolders); sampleDir = $(if (Test-Path $sample) { $sample } else { '' }) }
    }
    if ($t.State -eq 'available') {
        $repoName = ($t.Catalog.Repo -split '/')[1]
        return @{
            kind = 'available'; id = $t.Id; name = $t.Name; title = $t.Catalog.Title; repo = $t.Catalog.Repo
            version = $t.Release.Version; publishedAt = $t.Release.PublishedAt; assetName = $t.Release.AssetName
            hasAsset = [bool]$t.Release.Asset; hasSha = [bool]$t.Release.Sha; source = $t.Release.Source
            install = $(if ($script:Install.id -eq $t.Id) { $script:Install } else { $null })
            modulesDir = $script:ModulesDir; target = (Join-Path $script:ModulesDir $repoName)
        }
    }
    return @{
        kind = $t.State; id = $t.Id; name = $t.Name; message = $t.Error
        title = $(if ($t.Info) { $t.Info.Title } else { '' })
        folder = $(if ($t.Info) { $t.Info.Folder } else { '' })
        version = $(if ($t.Info) { $t.Info.Version } else { '' })
    }
}
function Show-Notice {
    $script:Notice = Get-Notice
    $panelView.Visible = $true
    $panelView.BringToFront()
    if ($script:Toast.Visible) { $script:Toast.BringToFront() }
    Send-Event $panelView 'notice' $script:Notice
}

# ---------------------------------------------------------------- dash lifecycle
# ---------------------------------------------------------------- keyboard: Ctrl+1..9 jump to a tab, Ctrl+Tab cycles
# Keys typed in a dashboard go to its WebView2, not to this window, so after each page loads the launcher adds this
# listener. It sends launcher.* messages, which the launcher handles itself and never passes to the dash.
$script:KeyScript = @'
(() => {
  if (window.__dashLauncherKeys) return;
  window.__dashLauncherKeys = true;
  window.addEventListener('keydown', (e) => {
    if (!e.ctrlKey || e.altKey || e.metaKey) return;
    const m = /^(?:Digit|Numpad)([1-9])$/.exec(e.code);
    const key = m ? m[1] : (e.key === 'Tab' ? 'Tab' : '');
    if (!key) return;
    e.preventDefault(); e.stopPropagation();
    window.chrome.webview.postMessage({ cmd: 'launcher.key', args: { key: key, shift: e.shiftKey } });
  }, true);
})();
'@
function Invoke-LauncherKey {
    param($A)
    $tabs = @($script:Tabs)
    if (-not $tabs.Count) { return }
    $key = [string]$A.key
    $target = $null
    if ($key -match '^[1-9]$') {
        $i = [int]$key - 1
        if ($i -lt $tabs.Count) { $target = $tabs[$i] }
    } elseif ($key -eq 'Tab') {
        $cur = [array]::IndexOf(@($tabs | ForEach-Object { $_.Id }), $script:Active)
        $step = if ($A.shift) { -1 } else { 1 }
        $target = $tabs[(($cur + $step) % $tabs.Count + $tabs.Count) % $tabs.Count]
    }
    if ($target -and $target.Id -ne $script:Active) { Select-Tab $target.Id }
}

function Invoke-DashFn {
    # Calls a backend function through its own module object, never by bare name: every dash exports the same names.
    param($Tab, [string]$Name, [hashtable]$Params = @{})
    $cmd = $Tab.Fn[$Name]
    if (-not $cmd) { return $null }
    return (& $cmd @Params)
}

function New-DashContext {
    param($Tab)
    $id = $Tab.Id; $reg = $script:ById; $fm = $form
    return [pscustomobject]@{
        Mode            = 'launcher'
        Root            = $Tab.Info.Folder
        Post            = { param([string]$Json) $r = $reg[$id]; if ($r -and $r.WebView -and $r.WebView.CoreWebView2) { try { $r.WebView.CoreWebView2.PostWebMessageAsJson($Json) } catch { } } }.GetNewClosure()
        Close           = { $fm.Close() }.GetNewClosure()
        Relaunch        = ('"{0}" -Open {1}' -f (Join-Path $Root 'Start-DashLauncher.bat'), $id)
        HostPid         = $PID
        Theme           = $script:Settings.theme
        LauncherVersion = $Version
        Debug           = [bool]$Debug
    }
}

function Remove-DashView {
    param($Tab)
    if ($Tab.WebView) {
        try { $content.Controls.Remove($Tab.WebView); $Tab.WebView.Dispose() } catch { }
        $Tab.WebView = $null
    }
}

function Close-Tab {
    <# Shuts a loaded dash down and forgets its backend, so its tab can be removed or loaded again fresh. #>
    param($Tab)
    if ($Tab.Init) { try { Invoke-DashFn $Tab 'Stop-Dash' | Out-Null } catch { } }
    Remove-DashView $Tab
    if ($Tab.Module) { try { Remove-Module -ModuleInfo $Tab.Module -Force -ErrorAction SilentlyContinue } catch { } }
    $Tab.Module = $null; $Tab.Fn = @{}; $Tab.Init = $null; $Tab.Ctx = $null; $Tab.Status = $null
    $Tab.State = 'unloaded'
}

function Open-Tab {
    <# Loads the backend if needed, initializes it, creates its WebView2 and starts its worker. #>
    param($Tab)
    try {
        if (-not $Tab.Module) {
            $mods = @(Import-Module -Name $Tab.Info.Paths['backend'] -PassThru -Force -DisableNameChecking -ErrorAction Stop)
            $mod = $mods | Where-Object { $_.Path -eq $Tab.Info.Paths['backend'] } | Select-Object -First 1
            if (-not $mod) { $mod = $mods[0] }
            $fns = @{}
            foreach ($f in $script:Required) {
                $c = $mod.ExportedCommands[$f]
                if (-not $c) { throw "Its backend does not export $f (dash contract 1)." }
                $fns[$f] = $c
            }
            if ($mod.ExportedCommands['Invoke-DashSync']) { $fns['Invoke-DashSync'] = $mod.ExportedCommands['Invoke-DashSync'] }
            $Tab.Fn = $fns
            $Tab.Module = $mod
        }
        if (-not $Tab.Init) {
            if (-not $Tab.Ctx) { $Tab.Ctx = New-DashContext $Tab }
            # the last hashtable or object it outputs is the result, in case the backend leaks other output
            $init = @(Invoke-DashFn $Tab 'Initialize-Dash' @{ Context = $Tab.Ctx }) | Where-Object { $_ -is [hashtable] -or $_ -is [pscustomobject] } | Select-Object -Last 1
            if (-not $init -or -not $init.Ok) {
                if ($init -and [string]$init.Reason -eq 'locked') { $Tab.State = 'locked'; $Tab.Error = '' }
                else { $Tab.State = 'error'; $Tab.Error = $(if ($init) { [string]$init.Reason } else { 'Initialize-Dash returned nothing.' }) }
                return
            }
            foreach ($k in 'CacheDir', 'WebViewDataDir') {
                if (-not ($init.$k -is [string]) -or -not $init.$k) { throw "Initialize-Dash did not return $k." }
                if (-not (Test-Path $init.$k)) { New-Item -ItemType Directory -Path $init.$k -Force | Out-Null }
            }
            $Tab.Init = $init
        }
        $Tab.State = 'ready'
        $Tab.Error = ''
        Remove-DashView $Tab
        New-DashView $Tab
        Invoke-DashFn $Tab 'Start-DashWorker' | Out-Null
    } catch {
        $Tab.State = 'error'
        $Tab.Error = $_.Exception.Message
    }
}

function New-DashView {
    param($Tab)
    $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $p = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    $p.UserDataFolder = $Tab.Init.WebViewDataDir     # the dash's own profile: browser storage matches standalone
    $wv.CreationProperties = $p
    $wv.Dock = 'Fill'
    $wv.Tag = $Tab.Id
    $wv.Visible = ($script:Active -eq $Tab.Id)
    $content.Controls.Add($wv)
    $wv.BringToFront()
    # Events on the WinForms control: the sender is the control itself, whose Tag is the dash id.
    $wv.add_CoreWebView2InitializationCompleted({ param($sender, $e) Complete-DashView $sender $e })
    $wv.add_WebMessageReceived({
        param($s, $a)
        $tab = $script:ById[[string]$s.Tag]
        if (-not $tab -or $tab.State -ne 'ready' -or -not [object]::ReferenceEquals($tab.WebView, $s)) { return }
        $msg = $null
        try { $msg = $a.WebMessageAsJson | ConvertFrom-Json } catch { return }
        if ($msg.cmd -is [string] -and $msg.cmd.StartsWith('launcher.')) {
            if ($msg.cmd -eq 'launcher.key') { try { Invoke-LauncherKey $msg.args } catch { } }
            return
        }
        try { Invoke-DashFn $tab 'Invoke-DashCommand' @{ Message = $msg } | Out-Null } catch { }
    })
    $wv.add_NavigationStarting({
        param($s, $a)
        if ($a.Uri -notmatch ('^https://' + [regex]::Escape([string]$s.Tag) + '\.(ui|cache)/')) { $a.Cancel = $true }
    })
    $wv.add_NavigationCompleted({
        param($s, $a)
        Send-Event $s 'host.theme' @{ theme = $script:Settings.theme }
        try { [void]$s.CoreWebView2.ExecuteScriptAsync($script:KeyScript) } catch { }
    })
    $Tab.WebView = $wv
    [void]$wv.EnsureCoreWebView2Async($null)
}

function Complete-DashView {
    param($Sender, $E)
    $t = $script:ById[[string]$Sender.Tag]
    if (-not $t) { return }
    if (-not $E.IsSuccess) {
        $t.State = 'error'
        $t.Error = "WebView2 failed to start: $($E.InitializationException.Message)"
        if ($script:Active -eq $t.Id) { $Sender.Visible = $false; Show-Notice }
        Push-RailState
        return
    }
    $core = $Sender.CoreWebView2
    $allow = [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow
    $core.SetVirtualHostNameToFolderMapping("$($t.Id).ui", $t.Info.Paths['ui'], $allow)
    $core.SetVirtualHostNameToFolderMapping("$($t.Id).cache", $t.Init.CacheDir, $allow)
    $core.Settings.AreDefaultContextMenusEnabled = [bool]$Debug
    $core.Settings.AreDevToolsEnabled = [bool]$Debug
    $core.Settings.IsStatusBarEnabled = $false
    $core.add_NewWindowRequested({ param($s, $a) $a.Handled = $true })      # no pop-ups
    $core.Navigate(('https://{0}.ui/{1}' -f $t.Id, $t.Info.Entry))
}

function Select-Tab {
    param([string]$Id)
    $script:PanelOverride = ''
    $next = $script:ById[$Id]
    if (-not $next) { return }
    $cur = $script:ById[$script:Active]
    if ($cur -and $cur -ne $next -and $cur.State -eq 'ready') {
        try { Invoke-DashFn $cur 'Suspend-DashWorker' | Out-Null } catch { }
        Send-Event $cur.WebView 'host.hidden' @{}
        if ($cur.WebView) { $cur.WebView.Visible = $false }
    }
    $wasActive = ($script:Active -eq $Id)
    $script:Active = $Id
    if ($next.Info -and $next.Info.Ok) { $script:Settings.lastTab = $Id }
    if ($next.State -eq 'unloaded') { Open-Tab $next }
    elseif ($next.State -eq 'ready' -and -not $wasActive) {
        try { Invoke-DashFn $next 'Start-DashWorker' | Out-Null } catch { }
        Send-Event $next.WebView 'host.visible' @{}
    }
    if ($next.State -eq 'ready' -and $next.WebView) {
        $panelView.Visible = $false
        $next.WebView.Visible = $true
        $next.WebView.BringToFront()
        if ($script:Toast.Visible) { $script:Toast.BringToFront() }
        $form.Text = '{0} - {1}' -f $next.Info.Title, $AppName
    } else {
        $form.Text = $AppName
        Show-Notice
    }
    Push-RailState
}

function Test-RunningModules {
    <#
    Every 2 seconds: one file check per running dash (not a folder watch, and it never looks for new modules). A dash
    whose dash.json is gone keeps running from memory but would break on its next sync, update or reload, so it is
    paused and covered with a notice offering Close or Reload.
    #>
    foreach ($t in @($script:Tabs)) {
        if ($t.State -ne 'ready' -or -not $t.Info) { continue }
        if (Test-Path -LiteralPath (Join-Path $t.Info.Folder 'dash.json') -PathType Leaf) { continue }
        $t.State = 'missing'
        try { Invoke-DashFn $t 'Suspend-DashWorker' | Out-Null } catch { }
        if ($script:Active -eq $t.Id) {
            if ($t.WebView) { $t.WebView.Visible = $false }
            $form.Text = $AppName
            Show-Notice
        }
        Show-Toast ("{0}'s folder was removed from the modules folder." -f $t.Name)
    }
}

function Stop-AllTraffic {
    $q = "Stop all traffic to every dashboard's data sources now?`n`nSyncs, live refreshes and data requests stop. Update checks are not affected. Each dashboard stays stopped until you resume it inside that dashboard."
    if ([Windows.Forms.MessageBox]::Show($q, $AppName, 'YesNo', 'Warning') -ne 'Yes') { return -1 }
    $n = 0
    foreach ($t in $script:Tabs) {
        if ($t.State -eq 'ready') { try { Invoke-DashFn $t 'Stop-DashTraffic' | Out-Null; $n++ } catch { } }
    }
    return $n
}

$script:PendingStop = $null
function Complete-StopAllTraffic {
    $p = $script:PendingStop
    $n = 0
    try { $n = Stop-AllTraffic } catch { }
    $script:PendingStop = $null
    if ($p) { Send-View $p.View ('{{"id":{0},"ok":true,"data":{1}}}' -f $p.Id, $n) }
    if ($n -eq 0) { Show-Toast 'No dashboard is running, so there was nothing to stop.' }
    elseif ($n -eq 1) { Show-Toast 'Data traffic stopped in 1 dashboard. Resume it from inside the dashboard.' }
    elseif ($n -gt 1) { Show-Toast "Data traffic stopped in $n dashboards. Resume each from inside the dashboard." }
    Push-RailState
}

$script:Scanning = $false
$script:PendingScan = $null
function Invoke-Rescan {
    <# Rescans the module folders, then reopens the active tab if its state changed. Returns the counts. #>
    if ($script:Scanning) { return $null }
    $script:Scanning = $true
    try {
        $active = $script:Active
        $r = Update-Tabs
        $stillReady = ($active -and $script:ById.ContainsKey($active) -and $script:ById[$active].State -eq 'ready')
        if (-not $stillReady) {
            $pick = $null
            if ($active -and $script:ById.ContainsKey($active)) { $pick = $active }
            else { $f = $script:Tabs | Where-Object { $_.State -eq 'unloaded' } | Select-Object -First 1; if (-not $f) { $f = $script:Tabs | Select-Object -First 1 }; if ($f) { $pick = $f.Id } }
            $script:Active = ''
            if ($pick) { Select-Tab $pick } else { Show-Notice }
        }
        Push-RailState
        return $r
    } finally { $script:Scanning = $false }
}
function Format-ScanResult {
    param($R)
    if ($R.busy) { return 'Already scanning.' }
    $bits = @()
    if ($R.added) { $bits += $(if ($R.added -eq 1) { '1 new module' } else { "$($R.added) new modules" }) }
    if ($R.removed) { $bits += $(if ($R.removed -eq 1) { '1 module removed' } else { "$($R.removed) modules removed" }) }
    if ($R.broken) { $bits += $(if ($R.broken -eq 1) { '1 module has a problem' } else { "$($R.broken) modules have a problem" }) }
    if (-not $bits.Count) { return 'No changes in the modules folder.' }
    return (($bits -join ', ') + '.')
}
function Complete-Scan {
    $p = $script:PendingScan
    $r = $null
    try { $r = Invoke-Rescan } catch { }
    try { Start-CatalogCheck -MinMinutes 10 } catch { }
    $script:PendingScan = $null
    if (-not $r) { $r = @{ added = 0; removed = 0; broken = 0; total = $script:Tabs.Count; busy = $true } }
    Show-Toast (Format-ScanResult $r)
    if ($p) { Send-View $p.View ('{{"id":{0},"ok":true,"data":{1}}}' -f $p.Id, (ConvertTo-Json -InputObject $r -Compress)) }
}

function Show-StandaloneWindow {
    # A locked dash is open in its own window: bring that window to the front.
    param($Tab)
    $title = $Tab.Info.Title
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -eq $title } | Select-Object -First 1
    if (-not $p) { return $false }
    if ([DashLauncher.Native]::IsIconic($p.MainWindowHandle)) { [DashLauncher.Native]::ShowWindow($p.MainWindowHandle, 9) | Out-Null }
    return [DashLauncher.Native]::SetForegroundWindow($p.MainWindowHandle)
}

# ---------------------------------------------------------------- rail and notice page commands
function Invoke-LauncherCommand {
    param($View, $Msg)
    $a = $Msg.args
    $reply = { param($DataJson) Send-View $View ('{{"id":{0},"ok":true,"data":{1}}}' -f [int]$Msg.id, $DataJson) }
    $fail = { param($Text) Send-View $View ('{{"id":{0},"ok":false,"error":{1}}}' -f [int]$Msg.id, (ConvertTo-Json -InputObject ([string]$Text) -Compress)) }
    $tabArg = { $i = [string]$a.id; if ($i -cmatch '^[a-z][a-z0-9]{1,19}$' -and $script:ById.ContainsKey($i)) { $script:ById[$i] } else { $null } }
    switch ([string]$Msg.cmd) {
        'rail.init' {
            $script:LastRailJson = ''
            & $reply (ConvertTo-Json -InputObject @{ version = $Version; theme = $script:Settings.theme; debug = [bool]$Debug } -Compress)
            Push-RailState
            Confirm-UpdateStarted                     # the launcher has loaded: an update just installed can be kept
        }
        'update.open' {
            & $reply 'true'
            $script:PanelOverride = 'update'
            $form.Text = $AppName
            Show-Notice
            Push-RailState
            if (@('idle', 'error', 'none') -contains $script:Upd.status) { [void](Start-Updater 'Check') }
        }
        'update.close' {
            & $reply 'true'
            $back = $script:Active
            $script:PanelOverride = ''
            $script:Active = ''
            if ($back -and $script:ById.ContainsKey($back)) { Select-Tab $back } else { Show-Notice; Push-RailState }
        }
        'update.check' { & $reply ((Start-Updater 'Check').ToString().ToLower()) }
        'update.stage' { & $reply ((Start-Updater 'Stage').ToString().ToLower()) }
        'update.cancel' {
            try { if ($script:UpdProc -and -not $script:UpdProc.HasExited) { $script:UpdProc.Kill() } } catch { }
            & $reply 'true'
        }
        'update.apply' {
            $err = Install-StagedUpdate
            if ($err) { & $fail $err; return }
            & $reply 'true'
            $form.Close()                              # the helper waits for this process to end, then swaps the files
        }
        'update.auto' {
            $script:Settings.updateCheck = [bool]$a.on
            Save-Settings
            & $reply 'true'
        }
        'panel.get' { & $reply (ConvertTo-Json -InputObject @{ notice = (Get-Notice); theme = $script:Settings.theme } -Depth 6 -Compress) }
        'tab.select' {
            $t = & $tabArg
            if (-not $t) { & $fail 'unknown tab'; return }
            & $reply 'true'
            Select-Tab $t.Id
        }
        'tab.retry' {
            $t = & $tabArg
            if (-not $t -or @('locked', 'error') -notcontains $t.State) { & $fail 'nothing to retry'; return }
            if (-not $t.Init) { $t.Module = $null }           # import again in case the backend file was fixed
            $t.State = 'unloaded'
            & $reply 'true'
            $script:Active = ''
            Select-Tab $t.Id
        }
        'tab.approve' {
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'declined') { & $fail 'not declined'; return }
            $key = Get-ApprovalKey $t.Info
            $script:Settings.declined = @($script:Settings.declined | Where-Object { $_ -ne $key })
            $script:Settings.approved = @($script:Settings.approved) + $key
            Save-Settings
            $t.State = 'unloaded'
            & $reply 'true'
            $script:Active = ''
            Select-Tab $t.Id
        }
        'tab.close' {
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'missing') { & $fail 'not missing'; return }
            & $reply 'true'
            Close-Tab $t
            $script:Active = ''
            [void](Invoke-Rescan)
        }
        'tab.reload' {
            # only if the folder is back: then the dash starts again fresh from its files
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'missing') { & $fail 'not missing'; return }
            if (-not (Test-Path -LiteralPath (Join-Path $t.Info.Folder 'dash.json') -PathType Leaf)) { & $reply 'false'; return }
            & $reply 'true'
            $id = $t.Id
            Close-Tab $t
            [void](Invoke-Rescan)
            if ($script:ById.ContainsKey($id) -and $script:Active -ne $id) { $script:Active = ''; Select-Tab $id }
        }
        'tab.switchTo' {
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'locked') { & $fail 'not locked'; return }
            & $reply ((Show-StandaloneWindow $t).ToString().ToLower())
        }
        'theme.set' {
            $th = [string]$a.theme
            if (@('system', 'light', 'dark') -notcontains $th) { & $fail 'bad theme'; return }
            $script:Settings.theme = $th
            Save-Settings
            foreach ($t in $script:Tabs) {
                if ($t.Ctx) { $t.Ctx.Theme = $th }
                if ($t.State -eq 'ready') { Send-Event $t.WebView 'host.theme' @{ theme = $th } }
            }
            Send-Event $panelView 'theme' @{ theme = $th }
            & $reply 'true'
            Push-RailState
        }
        'modules.scan' {
            # approval dialogs may open, so run it just after this WebView2 event returns
            if ($script:PendingScan) { & $reply '{"busy":true}'; return }
            $script:PendingScan = @{ View = $View; Id = [int]$Msg.id }
            [void]$form.BeginInvoke([Action]{ Complete-Scan })
        }
        'catalog.download' {
            # open the release download (or its page) in the default browser; only github.com links for that repo
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'available') { & $fail 'not available'; return }
            $url = if ($a.page -or -not $t.Release.Asset) { $t.Release.Url } else { $t.Release.Asset }
            if ($url -notlike "https://github.com/$($t.Catalog.Repo)/*") { & $fail 'bad link'; return }
            try { Start-Process $url; & $reply 'true' } catch { & $fail $_.Exception.Message }
        }
        'catalog.install' {
            $t = & $tabArg
            if (-not $t -or $t.State -ne 'available') { & $fail 'not available'; return }
            $err = Start-ModuleInstall $t
            if ($err) { & $fail $err; return }
            & $reply 'true'
        }
        'modules.open' {
            try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:ModulesDir); & $reply 'true' } catch { & $fail $_.Exception.Message }
        }
        'key' { & $reply 'true'; Invoke-LauncherKey $a }
        'traffic.stop' {
            # WebView2 must not run a modal dialog inside its own event: ask just after this handler returns
            if ($script:PendingStop) { & $reply '0'; return }
            $script:PendingStop = @{ View = $View; Id = [int]$Msg.id }
            [void]$form.BeginInvoke([Action]{ Complete-StopAllTraffic })
        }
        default { & $fail ('unknown command: ' + [string]$Msg.cmd) }
    }
}

function Initialize-LauncherView {
    param($View, [string]$Page)
    $View.add_CoreWebView2InitializationCompleted({
        param($sender, $e)
        if (-not $e.IsSuccess) {
            [Windows.Forms.MessageBox]::Show("WebView2 failed to start:`n$($e.InitializationException.Message)`n`nInstall the Evergreen WebView2 Runtime from Microsoft.", $AppName, 'OK', 'Error') | Out-Null
            $form.Close(); return
        }
        $core = $sender.CoreWebView2
        $core.SetVirtualHostNameToFolderMapping('launcher.ui', (Join-Path $Root 'ui'), [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
        $core.Settings.AreDefaultContextMenusEnabled = [bool]$Debug
        $core.Settings.AreDevToolsEnabled = [bool]$Debug
        $core.Settings.IsStatusBarEnabled = $false
        $core.add_NewWindowRequested({ param($s, $a) $a.Handled = $true })
        $core.Navigate('https://launcher.ui/' + $sender.Tag)
    })
    $View.add_WebMessageReceived({
        param($s, $a)
        $msg = $null
        try { $msg = $a.WebMessageAsJson | ConvertFrom-Json } catch { return }
        try { Invoke-LauncherCommand $s $msg } catch { }
    })
    $View.add_NavigationStarting({ param($s, $a) if ($a.Uri -notmatch '^https://launcher\.ui/') { $a.Cancel = $true } })
    $View.Tag = $Page
}
Initialize-LauncherView $rail 'rail.html'
Initialize-LauncherView $panelView 'panel.html'

# ---------------------------------------------------------------- timer: page events every 250 ms, status every 2 s
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$script:Tick = 0
$timer.add_Tick({
    $script:Tick++
    foreach ($t in @($script:Tabs)) {
        if ($t.State -ne 'ready') { continue }
        try { foreach ($json in @(Invoke-DashFn $t 'Receive-DashEvents')) { if ($json) { Send-View $t.WebView ([string]$json) } } } catch { }
        if ($script:Tick % 8 -eq 0) {
            try { $t.Status = Invoke-DashFn $t 'Get-DashStatus' } catch { $t.Status = @{ Error = $_.Exception.Message } }
        }
    }
    if ($script:Tick % 8 -eq 0) { Test-RunningModules; Push-RailState }
    if ($script:CatalogJob -and $script:CatalogJob.Handle.IsCompleted) { Complete-CatalogCheck }
    if ($script:UpdProc) { Watch-Updater }
    if ($script:InstallProc) { Watch-Install }
})

# ---------------------------------------------------------------- start and close
$form.add_Shown({
    [void](Update-Tabs)
    [void]$rail.EnsureCoreWebView2Async($null)
    [void]$panelView.EnsureCoreWebView2Async($null)
    $first = $null
    foreach ($want in @($Open, $script:Settings.lastTab)) {
        if ($want -and $script:ById.ContainsKey($want) -and @('unloaded', 'declined') -contains $script:ById[$want].State) { $first = $want; break }
    }
    if (-not $first) { $f = $script:Tabs | Where-Object { $_.State -eq 'unloaded' } | Select-Object -First 1; if ($f) { $first = $f.Id } }
    if (-not $first -and $script:Tabs.Count) { $first = $script:Tabs[0].Id }
    if ($first) { Select-Tab $first } else { Show-Notice }
    $timer.Start()
    Start-CatalogCheck -MinMinutes 60
    Start-UpdateCheckIfDue
})

$form.add_FormClosing({
    $timer.Stop()
    if ($script:CatalogJob) { try { $script:CatalogJob.Ps.Stop(); $script:CatalogJob.Ps.Dispose() } catch { } }
    try { if ($script:UpdProc -and -not $script:UpdProc.HasExited) { $script:UpdProc.Kill() } } catch { }
    try { if ($script:InstallProc -and -not $script:InstallProc.HasExited) { $script:InstallProc.Kill() } } catch { }
    foreach ($t in @($script:Tabs)) {
        if ($t.Init) { try { Invoke-DashFn $t 'Stop-Dash' | Out-Null } catch { } }
    }
    $nb = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
    $script:Settings.bounds = @{ x = $nb.X; y = $nb.Y; w = $nb.Width; h = $nb.Height; max = ($form.WindowState -eq 'Maximized') }
    Save-Settings
})

[Windows.Forms.Application]::Run($form)
try { $script:AppMutex.ReleaseMutex(); $script:AppMutex.Dispose() } catch { }
