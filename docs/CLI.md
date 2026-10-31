# Command line

`tamebar` answers "what is using this Mac" from a terminal or an agent, without opening the app. It never
pauses, quits or slows anything, never changes Tamebar's settings, never takes `autopause.lock`, and never
sends a signal. Acting stays with you and with Tamebar itself. It writes only markers, the start hook's
files and the hook itself: `tamebar mark` appends one line to `usage-markers.jsonl` (decisions Q16),
`tamebar wait` registers itself in `waiting/` and `tamebar start` writes a release file there (decisions
Q19), and `tamebar hooks install|remove` edits Claude Code's and Codex's hook files (decisions P2); every
other command is read-only.

```sh
tamebar status [--json]                  # memory, CPU, disk, top apps, call, what Tamebar did
tamebar sessions [--all] [--json]        # Claude and Codex sessions by RAM
tamebar stopped [--json]                 # what Tamebar stopped, and the command to bring it back
tamebar history [--since 24h] [--json]   # pressure events and samples with the top apps
tamebar trend [--days 14] [--compare <marker|version|day>] [--json]
                                         # time under memory pressure per day, before and after
tamebar mark "<text>"                    # add a marker to the trend
tamebar wait                             # start hook: a new session waits while the Mac is struggling
tamebar start <project|all>              # start the sessions waiting for memory
tamebar hooks install|remove|status      # the start hook in Claude Code and Codex
tamebar --help | tamebar help <command>
```

Exit codes: `0` success, `1` `mark` couldn't write its line, `start` found nothing waiting or a hook file
couldn't be read or changed, `2` bad usage
(`wait` always exits `0`; the message and a pointer to
`--help` go to stderr).

## How it runs

The CLI is the app's own executable. `TamebarEntry` hands the arguments to `CLI.run` when the first one is a
bare word (`status`, `sessions`, `stopped`, `history`, `trend`, `mark`, `wait`, `start`, `hooks`, `help`, or an unknown
word, which is bad usage) or `--help`/`-h`.
The app's own flags all start with a dash, so they still launch the app. The command runs and exits before
anything of the app starts: no `NSApplication`, no window, no Dock icon, no brand migration, no Emergency
controls helper.

`./scripts/install.sh` links `~/.local/bin/tamebar` to `~/Applications/Tamebar.app/Contents/MacOS/Tamebar`. It
replaces a link that already points into a `Tamebar.app`, and leaves anything else at that path alone with a
warning. The installers make the same link: the Homebrew cask through its `binary` stanza, the curl
installer (`install.sh`) as `~/.local/bin/tamebar`. Only a copy dragged out of the DMG by hand has none (see
[Installing](INSTALL.md)).

Data sources, all the app's own code:

