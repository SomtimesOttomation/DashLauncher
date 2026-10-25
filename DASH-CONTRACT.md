# Dash contract (version 1)

How a dashboard ("dash") plugs into DashLauncher while still running on its own.
A dash that follows this document can be copied into DashLauncher's `modules` folder and appears as a tab, with no launcher code changes.

Everything here targets Windows PowerShell 5.1 + WebView2, no installer, no admin rights, no build step.

## In one paragraph

A dash ships two extra things: a `dash.json` manifest in its root folder, and a backend PowerShell module that exports
the functions below. The backend never touches a window or a WebView2. Whoever hosts it (the dash's own thin
`Start-*.ps1`, or DashLauncher) creates the window and the WebView2, and hands the backend a **context** object to talk
through. The page code does not change: it keeps calling `bridge.request(cmd, args)` and listening for `{event, data}`.

## Folder layout

```
DashLauncher\
  Start-DashLauncher.bat
  core\                     the launcher's own PowerShell module
  modules\                  dashboard modules, one folder each
    NBADash\                a dash
      dash.json             required, read by the launcher
      Start-NBADash.bat     standalone entry point (thin host)
      modules\NBADash.Host.psm1   the backend module named in dash.json
      ui\                   the page, served as https://<id>.ui/
```

The launcher looks one level deep in its `modules` folder for `*\dash.json` when it starts and when the person presses
"Scan for modules" at the bottom of the tab rail. A dash listed in the launcher's `catalog.json` is trusted once the
person installs it; any other dash is loaded only after the person approves it, and the launcher asks the first time it
finds one. If a scan finds a running
dash's folder (or its `dash.json`) gone, the launcher calls its `Stop-Dash` and removes its tab. Between scans, the launcher checks every 2 seconds
that each running dash's `dash.json` still exists; if not, it calls `Suspend-DashWorker` and covers the dash with a
notice offering Close or Reload. A dash still runs standalone
from its own `.bat`, wherever its folder sits, including inside `modules`.

## Getting listed in the launcher

DashLauncher's `catalog.json` lists known dashes by id and GitHub repo. A listed dash that is not installed shows as a
greyed tab once its repo has a published release (not a draft or pre-release) at or above the catalog's `minVersion`;
its page has an Install button and manual steps. For that to work, the release zip must have `dash.json` at its root (or
inside one top folder), and the release must attach `<zip name>.sha256`: Install downloads both, checks the checksum,
checks the `dash.json` id matches the catalog, and puts the dash in `modules\<repo name>`. An existing folder is never
replaced. If GitHub cannot be reached, the
last answer seen is used; `"published": true` in `catalog.json` shows a dash regardless, and `false` hides it.

## dash.json

```json
{
  "contract": 1,
  "id": "nbadash",
  "name": "NBA",
  "title": "NBA 2026-27",
  "versionFile": "VERSION",
  "icon": "ui/img/tab-icon.svg",
  "backend": "modules/NBADash.Host.psm1",
  "ui": "ui",
  "entry": "index.html",
  "standalone": "Start-NBADash.bat",
  "dataSources": [
    { "name": "ESPN public endpoints", "terms": "https://example.com/terms" }
  ]
}
```

| Field | Required | Rule |
| --- | --- | --- |
| `contract` | yes | Integer. The launcher refuses a dash whose number is higher than it supports and says "needs a newer DashLauncher". |
| `id` | yes | `^[a-z][a-z0-9]{1,19}$`, unique among installed dashes. `launcher` is reserved. |
| `name` | yes | Tab label, 1 to 12 characters. |
| `title` | yes | Window title while the tab is active, 1 to 60 characters. |
| `versionFile` | yes | Relative path to a file whose trimmed content is `X.Y.Z`. |
| `icon` | yes | Relative path to an `.svg` or `.png`, drawn at 32 x 32. |
| `backend` | yes | Relative path to the `.psm1` backend module. |
| `ui` | yes | Relative path to the folder served as `https://<id>.ui/`. |
| `entry` | yes | File inside `ui` to open, normally `index.html`. |
| `standalone` | yes | Relative path to the dash's own `.bat` entry point. |
| `dataSources` | no | Third-party sources the dash fetches from, each with `name` and a `terms` URL. Shown on the launcher's About page. |

Every relative path must stay inside the dash folder: no `..`, no leading `\` or `/`, no drive letter, no UNC path, and
the file or folder must exist. A manifest that breaks any rule is listed as broken with the reason, and none of its code
is loaded. Fields the launcher does not know are ignored, so optional fields added later in contract 1 do not
break older launchers. The machine-readable version of these rules is `schema/dash.schema.json`.

## Host names

| Host name | Maps to | Who maps it |
| --- | --- | --- |
| `https://<id>.ui/` | the dash's `ui` folder | the host |
| `https://<id>.cache/` | the `CacheDir` returned by `Initialize-Dash` | the host |

