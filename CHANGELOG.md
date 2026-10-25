# Changelog

Changes are grouped by label: Feature, Bug/Fix, Redesign, Housekeeping. Every merged change lands under Unreleased first and moves to a version heading when that release is published.

## Unreleased

**Feature**
- Launcher window with sport tabs down the left side; each dashboard opens in its own view and only the visible one runs.
- Dashboard modules live in DashLauncher's `modules` folder. They are found at start and with the Scan for modules button.
- Published dashboards that are not installed show as greyed tabs, with a link to the latest GitHub release and steps to install; Refresh turns the tab on.
- Asks before adding a newly found dashboard that is not in the launcher's list, and shows dashboards with a broken dash.json without loading them.
- Detects a dashboard already open in its own window and offers to switch to it.
- If a running dashboard's folder is removed, it is paused and covered with a notice to close it or reload it once the folder is back.
- Messages appear at the bottom right of the window, like NBADash's.
- One theme for the launcher and every dashboard: follows Windows, light or dark.
- Stop button that stops all traffic to every dashboard's data sources after you confirm; update checks keep working. Each dashboard resumes only from inside itself.
- Reopens on the right tab after a dashboard update (`-Open`).

**Housekeeping**
- Dash contract version 1 (DASH-CONTRACT.md) and the dash.json schema.
- Contract notes: backends are called through their own module, helper module names must be unique, unknown dash.json fields are ignored.
- `tools\Test-DashContract.ps1` checks a dashboard against the contract; `tests\Test-Manifest.ps1` checks the dash.json rules.
- README, license and changelog.