| What | Source |
|---|---|
| RAM, swap, pressure | `MemoryGuardSample`, `MemoryPressureReader` (kernel level) |
| Verdict | `PressureEvaluator` on this one reading |
| CPU, disk | `SystemMetricsProvider`, CPU measured over 0.5 s |
| Top app by RAM and CPU | `CPUProcessReader.leads`, the same leads as the sidebar and history (helpers count toward their app, command-line tools split by project) |
| Call | `CallSignals.read`: mic or camera in use, no permission, nothing captured |
| Heat | `ProcessInfo.thermalState` through `SystemMetricsProvider`; whether Tamebar acts, from `autopause.json` |
| AI sessions | `DevProcessScanner` (`AIThreadGrouping`, `AIThreadNames`) |
| Protections | `SessionKeeps`, Keep running projects, `UnusedPolicy.serving`, `BackgroundJobs` |
| Resume command | `EndPlan.entry(...).resumeCommand`, as the Stopped list copies it |
| Stopped | `StoppedLog.entries`, the list on the window's Activity tab: the auto-pause and app ledgers in `autopause.json`, Ended sessions (`sessions.ended.v1`), apps quit from the panel (`apps.quitByYou.v1`), dev servers ended with their session (`servers.ended.v1`) and Codex plugins turned off (`codex-plugins.json`) |
| Codex plugins | `codex-plugins.json` (`CodexTrimState`): what Q21 turned off, and its last count of the rollouts' calls |
| Tamebar's state | `autopause.json` (`AutoPauseWiring.Record`), `background.json` (`BackgroundPriority.Record`) |
| History | `memory-history.json`, `resource-history.json`, `pressure-latest.json` |
| Trend | `usage-daily.json` (the app's daily record), `usage-markers.jsonl` |
| Strain, waiting | `strain.json` (written by the running Tamebar), `waiting/<pid>.json` and `.go` |

Files are decoded with the app's decoders but never through its `load`: an unreadable file is reported in
`notes` and left where it is (the app would move it aside). Saved projects are decoded without the app's
backup of an unreadable value. Settings come from the `com.tamebar.Tamebar` domain whichever path ran the
binary. The live numbers are always a fresh scan, so they are right when Tamebar isn't running; the output
then says so, and Tamebar's state is what it saved last.

`TAMEBAR_STATE_DIR` points the command at another data folder. Tests use it with fixtures.

## Speed

Measured on a 16 GB Mac on 2026-10-27 (16 GB under memory pressure, 17 GB swap, 18 AI sessions), release
build run through a symlink, three runs each: `status` 0.58–0.60 s (0.5 s of it is the CPU window),
`sessions` 0.64–0.95 s, `history` 0.05 s. A debug build takes about 1.0 s and 1.3 s. `sessions` is dominated by `lsof` for
listening ports and `ps`; under heavy memory pressure `lsof` can take longer. If it gets slow, the fix is to
let `sessions` skip ports (`serving` unknown) or read Tamebar's last scan instead of scanning again.

`wait` when the Mac isn't struggling, measured on 2026-10-30 with the installed build: 12–24 ms on its own;
inside a `claude -p` start, Claude's debug log read "finished with status 0 (106ms)", alongside its other
`SessionStart` hooks (110–140 ms), so a normal start isn't held.

## JSON

Every report has `"schema": 1`, `"command"` and `"generated_at"`. Keys are snake_case, sizes are integer
bytes (`*_bytes`), percentages are numbers (`cpu_percent`, 100 is one core for a process, all cores for the
Mac), dates are ISO 8601 in UTC. A key is always present; `null` means unknown. New keys may be added
within schema 1; a removed or changed key bumps the schema.

### `status`

```json
{
  "schema": 1, "command": "status", "generated_at": "2026-10-27T10:57:28Z",
  "memory": { "total_bytes": 17179869184, "available_bytes": 3120660480,
              "compressed_bytes": 6421200896, "swap_used_bytes": 16520642560, "pressure": "warning" },
  "assessment": { "risk": "critical", "limit": "memory", "title": "Memory and disk under pressure",
                  "advice": "Avoid starting new threads or builds. ..." },
  "cpu": { "percent": 42.4 },
  "disk": { "free_bytes": 16072912896, "total_bytes": 494332366848 },
  "top": { "memory": { "name": "Google Chrome", "bytes": 7330784168 },
           "cpu": { "name": "Xcode", "percent": 65.6 } },
  "call": { "mic": false, "camera": false, "active": false },
  "thermal": { "state": "nominal", "acting": false },
  "automatic": { "end_idle_sessions": false, "trim_codex_plugins": false,
                 "protected_ports": [], "kept_codex_servers": [] },
  "codex_plugins": { "checked_at": "2026-10-30T22:41:00Z", "applied": true,
                     "turn_off": ["cubic", "context7", "plugin code-review@openai-bundled"],
                     "calls": { "mcp_server_github": 67, "cua_repl": 791 }, "held": null,
                     "off": ["cubic", "context7", "code-review@openai-bundled"] },
  "strain": { "struggling": true, "since": "2026-10-30T11:02:10Z",
              "signals": [ { "kind": "fan", "value": 78.2, "state": null, "text": "fan 78%" } ],
              "waiting": [ { "project": "dashboard-app", "tool": "claude", "tool_name": "Claude",
                             "directory": "/Users/me/code/dashboard-app",
                             "session_id": "601f93df-...", "agent_pid": 4242, "wait_pid": 4250,
                             "since": "2026-10-30T11:03:00Z", "waited_seconds": 64 } ] },
  "tamebar": {
    "running": true, "pid": 91564,
    "data_directory": "/Users/me/Library/Application Support/Tamebar",
    "notes": [], "last_tick": "2026-10-27T10:56:54Z", "pressure_since": "2026-10-27T09:15:23Z",
    "auto_paused": [ { "id": "claudeCode-4242-1799990000", "kind": "session", "tool": "claude_code",
                       "tool_name": "Claude Code", "pid": 4242, "project": "notes", "directory": null,
                       "reason": "pressure", "since": "..." } ],
    "quit_apps": [ { "bundle_id": "com.tinyspeck.slackmacgap", "name": "Slack",
                     "memory_bytes": 1000000000, "quit_at": "...", "confirmed": true } ],
    "slowed": [ { "group": "ai:claudeCode-4242-1799990000", "kind": "session",
                  "label": "Claude Code · notes", "process_ids": [777], "executables": ["node"],
                  "slowed_at": "...", "bundle_id": null, "cpu_percent": null },
                { "group": "app:ChatGPT", "kind": "app", "label": "ChatGPT", "process_ids": [888],
                  "executables": ["ChatGPT Helper"], "slowed_at": "...",
                  "bundle_id": "com.openai.codex", "cpu_percent": 490 } ],
    "in_call": false
  }
}
```

- `memory.pressure`: the kernel's level, `normal`, `warning`, `critical` or `unknown`.
- `assessment`: the app's verdict. `risk` is `normal`, `growing`, `warning` or `critical`; `limit` the
  bottleneck, `none`, `memory`, `disk` or `cpu`; `advice` is empty when there is nothing to do. CPU strain
  needs 15 s of history, so a single reading never reports it.
- `cpu.percent` is `null` if it couldn't be measured. `call` is `null` when the probe failed.
- `thermal.state`: macOS's thermal state now, `nominal`, `fair`, `serious` or `critical` (`unknown` if
  macOS adds a level). `thermal.acting`: the running Tamebar is acting on heat (decisions Q13): serious or
  critical has held 30 s and nominal or fair hasn't held 60 s since. Always false when Tamebar isn't
  running. The text output prints it as a `Heat` line.
