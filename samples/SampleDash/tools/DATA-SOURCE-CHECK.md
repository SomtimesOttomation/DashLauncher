# Data-source check (do this before building any feed)

NBADash started with a probe script and a short private report; this is the same check as a template. Write the report
in your private design notes (not in the repo), and run `Probe-Source.ps1` once per candidate source.

## 1. Report outline

For 2 to 4 candidate sources:

| Source | Covers | Access and limits | Terms (quoted) | Risks |
|---|---|---|---|---|
| name + URL | competitions, seasons, data types | key needed? rate limit, size of responses | the exact sentences, each marked **primary** (the source's own terms page), **secondary** (someone else's summary) or **UNVERIFIED** | breaking changes, missing tiers, odds in responses, account data in responses |

Then:

- **Pass / fail table**: one row per need (fixtures, live scores, tables, rosters, logos...), one column per source.
- **Ranking**: which source to use for what, and why. Prefer sources that need no key; manual fetching by default,
  automatic refresh only as an opt-in with a warning (DASH-CONTRACT.md, "Fetching rules").

## 2. Probe rules (`Probe-Source.ps1` follows them)

- About 15-25 requests in total, one a second (slower if the terms ask).
- Keys come from an environment variable or a hidden prompt. Never print them, save them, commit them or put them in the
  update zip. In the dash, keys live in the person's settings file (`%APPDATA%\<Name>`).
- Output goes to `tools\probe-output\`, which is git-ignored.
- Only whitelisted fields are printed or saved, so odds and betting fields never appear.
- Account names and e-mails are redacted: some sources return them in a header or the body (football-data.org does).
  Check the output yourself before sharing it with anyone, a chat included.
- After the probe, list every source you will use in `dash.json` `dataSources` with its terms URL.
