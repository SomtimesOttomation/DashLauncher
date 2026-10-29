# Drop-in updates

Drop a DashLauncher or dashboard module zip here, for example `DashLauncher-v0.6.0.zip` or `NBADash-v0.15.0.zip`, while
DashLauncher is open. Within a few seconds a message at the bottom right asks whether to apply it.

- **Apply** runs the usual update. DashLauncher updates itself and restarts; a module is updated in place (its old files
  are backed up and put back if anything fails) and DashLauncher restarts on the same tab; a module that is not installed
  yet is installed.
- **Not now** leaves the zip here. DashLauncher asks again the next time it starts.

The zip can have its files at the top or inside one folder. If a `.sha256` file with the same name sits beside it
(as on GitHub release pages, for example `NBADash-v0.15.0.zip.sha256`), the zip must match it. A zip that is not newer
than what you have is left alone. Applied zips are moved to the `applied` folder; delete them whenever you like.

DashLauncher's own updates never change this folder.
