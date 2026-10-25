# DashLauncher

One window for several sports dashboards, with the sports as tabs on the side.
Each dashboard lives in its own repo and still runs on its own; DashLauncher only holds the glue.

Windows PowerShell 5.1 + WebView2. No installer, no admin rights, no build step.

## First run

1. Unzip DashLauncher anywhere, for example `C:\Tools\DashLauncher`.
2. Double-click `Start-DashLauncher.bat`. On first run it downloads the WebView2 wrapper DLLs into `lib\` (no admin
   needed). The WebView2 runtime itself ships with Edge.
3. Published dashboards show as greyed tabs. Click one: its page links to the latest release on GitHub. Download the
   zip, extract it into DashLauncher's `modules` folder (the page shows the exact folder), and press **Refresh**. The
   tab turns to colour and opens.
   ```
   C:\Tools\DashLauncher\
     Start-DashLauncher.bat
     modules\
       NBADash\
   ```
4. A module you copy in yourself that is not in the launcher's list is added after you say yes.
5. Click a tab on the left to switch sports. The bottom of the rail has:
   - **Scan for modules**: looks in the `modules` folder again (it also looks every time DashLauncher starts).
   - **Theme**: follows Windows, light or dark, for the launcher and every dashboard.
   - **Stop**: stops all traffic to every dashboard's data sources after you confirm. Update checks keep working.

A dashboard can run in one place at a time. If NBADash is already open in its own window, the NBA tab says so and
offers to switch to that window.

`Start-DashLauncher.bat -Debug` turns on DevTools in every view.

## Checking a dashboard

`tools\Test-DashContract.ps1 -Path modules\NBADash` checks a dashboard against the contract without opening a window or
fetching anything. Close the dashboard first. `tests\Test-Manifest.ps1` checks the launcher's own dash.json rules.

## Status

| Phase | What | Where |
| --- | --- | --- |
| 0 | The dash contract and manifest schema | this repo (done) |
| 1 | NBADash split into a backend module and a thin host, with no visible change | [NBADash](https://github.com/SomtimesOttomation/NBADash) (done) |
| 2 | Launcher v0.1: window, tab rail, NBA tab, first-run approval | this repo (in testing) |
| 3 | Launcher v0.2: a no-network Sample dash, tab badges, keyboard switching | this repo |
| 4 | Launcher v0.3: updater and release workflow (never touches `modules`) | this repo |
| 5 | v1.0: more sports plug in through their own `dash.json` | each sport's repo |

## How a dashboard plugs in

Each dashboard module is a folder inside `modules`, with a `dash.json` in its root and a backend module the launcher
loads. A module that is not in the launcher's list is loaded only after you say yes. A module still runs on its own from
its own `.bat`. The full rules are in [DASH-CONTRACT.md](DASH-CONTRACT.md), and the manifest
can be checked against [schema/dash.schema.json](schema/dash.schema.json).

## Which modules are offered

`catalog.json` lists the dashboards DashLauncher knows about. A listed one that is not installed shows as a greyed tab
once its GitHub repo has a published release at or above `minVersion`. DashLauncher asks GitHub at start (at most once an
hour) and on Scan for modules (at most every 10 minutes), only while a listed module is not installed, and remembers the
last answer for when GitHub cannot be reached. To show a module regardless, set `"published": true` for it in
`catalog.json`; `false` hides it. Setting `"catalogCheck": false` in `%APPDATA%\DashLauncher\settings.json` stops the
GitHub check.

## Fetching

The launcher never fetches sports data itself; it only asks GitHub about published modules (above). Each dashboard keeps its own rules: nothing is fetched until you ask,
automatic refresh is opt-in, and a hidden tab fetches nothing on a timer. The stop button stops all traffic to every
dashboard's data sources at once; update checks are not affected. There is no button that starts traffic in every
dashboard.

## Disclaimer

DashLauncher is an unofficial personal project, not affiliated with any league, team or data provider. It bundles no
third-party data.

## License

MIT. See [LICENSE](LICENSE).
