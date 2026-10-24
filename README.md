# DashLauncher

One window for several sports dashboards, with the sports as tabs on the side.
Each dashboard lives in its own repo and still runs on its own; DashLauncher only holds the glue.

Windows PowerShell 5.1 + WebView2. No installer, no admin rights, no build step.

## Status

Design stage. Nothing to run yet.

| Phase | What | Where |
| --- | --- | --- |
| 0 | The dash contract and manifest schema | this repo (done) |
| 1 | NBADash split into a backend module and a thin host, with no visible change | [NBADash](https://github.com/SomtimesOttomation/NBADash) |
| 2 | Launcher v0.1: window, tab rail, NBA tab, first-run approval | this repo |
| 3 | Launcher v0.2: a no-network Sample dash, tab badges, keyboard switching | this repo |
| 4 | Launcher v0.3: updater and release workflow | this repo |
| 5 | v1.0: more sports plug in through their own `dash.json` | each sport's repo |

## How a dashboard plugs in

Put the dashboard folders next to DashLauncher:

```
Dashboards\
  DashLauncher\
  NBADash\
  F1Dash\
```

Each dashboard has a `dash.json` in its root and a backend module the launcher loads. The first time the launcher finds a
new dashboard it asks before loading it. The full rules are in [DASH-CONTRACT.md](DASH-CONTRACT.md), and the manifest
can be checked against [schema/dash.schema.json](schema/dash.schema.json).

## Fetching

The launcher never fetches sports data itself. Each dashboard keeps its own rules: nothing is fetched until you ask,
automatic refresh is opt-in, and a hidden tab fetches nothing on a timer. A kill switch stops all traffic in every
dashboard at once. There is no button that starts traffic in every dashboard.

## Disclaimer

DashLauncher is an unofficial personal project, not affiliated with any league, team or data provider. It bundles no
third-party data.

## License

MIT. See [LICENSE](LICENSE).