The host cancels navigation to anything else and blocks pop-ups. These are the same names the dash uses standalone, so
page code that builds `https://nbadash.cache/...` URLs keeps working in the launcher.

## Backend module

The host imports the module named in `backend` and calls these functions. All except the worker run on the host's UI
thread, so each call must return quickly (aim for under 50 ms) and must never wait on the network. Slow work goes to the
dash's worker runspace or a child process, as NBADash already does.

| Function | Called when | Must |
| --- | --- | --- |
| `Initialize-Dash -Context $ctx` | The dash is first needed (tab opened, or master sync) | Load settings, create folders, take the host lock. Return the init result below. Must not start fetching. |
| `Start-DashWorker` | The tab becomes visible | Start the worker, or resume it if paused, unless the kill switch stopped it. |
| `Suspend-DashWorker` | The tab is hidden | Stop timed fetching (live polling, auto refresh). Finish requests already queued. A sync the person started keeps running, with its progress reported through `Get-DashStatus`. |
| `Invoke-DashCommand -Message $msg` | The page sends `{id, cmd, args}` | Validate every argument and answer through `Context.Post` with `{id, ok, data}` or `{id, ok:false, error}`. |
| `Receive-DashEvents` | Every 250 ms while initialized | Return an array of JSON strings, each an `{event, data}` message for the page (worker output, sync and updater progress). Return at most 25 per call. |
| `Get-DashStatus` | Every 2 seconds while initialized | Return the status hashtable below. No network, no disk scans. |
| `Stop-DashTraffic` | The person presses the launcher's kill switch | Stop all traffic to the dash's data sources: cancel running syncs and queued data requests, stop live refresh, and pause the worker, visible tab included. Update checks and downloads (GitHub) are not affected. Change no saved settings. Tell the page traffic was stopped; only the person resumes it, from inside the dash. |
| `Stop-Dash` | The host is closing | Stop child processes and the worker, release the host lock, within 2 seconds. |
| `Invoke-DashSync -Scope 'quick'` | Optional. The launcher's master sync runs (built but switched off for now; see below) | Start the dash's own quick sync and return `$true`, or `$false` if one is already running. Progress shows through `Get-DashStatus`. A dash without this function is skipped by the master sync. |

Several dashes run in one launcher process, and every backend exports the same function names. So the launcher calls
each backend through its own module object, never by bare name, and a backend must not rely on being imported into the
global scope. Any helper module a backend imports must have a name unique to that dash (NBADash uses `Nba.Data`), because
PowerShell keeps one module per name per process.

### Init result

```powershell
@{
    Ok             = $true                 # $false when the dash cannot start here
    Reason         = ''                    # 'locked' when the dash is already open in another host, else a message
    CacheDir       = 'C:\Users\...\AppData\Local\NBADash\cache'
    WebViewDataDir = 'C:\Users\...\AppData\Local\NBADash\webview2'
}
```

The host maps `<id>.cache` to `CacheDir` and creates the dash's WebView2 with `WebViewDataDir` as its profile folder,
so browser storage (sorts, filters) is the same standalone and in the launcher.

### Status hashtable

```powershell
@{
    Live            = 2          # items live right now (games in progress); 0 when none
    Syncing         = $true
    SyncPct         = 40         # 0-100, or $null when unknown
    UpdateAvailable = '0.12.0'   # newer version found by the dash's own updater, or $null
    Error           = $null      # short message when the backend is unhealthy
    Traffic         = @{ Requests = 412; Bytes = 3145728; Errors = 0 }   # the dash's own counter, this session
}
```

The launcher shows `Traffic` per dash, exactly as each dash counts it. It adds no total and never changes a dash's
counting.

## Kill switch

The launcher has one button that stops all traffic to data sources happening right now: it calls `Stop-DashTraffic`
on every initialized dash. It is for the sports data sources only; update checks and downloads keep working. There is no matching "start all". After a stop, each dash stays quiet until the person resumes it
inside that dash; switching tabs does not resume it.

## Context object

The host builds this before `Initialize-Dash` and keeps it for the dash's lifetime.

| Member | Type | Standalone host | DashLauncher |
| --- | --- | --- | --- |
| `Mode` | string | `'standalone'` | `'launcher'` |
| `Root` | string | the dash folder | the dash folder |
| `Post` | scriptblock `{ param([string]$Json) }` | posts to its own WebView2 | posts to that dash's WebView2 |
| `Close` | scriptblock | closes its window | closes the whole launcher |
| `Relaunch` | string | full command line: the dash's quoted `.bat` path | full command line, arguments included: `"<launcher folder>\Start-DashLauncher.bat" -Open <id>` |
| `HostPid` | int | its own process id | the launcher's process id |
| `Theme` | string | `''` (the dash uses its own setting) | `'light'`, `'dark'` or `'system'` |
| `LauncherVersion` | string | `''` | the launcher's version |
| `Debug` | bool | `-Debug` switch | `-Debug` switch |

