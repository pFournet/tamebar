# Privacy and permissions

Tamebar runs locally, without a telemetry SDK, account service, or remote AI inference.
App and process names, folder paths, and local history stay on your Mac unless you choose to share them.

## Network

The only network request is the update check in release builds. Once a day, and when you choose Check for
updates, Sparkle fetches the update feed (`appcast.xml`) from Tamebar's update server. The request carries the
app and Sparkle versions in its user agent; no system profile, identifier, or usage data is sent. A found update
downloads from the same server and installs only if its EdDSA signature matches the key built into the app.
Turn off automatic checks in Settings > Updates. Development builds have no feed and make no request.

## Local data

Local files live in `~/Library/Application Support/Tamebar` (`Tamebar-e2e` for the e2e build).
Cleanup reports dropped in BlitzClean's `~/Library/Application Support/BlitzClean/reports` folder are
also imported, read in place without changing them.

| Store | Retention and contents |
| --- | --- |
| Cleanup ledger | At most 1,000 records, including reviewed paths and measured space changes. |
| Memory incidents | At most 1,440 events from the last 24 hours, including app/tool and project names. |
| Pressure trace | Up to 240 recent samples/actions and top project summaries. |
| CPU/RAM charts | Two-second detail for 15 minutes and five-minute points for seven days; including the top app or process group by CPU and RAM; at most 1 MiB on disk. |
| File review | At most 5,000 entries / 8 MiB, including paths, sizes, identity metadata, and scan time. |
| Old-file choices | The chosen age and the paths you marked Keep, in app preferences. |
| Media exports | At most 100 completed records / 512 KiB, including input/output paths and results. |

Persisted JSON files have owner-only permissions.
File filters, navigation, dismissed crash reports, project choices, and selected scan roots also survive relaunch.

The `com.tamebar.Tamebar` preference domain stores notification choices, project settings, and start commands.
It also stores explicit container-to-project assignments by container ID and folder path.
The emergency helper retains its process inventory only in memory and registers one global shortcut.
It does not record keystrokes, read conversation bodies, or require Accessibility to register that shortcut.
On first launch, Tamebar copies BlitzClean's `com.blitzreels.BlitzClean` preferences and
`~/Library/Application Support/BlitzClean` files once, never overwriting its own. BlitzClean's data is
left unchanged, and Tamebar reads `BlitzClean/reports` in place.

Do not put secrets directly in saved commands; use the project's environment setup instead.
Process arguments are read locally to identify tools, but incident histories do not retain arguments or credentials.

Developer browsing reads package manifests and Git metadata without fetching remote branches, querying GitHub, or running npx.
Directory listings, recursive scans, duplicate hashing, and media processing run locally.

AI session naming reads bounded local title indexes and Claude session identity records.
For Codex CLI, an open rollout filename can identify the session; its conversation body is not read.
Cursor metadata is read through a read-only database connection; message blobs and encryption keys are not used.
Session titles stay in the live process list and are not added to monitoring history.

No conversation contents, window text, environment variables, or stack dumps are collected into the monitoring history.
A project or app name can itself be sensitive, so review exports before sharing.

## Permissions and connections

Settings > Finish setup lists the permissions that are still missing. No page asks on its own.

- Tamebar posts no macOS notifications and never asks for that permission; what it does on its own
  shows as a brief note by the notch or in the menu bar.
- Files and Folders access can be required for protected locations; denied paths are reported.
  Full Disk Access may be needed to inspect more protected macOS data, and does not bypass every system restriction.
- Accessibility enables window-response checks; no window text is logged for recovery.
- Local HTTP probes identify listening ports and can cause a development server to serve or compile a page.
- Opening a port launches its local address in your browser.
- Package tools, saved server commands, Docker, and external cleanup tools follow their own network/permission behavior.
- FFmpeg/FFprobe are optional local installations, not bundled downloads.

The app's code signature affects how macOS remembers permissions.
Ad-hoc rebuilds or a changed signing identity can require granting access again.

## Actions and lifetime

Personal-file removal uses Trash; Tamebar never empties it.
Confirmed cache/developer cleanup can permanently delete rebuildable items after revalidation.

Normal Quit/Stop actions are immediate; Force Quit and bulk termination require inline review.
Automatic project pausing requires per-project consent and never deletes data or kills apps.

Monitoring continues when the main window closes; quit Tamebar to stop it.
Saved server commands are not automatically stopped when Tamebar quits.

A system-wide stall can stop Tamebar too: it is not a separate recovery daemon.
Local pressure traces cannot establish the cause of a kernel panic.
