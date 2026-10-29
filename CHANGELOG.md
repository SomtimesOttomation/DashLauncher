# Changelog

Changes are grouped by label: Feature, Bug/Fix, Redesign, Housekeeping. Every merged change lands under Unreleased first and moves to a version heading when that release is published.

## Unreleased

**Feature**
- Sample dash: the shared navigation bar with the live-status pause switch, plus a changelog and release-zip steps in its README, so a new dash starts with NBADash's look and the current release flow.

## Released

### v0.6.0

**Feature**
- Drop-in updates: a DashLauncher or dashboard module zip dropped into the new `updates` folder is noticed within about 5 seconds, and a message asks whether to apply it. Apply runs the usual update and restart (or installs a new module); Not now asks again next start. A `.sha256` beside the zip is checked, and applied zips move to `updates\applied`.

### v0.5.0

**Feature**
- Update dashboard modules from the launcher's update page: an "Also check my dashboard modules for updates" box (off by default) lists each installed module's version and any update, and you tick which ones to update. DashLauncher updates them with a checked download, backup and rollback, then restarts on the same tab.

**Housekeeping**
- Contract: how a launcher-run module update works, and a checklist line that a dash keeps its settings and data outside its folder.
- The update and notice pages scroll when the window is too short for them.

### v0.4.1

**Housekeeping**
- Shared navigation bar spec for every dash (`docs/NAVBAR-SPEC.md`, copied from NBADash), linked from the contract's checklist.
- Contract: every dash handles the page commands `traffic.stop` and `traffic.resume` and sends the `traffic` event; the Sample dash and `tools\Test-DashContract.ps1` follow.
- Navigation bar spec: live status is a button that pauses and resumes all data traffic, with a stronger live blink.

### v0.4.0

**Feature**
- The window's title bar follows the theme (dark or light, in the launcher's colours) instead of always white, and the corners are rounded on Windows 11.
- Restart & Reload button on the tab rail: closes DashLauncher and starts it again on the same tab, so an updated module dropped into `modules` runs its new files. It asks first if a dashboard is syncing or a module is installing.

### v0.3.0

**Feature**
- One-click Install on a greyed module's page: downloads the release, checks its checksum and dash.json, and turns the tab on. Manual steps stay as a fallback.

**Bug/Fix**
- A moved or second copy of DashLauncher now always looks in its own modules folder, not the first copy's.

**Housekeeping**
- README: moving an installed dashboard into `modules` means turning its nightly sync off and on again.
- Contract: `Context.Relaunch` is spelled out as a full command line.

### v0.2.0

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
- Ctrl+1 to Ctrl+9 jump to a tab; Ctrl+Tab and Ctrl+Shift+Tab move to the next or previous tab, even inside a dashboard.
- Updates: the version at the bottom of the rail opens an update page; a daily check at start (can be turned off), checksum-verified download, install with automatic rollback. Never touches `modules`, `lib` or settings.
- Sample module (`samples\SampleDash`): contacts nothing, pretends live games, updates, problems and a sync to test the launcher offline, and is the template for new dashboards.

**Housekeeping**
- Dash contract version 1 (DASH-CONTRACT.md) and the dash.json schema.
- Contract notes: backends are called through their own module, helper module names must be unique, unknown dash.json fields are ignored.
- Contract: `launcher.*` commands and the tab-switching shortcuts are reserved for the launcher.
- Release workflow: publishing a GitHub release builds the zip and checksum, and refuses a package that contains a `modules` folder.
- `tools\Test-DashContract.ps1` checks a dashboard against the contract; `tests\Test-Manifest.ps1` checks the dash.json rules.
- README, license and changelog.
