# Dashboard modules

Each dashboard module goes here in its own folder, for example:

```
modules\
  NBADash\
    dash.json
```

Published dashboards show in DashLauncher as greyed tabs: click one and press **Install**, and DashLauncher puts it
here. Or download the zip yourself, extract it into a new folder here, and press Refresh.

DashLauncher also looks in this folder every time it starts, and when you press Scan for modules. DashLauncher's own
updates never change this folder.

Moving a dashboard you already use into this folder? If it set up a Windows scheduled task (NBADash's nightly sync
does), turn that off and on again in the dashboard's Settings afterwards, so the task points at the new folder.