- `strain` (decisions Q19): whether the Mac is really struggling, as the running Tamebar judges it from its
  2-second readings (`strain.json`): any of swap-ins averaged over 30 s above 4,000 pages/s while pressure is
  warning or critical (`swap`, `value` in pages/s), the fan averaged over 60 s above 70 % of its max (`fan`,
  `value` in percent; absent without a fan or when AppleSMC can't be read), the thermal state serious or
  critical (`heat`, with `state`), or pressure critical (`critical`). It clears after 60 s with none.
  `struggling` is `null` when no running Tamebar wrote the file (its pid and start time are checked), and
  `signals` is empty unless struggling. `waiting`: the new sessions held at start by `tamebar wait`, oldest
  first, not yet released. The text prints `Strain   struggling (fan 78%)`, `Strain   none` or
  `Strain   unknown, Tamebar isn't running`, then one `Waiting  dashboard-app · Claude, 1m · tamebar start
  dashboard-app` line per session.
- `codex_plugins` (decisions Q21): `null` until the running Tamebar has counted the Codex rollouts once.
  `checked_at`: that daily count; `calls`: MCP calls in the last 30 days by server (name lowercased, `-`
  read as `_`); `turn_off`: what that run turned off (`applied` true when it wrote the file); `held`: why
  nothing may be turned off (fewer than 30 days of rollouts, or one that couldn't be read); `off`: what
  Tamebar turned off and is still off. The text prints `Codex    off by Tamebar, no call in 30 days: cubic,
  context7 (checked Oct 30 22:41)`.
- `automatic` (decisions P2): the switches and lists of Settings, Automatic actions, read from the
  settings (see [Settings](#settings)). The text prints an `Auto` line, `watches and slows only`, or what is on:
  `ends idle sessions · turns off unused Codex plugins · never ports 3000 · never Codex chat`.
- `tamebar.auto_paused`: what Tamebar paused itself (`kind` `session` or `project`, `reason` `pressure`,
  `meeting`, `heat` or `queue`). Since decisions Q18 an idle session is paused for a call or heat only;
  `pressure` is a dev-server project (or a session an older build paused). `queue` is a session an older
  build's work queue stopped (Q14), until Tamebar resumes it at its first scan (decisions Q19: running
  sessions are never held for memory); the text prints it as a `Paused` line. `project` is null for a session whose process is gone. `quit_apps`: apps Tamebar quit under
  pressure and will reopen once memory recovers (`confirmed` false while the quit is in flight). `slowed`:
  processes it moved to background priority, by the Memory/CPU row they belong to. `kind` is `session` (a
  busy session's heavy children), `workload` (a terminal job) or `app` (an app busy in the background,
  decisions Q17: over 150 % CPU for 2 minutes, not in front; restored in front or after 60 s under 50 %).
  An app's `label` is its name, with its `bundle_id` and its `cpu_percent` when it was slowed; both are null
  for the others. The text output prints an app as `Slowed   ChatGPT, in the background (490% CPU)`. `in_call`: something is
  paused for a call. `pressure_since`: memory pressure has held since then by the app's clocks; `last_tick`:
  the last scan it planned from.

### `sessions`

```json
{
  "schema": 1, "command": "sessions", "generated_at": "...", "tamebar_running": true,
  "all": false, "min_bytes": 100000000, "total": 18, "hidden": 0, "incomplete": false,
  "sessions": [ {
    "id": "claudeCode-10587-1792484332", "tool": "claude_code", "tool_name": "Claude Code",
    "project": "web-frontend", "directory": "/Users/me/Documents/Repo/web-frontend",
    "title": "web-frontend", "pid": 10587, "memory_bytes": 489000000, "cpu_percent": 0.4,
    "state": "idle", "agent_status": "idle", "idle_seconds": 90000, "idle_since": "...",
    "paused_by": null, "pause_reason": null, "paused_since": null,
    "protected": true, "protections": ["serving", "background_job"], "ports": [5175],
    "detached": false, "session_id": "ec01dd88-...",
    "resume_command": "cd '/Users/me/Documents/Repo/web-frontend' && claude --resume ec01dd88-..."
  } ]
}
```

- Sorted by `memory_bytes`, largest first. Without `--all`, sessions under `min_bytes` (100 MB) are counted
  in `hidden` and left out.
- `tool`: `claude_code`, `codex_cli`, `codex_desktop`, `cursor_agent` or `other_agent`.
- `state`: `paused` (every process stopped), else `busy` (the agent reports busy or a shell), `idle`, or
  `unknown` (the agent publishes no state). Since decisions Q19 nothing is `queued`. `agent_status` is what the agent wrote: `busy`, `idle`, `shell`
  or `null`. `idle_seconds` and `idle_since` are set when the agent says it is idle.
- `paused_by`: `tamebar` when Tamebar's ledger holds the pause (with `pause_reason` `pressure`, `meeting`,
  `heat`, or `queue` for a session an older build queued until Tamebar resumes it, and `paused_since`),
  else `user`; `null` when not paused.
- `protections`: `kept` (Keep on its row), `kept_project` (inside a Keep running project), `serving` (something
  it started listens on a port; `ports` lists them), `background_job` (something it started still runs).
  `protected` is true when any applies. Busy isn't listed here; it is the `state`.
- `resume_command` is set for Claude Code and Codex CLI sessions with a session id and a folder.
- `incomplete`: `ps` or `lsof` returned partial output, so a session or a port may be missing.

### `stopped`

```json
{
  "schema": 1, "command": "stopped", "generated_at": "...", "tamebar_running": true, "notes": [],
  "total": 4,
  "stopped": [ {
    "id": "app:com.docker.docker", "kind": "app", "name": "Docker Desktop",
    "tool": null, "tool_name": null, "directory": null, "session_id": null,
    "bundle_id": "com.docker.docker", "stopped_at": "...", "state": "quit", "reason": "by_you",
    "idle_days": null, "memory_bytes": 9000000000, "resume_command": "open -a Docker"
  }, {
    "id": "ended:601f93df-...", "kind": "session", "name": "Atlas", "tool": "claude_code",
    "tool_name": "Claude Code", "directory": "/Users/me/code/Atlas",
    "session_id": "601f93df-...", "bundle_id": null, "stopped_at": "...", "state": "ended",
    "reason": "idle", "idle_days": 3, "memory_bytes": 2000000000,
    "resume_command": "cd '/Users/me/code/Atlas' && claude --resume 601f93df-..."
  }, {
    "id": "server:6F1C...", "kind": "server", "name": "web-frontend :5180", "tool": null,
    "tool_name": null, "directory": "/Users/me/Documents/Repo/web-frontend/apps/web",
    "session_id": "019a...", "bundle_id": null, "stopped_at": "...", "state": "ended",
    "reason": "unused", "idle_days": 2, "memory_bytes": 40000000,
    "resume_command": "cd '/Users/me/Documents/Repo/web-frontend/apps/web' && npm run dev -- --port 5180"
  }, {
    "id": "codex:server:context7", "kind": "codex plugin", "name": "context7", "tool": null,
    "tool_name": null, "directory": null, "session_id": null, "bundle_id": null,
    "stopped_at": "...", "state": "off", "reason": "unused", "idle_days": 30, "memory_bytes": null,
    "resume_command": null
  } ]
}
```

Everything Tamebar stopped that isn't back yet (decisions Q15), from the stores that record each
kind: sessions and projects it paused (`autopause.json`'s ledger), sessions it ended, on its own or
from the panel (Ended sessions), apps it quit under memory pressure (`autopause.json`'s app ledger)
and apps quit from the panel, dev servers ended with their session (decisions Q20) and Codex plugins
turned off (decisions Q21). Something quit by hand outside Tamebar isn't in it.

- Order: what needs a command first (apps, then ended sessions and servers), then Codex plugins turned
  off, then what comes back on its own (paused), newest first in each. The Activity tab lists the same entries with paused first, as its mock does.
- `kind`: `session`, `project` (a dev server paused under pressure), `app`, `server` (a dev server
  ended with its session, Q20) or `codex plugin` (an `[mcp_servers.<name>]` or bundled
  `[plugins."<id>"]` turned off in `~/.codex/config.toml`, Q21). `name` is the project's folder for a
  session or a project, the app's name for an app, `<session folder> :<port>` for a server, the
  config name for a Codex plugin.
- `state`: `paused`, `ended`, `quit` or `off` (a Codex plugin). `reason`:
  `memory`, `call`, `heat`, `idle` (ended on its own after `idle_days` idle days), `unused` (Q20: the
  session had no interaction and its server no connection for `idle_days` days, 1 at least; Q21: no Codex
  call in 30 days), or `by_you` (from Tamebar's panel). An `ended` session with `memory` was ended under memory pressure held 2 minutes,
  idle 12 h or more (decisions Q18); its text line reads `ended · memory`. An Ended sessions entry
  saved before 2026-10-29 has no flag: `idle` when it kept an idle time, else `by_you`.
- `memory_bytes`: what it held when it was stopped; a paused session's is what it holds now, and a
  paused project's is `null`.
- `resume_command`: `cd '<folder>' && claude --resume <id>` (or `codex resume <id>`) for an ended
  session, `open -a <App>` for an app (`open -b <bundle id>` when the bundle has no name), `cd '<folder>'
  && <command line>` for a server (its command as `ps` shows it, `npm run <script>` with its `--` put
  back), `null` for what comes back on its own (paused) and for a Codex plugin, whose text line reads
  `Undo in Tamebar's Stopped list` (Undo sets `enabled = true` again, and Tamebar never turns it off
  again).
- An entry leaves when the thing is back: a pause resumed, an ended session running again, an app
  launched after its quit (an app still listed with an earlier launch is the one quitting), a server
  listening on its port again from its folder, a Codex plugin back on (Undo, or `enabled = true` by
  hand). And after 30 days, Ended sessions' retention, whatever it is (a Codex plugin stays while off).
- The text prints one line per entry, `Oct 29 11:24  Atlas  session  2 GB  ended · idle 3 days`, then
  the command under it in full.

### `history`

```json
{
  "schema": 1, "command": "history", "generated_at": "...", "since": "...", "window_seconds": 86400,
  "tamebar_running": true, "notes": [],
  "events": [ { "date": "...", "kind": "pressure", "detail": "Memory running low", "pressure": "warning",
                "available_bytes": 2403860480, "swap_used_bytes": 24491786240,
                "top_apps": [ { "name": "Google Chrome", "bytes": 4898777648 } ],
                "top_projects": [ { "name": "web-frontend", "bytes": 5573847600 } ] } ],
  "samples": [ { "date": "...", "memory_percent": 88.7, "cpu_percent": 45.2,
                 "memory_lead": { "name": "Google Chrome", "bytes": 7330784168 },
                 "cpu_lead": { "name": "Notion", "percent": 51.7 } } ],
  "pressure_log": [ { "date": "...", "risk": "Memory is the bottleneck",
                      "detail": "2 GB RAM available · 20 GB swap · 14 GB disk free", "action": "",
                      "top_projects": [ { "name": "web-frontend", "memory": "6 GB" } ] } ]
}
```

- `--since` takes a whole number and `m`, `h`, `d` or `w` (default `24h`). Everything is oldest first.
- `events` (`memory-history.json`, one day): every event but routine samples. `kind` is `pressure` (the memory
  verdict changed), `disk-alert`, `app-exit`, `quit-request`, `quit-completed` or `started`. `top_apps` and
  `top_projects` are the three largest at that moment.
- `samples` (`resource-history.json`, one week): every 2 s for the last 15 minutes, then each five-minute peak,
  with the app using the most RAM and CPU at it.
- `pressure_log` (`pressure-latest.json`, about four hours): the verdict once a minute, an automatic action
  if one happened, and the projects using the most memory as the app wrote them.

### `trend`

```
$ tamebar trend --days 14
Day     Awake  Pressure        Critical  Struggling  Swap peak  AI sessions  Tamebar did
Oct 22  9h     3h 10m · 35%    40m       —           24 GB      18 · 16 GB   paused 12
Oct 23  8h     2h 50m · 35%    25m       —           23 GB      20 · 17 GB   paused 9
 ── v0.2 · Stopped log, courier fix ──
Oct 31  9h     1h 30m · 17%    5m        12m         15 GB      21 · 15 GB   ended 3

$ tamebar trend --compare v0.2
7 days before → after v0.2 (4 days)
Under pressure   35% → 17% of awake time
Critical         32 min → 5 min a day
Swap peak        24 → 15 GB
AI sessions      19 → 21 on average, so the workload didn't drop
```

One row per local day with data, oldest first, over the last `--days` days (1–366, default 14). **Awake** is
the in-use time: the Mac awake and the user present (decisions Q5: not locked, input in the last 10 min).
**Pressure** is the in-use time with memory pressure at warning or critical (`PressureAssessment.memoryRisk`),
and its share of the in-use time; **Critical** the part at critical. **Struggling** is the in-use time the
Mac was really struggling (decisions Q19, the `strain` of `status`), `—` for a day recorded before Tamebar
judged it (2026-10-30). **AI sessions** is the average count and
their average memory. **Tamebar did** counts what it did on its own: paused (sessions and projects, heat
included), ended (while away, and under memory pressure, Q18), queued (busy sessions the work queue stopped, Q14; days before Q19 removed it on 2026-10-30), quit (apps under pressure), slowed
(background priority, processes of busy background apps included), and the memory those freed where the action knows it. A marker shows as a ` ── … ──`
line after the day it was set. Several builds installed the same day show as that day's last one.

The days before the first run are the **baseline**: `resource-history.json`'s week of 5-minute RAM and CPU
peaks, imported once. Their rows read `—` for everything but `baseline · RAM peak 92% · CPU peak 81%`. Until
Tamebar has written `usage-daily.json`, the command reads the baseline from `resource-history.json` itself.

`--compare` takes a marker (its text, or any part of it; a version with or without `v`; a commit) or a day
(`2026-10-29`). It prints up to 7 days with data before the marker against up to 7 after it, saying how
many each side has. The marker's own day mixes both and counts on neither side; a day given as a date is the
first day after. Pressure is the time under pressure over the in-use time of all the side's days together;
Critical and Swap peak are daily means; RAM peak (the mean of the daily RAM peaks) shows when a side has it,
which the baseline does; AI sessions are on average, so a lighter workload shows ("so part of the change may
be a lighter workload" when 10 % fewer). An unknown marker is bad usage, with the latest markers on stderr.

```json
{
  "schema": 1, "command": "trend", "generated_at": "...", "window_days": 14, "tamebar_running": true,
  "notes": [],
  "days": [ {
    "day": "2026-10-22", "baseline": false,
    "awake_minutes": 600, "in_use_minutes": 540, "pressure_minutes": 190, "warning_minutes": 150,
    "critical_minutes": 40, "pressure_percent": 35.2, "critical_percent": 7.4,
    "cpu_saturated_minutes": 12, "hot_minutes": 0, "struggling_minutes": null, "struggling_percent": null,
    "swap_peak_bytes": 24000000000, "swap_average_bytes": 18000000000, "available_lowest_bytes": 900000000,
    "memory_peak_percent": 97.1, "memory_average_percent": 88.4, "cpu_peak_percent": 100, "cpu_average_percent": 41.2,
    "ai_sessions_average": 18.2, "ai_sessions_peak": 22,
    "ai_sessions_memory_average_bytes": 16000000000, "ai_sessions_memory_peak_bytes": 19000000000,
    "tamebar_did": { "paused": 12, "queued": 0, "ended": 0, "quit": 1, "slowed": 3, "freed_bytes": 2400000000 }
  } ],
  "markers": [ { "date": "2026-10-23T14:00:00Z", "day": "2026-10-23", "kind": "version",
                 "text": "0.2 · 4f3a2b1", "label": "v0.2 · 4f3a2b1", "version": "0.2", "commit": "4f3a2b1" } ],
  "compare": {
    "label": "v0.2 · 4f3a2b1", "day": "2026-10-23", "marker": { ... }, "workload": "same",
    "before": { "days": ["2026-10-16", "..."], "use_days": 7, "pressure_percent": 35.2,
                "critical_minutes_per_day": 32, "swap_peak_bytes": 24000000000, "memory_peak_percent": 96.5,
                "ai_sessions_average": 19, "ai_sessions_memory_average_bytes": 16000000000,
                "in_use_minutes_per_day": 540, "tamebar_did": { ... } },
    "after": { ... }
  }
}
```

- `day` is the local calendar day; a day of 23 or 25 hours (daylight saving) is split at its own midnights.
- Minutes count only while the Mac is awake; a gap of more than a minute between two of the app's 2-second
  readings is sleep or Tamebar not running, and counts as nothing. `awake_minutes` includes time away;
  pressure, critical, `struggling_minutes` (Q19's strain; `null` before it was recorded, with
  `struggling_percent` of in-use time), `cpu_saturated_minutes` (90 % CPU for 15 s) and `hot_minutes` (thermal serious or
  critical) count only in-use time. Swap, RAM, CPU and sessions are measured over all awake time.
- A baseline day has `baseline: true`, its RAM and CPU fields, and `null` for the rest.
- `compare` is `null` without `--compare`. `workload`: `lighter` (10 % fewer AI sessions after), `heavier`
  (10 % more), `same`, or `null` when a side has no sessions.
- `kind`: `version` (a new Tamebar build, set by the app at launch), `setting` (an automatic setting
  switched: "Auto-end after 7 days", "Quit under pressure: + Loom", "Auto-pause: − web", "Slow in background:
  − Chrome"), `note` (`tamebar mark`).

### `wait`

The start hook (decisions Q19): Claude Code's and Codex's `SessionStart` run `~/.local/bin/tamebar wait` with
a `timeout` of 660 s. It returns `0` at once, printing nothing, unless all of these hold:

- the hook's JSON on stdin (read for at most 2 s; none counts as a fresh start) has `source` `startup`. A
  `resume`, `clear`, `compact` or `fork` never waits, so a running session is never held;
- `strain.json` was written by a Tamebar that still runs (its pid with the same start time);
- that Tamebar says the Mac is struggling.

Then it writes `waiting/<its pid>.json` (`waitPID` and its start time, the agent's pid, the nearest `claude`
or `codex` up its parents and never past it, `tool`, `directory` from the hook's `cwd`, `project` its folder's
name, `sessionID`, `started`) and blocks on kqueue (dispatch sources, no polling) until one of: its release file
`waiting/<pid>.go` appears, Tamebar or the agent exits, SIGTERM, SIGINT or SIGHUP, or 10 minutes. It removes
both files and exits `0`. It never prints to stdout, so nothing is added to the session's context; Claude shows
its own "running SessionStart hooks… Ns" meanwhile.

Tamebar releases: once the strain clears, the oldest waiting session at once, then one every 60 s while it
stays clear (if the strain returns, the rest keep waiting); Start now on the card releases one at once. It
prunes the registrations of `tamebar wait` processes that no longer run.

### `start`

```
$ tamebar start dashboard-app
Started dashboard-app · Claude (waited 1m).
```

Starts every waiting session whose project (the folder's name, as `tamebar sessions` shows it; any case) is the
argument, or all of them with `all`, by writing their release files (`{"by": "tamebar_start", "at"}`). It needs
no running Tamebar. Nothing matched: a line on stderr naming what waits, and exit `1`.

### `hooks`

```
$ tamebar hooks install
Claude Code (~/.claude/settings.json): installed /Users/me/.local/bin/tamebar wait (backup: /Users/me/.claude/settings.json.tamebar-backup-20261031-120000)
Codex (~/.codex/hooks.json): installed /Users/me/.local/bin/tamebar wait
```

Adds the start hook (`wait`, above) to Claude Code's `~/.claude/settings.json` and Codex's
`~/.codex/hooks.json` as a `SessionStart` group holding `{"type": "command", "command": "<tamebar> wait",
"timeout": 660}`. `<tamebar>` is the absolute path of `~/.local/bin/tamebar` when that link leads to the app
running the command, else the app's executable (quoted if it holds a space). The decisions are P2's:

- A tool whose folder (`~/.claude`, `~/.codex`) doesn't exist is skipped. A missing file, `hooks` or
  `SessionStart` is created.
- Idempotent: an existing Tamebar wait (any command whose program is `tamebar` or `Tamebar` followed by
  exactly `wait`) is updated in place to this path and timeout; duplicates are removed; nothing is written
  when it already matches.
- Every other key keeps its place and its text (numbers and escapes as written); the file is written back
  with two-space indentation, as both tools write theirs, and keeps a link a link.
- Before any change, the old file is copied to `<file>.tamebar-backup-YYYYMMDD-HHMMSS` beside it. A file that
  isn't a JSON object, or whose `hooks` or `SessionStart` has another shape, is left alone (exit `1`). The
  result is parsed again before and after it is written.

`tamebar hooks remove` takes out every Tamebar wait, with a group, `SessionStart` or `hooks` it leaves
empty, after the same backup. `tamebar hooks status` reads both files and prints the hook's commands, or
`not installed`; it writes nothing. The curl installer asks once whether to run `tamebar hooks install`.

### `mark`

```
$ tamebar mark "Raised the swap limit"
Marked “Raised the swap limit” at Oct 29 14:05.
```

Appends `{"at", "kind": "note", "text"}` as one line to `usage-markers.jsonl`; the words are joined, cut to
one line of 200 characters. It needs no running Tamebar. The app writes its own markers (a new build, a
switched setting) to the same file, so both take `usage-markers.lock` (an exclusive `flock`) for the append;
the app's yearly prune rewrites the file under the same lock. The app never rewrites the daily record from a
command, and the command never touches `usage-daily.json`.

## Settings

Settings, Automatic actions, writes these keys in the `com.tamebar.Tamebar` domain; `defaults write` works
too while Tamebar runs (it reads them at each scan):

| Key | Type | Default | What |
|---|---|---|---|
| `automatic.endIdleSessions` | Bool | false | End a session idle 12 h under memory pressure held 2 min (Q18), or idle 24 h whose dev server had no connection for 24 h (Q20). |
| `automatic.trimCodexPlugins` | Bool | false | Turn off Codex MCP servers no session called in 30 days, in `~/.codex/config.toml` after a backup (Q21). |
| `protection.ports` | [Int] | [] | Ports whose servers Q20 never ends. The portless proxy (1355, 443, 80) and every port in `~/.portless/routes.json` are always added. |
| `protection.codexServers` | [String] | [] | Codex MCP server names Q21 never turns off. |
| `sessions.autoEnd.v1` | JSON | Ask me | Unused AI sessions: End after N days while away (Q10). |
| `apps.quitUnderPressure.v1` | [String] | [] | Bundle ids Tamebar may quit under memory pressure (Q11). |

```sh
defaults write com.tamebar.Tamebar protection.ports -array 3000 5173
defaults write com.tamebar.Tamebar protection.codexServers -array chat
```

On the first launch of a build with these switches, an install that ran an earlier Tamebar keeps both
switches on, as they were then (`SafeDefaultsMigration`); a new install starts with them off.

## The daily record

`usage-daily.json` is the app's: it adds each 2-second pressure reading in memory (with the latest scan's
presence and AI sessions) and writes the file atomically at most once a minute, before sleep and on quit, so
a crash loses a minute at most. Only the Tamebar that acts (the one holding `autopause.lock`, never the e2e
build) records. Days older than a year, and markers older than a year, are dropped. A year of days is about
250 KB. An unreadable file is kept aside as `usage-daily.json.unreadable-<seconds>` and the record starts
again; the command reports it in `notes` and leaves it.
