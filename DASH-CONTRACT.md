# Dash contract (version 1)

How a dashboard ("dash") plugs into DashLauncher while still running on its own.
A dash that follows this document can be dropped next to DashLauncher and appears as a tab, with no launcher code changes.

Everything here targets Windows PowerShell 5.1 + WebView2, no installer, no admin rights, no build step.

## In one paragraph

A dash ships two extra things: a `dash.json` manifest in its root folder, and a backend PowerShell module that exports
the functions below. The backend never touches a window or a WebView2. Whoever hosts it (the dash's own thin
`Start-*.ps1`, or DashLauncher) creates the window and the WebView2, and hands the backend a **context** object to talk
through. The page code does not change: it keeps calling `bridge.request(cmd, args)` and listening for `{event, data}`.

## Folder layout

```
<any folder>\
  DashLauncher\             the launcher
  NBADash\                  a dash
    dash.json               required, read by the launcher
    Start-NBADash.bat       standalone entry point (thin host)
    modules\NBADash.Host.psm1   the backend module named in dash.json
    ui\                     the page, served as https://<id>.ui/
```

The launcher scans the folders listed in its settings (default: its own parent folder) for `*\dash.json`, one level
deep. It never loads a dash the person has not approved; the first time a new dash is found it asks first.

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
is loaded. The machine-readable version of these rules is `schema/dash.schema.json`.

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
| `Stop-DashTraffic` | The person presses the launcher's kill switch | Cancel running syncs, update downloads and queued requests, and pause the worker, visible tab included. Change no saved settings. Tell the page traffic was stopped; only the person resumes it, from inside the dash. |
| `Stop-Dash` | The host is closing | Stop child processes and the worker, release the host lock, within 2 seconds. |
| `Invoke-DashSync -Scope 'quick'` | Optional. The launcher's master sync runs (built but switched off for now; see below) | Start the dash's own quick sync and return `$true`, or `$false` if one is already running. Progress shows through `Get-DashStatus`. A dash without this function is skipped by the master sync. |

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

The launcher has one button that stops all traffic happening right now: it calls `Stop-DashTraffic` on every
initialized dash. There is no matching "start all". After a stop, each dash stays quiet until the person resumes it
inside that dash; switching tabs does not resume it.

## Context object

The host builds this before `Initialize-Dash` and keeps it for the dash's lifetime.

| Member | Type | Standalone host | DashLauncher |
| --- | --- | --- | --- |
| `Mode` | string | `'standalone'` | `'launcher'` |
| `Root` | string | the dash folder | the dash folder |
| `Post` | scriptblock `{ param([string]$Json) }` | posts to its own WebView2 | posts to that dash's WebView2 |
| `Close` | scriptblock | closes its window | closes the whole launcher |
| `Relaunch` | string | command line: the dash's `.bat` | command line: `Start-DashLauncher.bat -Open <id>` |
| `HostPid` | int | its own process id | the launcher's process id |
| `Theme` | string | `''` (the dash uses its own setting) | `'light'`, `'dark'` or `'system'` |
| `LauncherVersion` | string | `''` | the launcher's version |
| `Debug` | bool | `-Debug` switch | `-Debug` switch |

`Post` may only be called on the UI thread, which is where `Invoke-DashCommand` and `Receive-DashEvents` run. The
worker runspace never calls it; it queues messages for `Receive-DashEvents` instead.

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
both work. A dash never edits the launcher's files, and the launcher never edits a dash's files.

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

- [ ] `dash.json` passes `schema/dash.schema.json`, and every path exists inside the folder.
- [ ] The backend exports the eight required functions; nothing in it creates a window or loads WebView2.
- [ ] The standalone `.bat` works with DashLauncher absent.
- [ ] Opening the dash in the launcher while it is open standalone shows the locked message.
- [ ] A hidden tab makes no timed requests.
- [ ] After the kill switch, nothing fetches until the person resumes inside the dash.
- [ ] Every data source is listed in `dataSources`, and its terms have been read.
- [ ] Scripts are ASCII-only (Windows PowerShell 5.1 misreads other characters).
