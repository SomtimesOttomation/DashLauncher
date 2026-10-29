# Sample Dash

A small dashboard module that contacts nothing. It has two jobs:

1. **Try DashLauncher without a real dashboard.** It can pretend there are live games, an update or a problem, and run a
   fake 8-second sync, so every tab badge, the stop button, the theme and tab switching can be tested offline.
2. **Start a new dashboard.** It is the smallest complete example of the dash contract
   ([DASH-CONTRACT.md](../../DASH-CONTRACT.md)). Copy the folder, rename it, and replace the fake parts.

## Try it in DashLauncher

1. Copy the `SampleDash` folder into DashLauncher's `modules` folder.
2. Press **Scan for modules** at the bottom of the tab rail (or restart DashLauncher).
3. It isn't in the launcher's list of known modules, so DashLauncher asks before adding it. Say yes.

## Run it on its own

Double-click `Start-SampleDash.bat`. The first run downloads the WebView2 files into `lib\`, as NBADash does.

## What is in it

| File | What it is |
| --- | --- |
| `dash.json` | The manifest DashLauncher reads: id `sample`, name, title, paths. |
| `modules\Sample.Host.psm1` | The backend: the eight contract functions plus the optional `Invoke-DashSync`. |
| `Start-SampleDash.ps1` / `.bat` | The thin standalone host: window, WebView2, context, timer. |
| `ui\` | The page: `index.html`, `app.css`, `app.js`, and `bridge.js` for talking to the host. It has the shared navigation bar ([docs/NAVBAR-SPEC.md](../../docs/NAVBAR-SPEC.md)) with its live-status pause switch. |
| `VERSION` / `CHANGELOG.md` | The version (`X.Y.Z`) and the labelled changelog (Unreleased first, then released versions). |

## Starting a new dashboard from it

1. Copy the folder and rename it, for example `F1Dash`.
2. In `dash.json`, set a new `id` (lowercase, for example `f1dash`), `name`, `title`, and list every data source and its
   terms in `dataSources`.
3. Rename `modules\Sample.Host.psm1` (for example `F1Dash.Host.psm1`) and point `backend` at it. Any helper module you
   add needs a name unique to your dash.
4. In the backend and `Start-SampleDash.ps1`, replace `sample` in the lock name (`Local\DashHost-sample`), the host names
   (`sample.ui`, `sample.cache`) and the `SampleDash` data folders with your id and name.
5. Keep the navigation bar as it is (same order, look and keys as NBADash). Change only what search looks for (players,
   drivers, clubs) and what Refresh refetches. Clicking the live status must keep sending `traffic.stop` / `traffic.resume`.
6. Reset `VERSION` to `0.1.0` and clear `CHANGELOG.md` down to an empty Unreleased section.
7. Replace the fake ticks and sync with real fetching, in a worker runspace or child process as NBADash does, and keep
   the rules: nothing fetched until the person asks, automatic refresh opt-in, a hidden tab fetches nothing on a timer.
8. Check it with `tools\Test-DashContract.ps1 -Path <your folder>` from the DashLauncher repo.

## Release zip (drop-in update)

While the dash repos are private, every release also ships as a drop-in update: `<Name>-vX.Y.Z.zip` plus
`<Name>-vX.Y.Z.zip.sha256`. Saved into DashLauncher's `updates` folder, the launcher checks the checksum and the
`dash.json` id, backs up, installs and restarts on that tab.

- The zip is a complete copy of the dash at the release commit, with `dash.json` and `VERSION` at its root.
- Leave out `lib\`, `update\`, `.git\`, test screenshots and scratch files.
- The folder name comes from the zip name with `-vX.Y.Z` removed, so name it after the dash folder (`F1Dash-v0.3.0.zip`).
- The `.sha256` file holds the zip's SHA-256 hash in lowercase hex.

In PowerShell, from the dash folder (replace the name and version):

```powershell
$name = 'SampleDash'; $ver = (Get-Content VERSION).Trim()
$zip  = "..\$name-v$ver.zip"
$keep = Get-ChildItem -Force | Where-Object { $_.Name -notin 'lib', 'update', '.git' }
Compress-Archive -Path $keep.FullName -DestinationPath $zip -Force
(Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() | Set-Content -Encoding ascii -NoNewline "$zip.sha256"
```

Run `tools\Test-DashContract.ps1 -Path <your folder>` from the DashLauncher repo before handing the zip over.
