# Sample Dash

A dashboard module that contacts nothing: its teams, games and "servers" are made up. It has two jobs:

1. **Try DashLauncher without a real dashboard.** Its Settings page has Sample tools: pretend live games, an update
   or a problem (for the launcher's tab badges), and pretend that downloads fail. A season sync with a real progress
   bar runs against the fake servers, so the stop button, the rail's sync ring and tab switching can all be tested offline.
2. **Start a new dashboard.** It is built the way NBADash and NHLDash are, with every piece a dash needs from day one
   (see SAMPLE-DASH-GAPS.md in the project knowledge), so a new dash only swaps in its own data source.

## Try it in DashLauncher

1. Copy the `SampleDash` folder into DashLauncher's `modules` folder.
2. Press **Scan for modules** at the bottom of the tab rail (or restart DashLauncher).
3. It isn't in the launcher's list of known modules, so DashLauncher asks before adding it. Say yes.

## Run it on its own

Double-click `Start-SampleDash.bat`. The first run downloads the WebView2 files into `lib\`, as NBADash does.

## What is in it

| Piece | Where | What it does |
| --- | --- | --- |
| Manifest | `dash.json` | What DashLauncher reads: id `sample`, name, title, paths, data sources. |
| Backend | `modules\SampleDash.Host.psm1` | The eight contract functions plus `Invoke-DashSync`. A worker runspace fetches one key at a time, caches it, counts traffic per server (last 40 requests) and reports sync progress. |
| Standalone host | `Start-SampleDash.ps1` / `.bat` | Window, WebView2, context, timer. |
| Page | `ui\` | `index.html`, `app.css` (NBADash's colours, sizes and card layout), `app.js`, `bridge.js`. |
| Team banner | `app.js`: `renderBanner` | Logo tiles, several starred favourites first with a divider, scroll buttons, mouse wheel, active team in its colour. |
| Week bar | `app.js`: `renderWeekBar` | Full width under the banner, left aligned: Season, Sync, then a link per saved week. |
| Season sync | `sync.run` + `bridge.on('sync')` | Downloads the season a week at a time with real progress on the page and on the launcher's rail; saved weeks are not downloaded again. |
| Game cards | `app.js`: `gameCard` | NBADash's layout: 68 px logos, code over name and record, 26 px score, dimmed loser, gold edge for favourites. |
| Navigation bar | `index.html` | The shared bar ([docs/NAVBAR-SPEC.md](../../docs/NAVBAR-SPEC.md)) with its live-status pause switch. |
| Traffic page | `#/traffic` | Requests, data and errors per server, and the last 40 requests. |
| Hover cards | `app.js`: `GLOSS` | Every abbreviation and calculated number explains itself: add the term and any table heading with that text gets a hover card. |
| Failed-request rule | `app.js`: `want()` | A failed item waits for Refresh (F5); it is never re-requested on a redraw. |
| Updater | `Update-SampleDash.ps1`, `Apply-Update.ps1`, `update.*` commands, version button | Same as NHLDash: check, download, verify against `.sha256`, swap after closing, relaunch, roll back if the new version does not start. |
| Release workflow | `.github\workflows\release.yml` | On a published GitHub release: checks the tag matches `VERSION`, checks scripts are ASCII-only, builds and attaches `<RepoName>-vX.Y.Z.zip` + `.sha256`. |
| Version and changelog | `VERSION` / `CHANGELOG.md` | `X.Y.Z` and the labelled changelog (Unreleased first). |

Settings live in `%APPDATA%\SampleDash`, cache and the WebView2 profile in `%LOCALAPPDATA%\SampleDash`, never in the
dash's own folder, so updates (the dash's own or DashLauncher's) never wipe them.

## Starting a new dashboard from it

1. Create the GitHub repo first, named after the dash (for example `F1Dash`). The release workflow names the zip after
   the repo, so nothing in it needs changing.
2. Copy this folder into the new repo, `.github` included.
3. Rename everywhere, matching case:
   - `SampleDash` to your name (`F1Dash`): file names (`Start-`, `Update-`, `.Host.psm1`), data folders, the updater's
     repo (`SomtimesOttomation/F1Dash` in `Update-F1Dash.ps1`) and its required-files list.
   - `sample` to your id (`f1dash`): `dash.json`, the lock name `Local\DashHost-sample`, host names `sample.ui` / `sample.cache`.
   - `Sample Dash` to your title in `dash.json` and `index.html`; `SAMPLEDASH_` test hooks to your name.
4. In `dash.json`, list every data source and its terms in `dataSources` (keep the GitHub one for the updater).
5. In the backend, replace the worker's `Invoke-FakeServer` with real downloads (NHLDash's `Get-Bytes`) and the keys in
   `Resolve-DataKey` with your source's. Keep the rules: nothing fetched until the person asks, automatic refresh opt-in
   with a warning, a hidden tab fetches nothing on a timer, the pause switch stops everything but update checks.
6. In the page, replace `TEAMS` and `logo()` with your source's teams (cache real logos on disk, as NHLDash does),
   adapt the views, and add your terms to `GLOSS`. Keep the navigation bar, banner, week bar and card styles as they are.
7. Turn `updateCheck` on by default in `New-DefaultSettings` (the Sample keeps it off so it contacts nothing).
8. Remove the Sample tools card and `sample.set`, reset `VERSION` to `0.1.0` and clear `CHANGELOG.md` to an empty
   Unreleased section.
9. Check it with `tools\Test-DashContract.ps1 -Path <your folder>` from the DashLauncher repo: 0 problems, and the
   release workflow and updater reported as present.

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