`Post` may only be called on the UI thread, which is where `Invoke-DashCommand` and `Receive-DashEvents` run. The
worker runspace never calls it; it queues messages for `Receive-DashEvents` instead.

## Reserved for the launcher

- Messages whose `cmd` starts with `launcher.` are the launcher's own. In launcher mode it handles them and never passes
  them to `Invoke-DashCommand`, so a dash must not use that prefix for its own commands.
- Ctrl+1 to Ctrl+9, Ctrl+Tab and Ctrl+Shift+Tab switch tabs. After each page load the launcher adds a small key
  listener to the dash page that sends `launcher.key` messages, so a dash should not use those shortcuts itself.

## Host events

The host also pushes these to the page. A page that ignores them still works.

| Event | Data | Sent when |
| --- | --- | --- |
| `host.visible` | `{}` | the tab is shown again after being hidden |
| `host.hidden` | `{}` | the tab is hidden |
| `host.theme` | `{ "theme": "dark" }` | the launcher theme changes, and once after load in launcher mode |

In launcher mode a dash hides its own theme toggle and follows `host.theme`.
On `host.visible` a dash refetches only if its own automatic refresh setting is on; otherwise it shows how old its data
is and waits for the person to refresh.

## Master sync (built, switched off)

The launcher contains the plumbing for a manual "Sync all": it would call `Invoke-DashSync` on each dash in turn, one at a
time, behind a warning confirmed on every use. It is switched off: there is no button, and the setting that would show
it is not exposed. Dashes may implement `Invoke-DashSync` now so they are ready, but nothing calls it until master sync
is switched on in a later release.

## Host lock

`Initialize-Dash` takes a named mutex `Local\DashHost-<id>` and `Stop-Dash` releases it. If the mutex is already held,
the dash is open in another host (for example its own window), so `Initialize-Dash` returns `Ok = $false` and
`Reason = 'locked'`. The launcher then shows "NBA is open in its own window" instead of a second copy writing the same
cache and settings.

## Updates

Each dash keeps its own updater. When an update is applied, the dash calls `Context.Close`, and its apply helper waits
for `Context.HostPid` to exit and then runs the `Context.Relaunch` command line as given. Installed from the launcher,
an update therefore reopens the launcher with that dash's tab already open (`-Open <id>`), so the dash's page loads and
can confirm the new version started, exactly as it does standalone. If the dash fails to initialize or its page never
loads, nothing confirms and the dash's own updater rolls back.

A dash confirms a new version when its page loads, not in `Initialize-Dash`: page load proves the backend and the UI
both work. A dash never edits the launcher's files, and the launcher never edits a dash's files: the launcher's own updater
leaves the `modules` folder alone.

## Fetching rules

These are part of the contract, not suggestions.

1. Nothing contacts a third-party server on its own by default. Fetching happens when the person asks for it.
2. Automatic refresh, polling and scheduled syncs are opt-in, behind a plain warning and an acknowledgement, with every
   interval adjustable and clamped.
3. A hidden tab fetches nothing on a timer (`Suspend-DashWorker`).
4. A new data source's terms are read before the dash uses it, and the source is listed in `dataSources`.
5. A dash bundles no third-party data. It fetches on the person's own computer and caches locally.

## Versioning

This is contract version 1. Adding an optional function, field or event keeps the number. Changing or removing a
required one raises it, and the launcher keeps supporting the previous number for at least one release.

## Checklist for a new dash

`samples\SampleDash` in the DashLauncher repo is a complete, no-network example to copy.

- [ ] `dash.json` passes `schema/dash.schema.json`, and every path exists inside the folder.
- [ ] The backend exports the eight required functions; nothing in it creates a window or loads WebView2.
- [ ] The standalone `.bat` works with DashLauncher absent.
- [ ] Opening the dash in the launcher while it is open standalone shows the locked message.
- [ ] A hidden tab makes no timed requests.
- [ ] After the kill switch, no data source is contacted until the person resumes inside the dash (update checks may still run).
- [ ] Its release zip has `dash.json` at the root; extracted into DashLauncher's `modules` folder, it appears as a tab after Scan for modules.
- [ ] Every data source is listed in `dataSources`, and its terms have been read.
- [ ] Helper module names are unique to the dash (for example `Nba.Data`, not `Data`).
- [ ] No `launcher.*` commands of its own, and no Ctrl+1 to Ctrl+9 or Ctrl+Tab shortcuts.
- [ ] Scripts are ASCII-only (Windows PowerShell 5.1 misreads other characters).
