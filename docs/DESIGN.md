# Product design

## October 31 Safe defaults: what ends or edits is switched on in Settings (P2)

Settings, Automatic actions, keeps its card and gains two checks, each with one caption line and one small
field, between Unused AI sessions and Apps under pressure (hairlines around the Codex block):

```
  [ ] End long-idle sessions on their own
      Idle 12 h while memory stays tight, or idle 24 h with a dev server nobody opened. Resume them …
      Never end servers on ports  [3000, 5173          ]
  ──────────────────────────────────────────────
  [ ] Turn off unused Codex plugins
      Sets enabled = false in ~/.codex/config.toml, after a backup, for a server no Codex session …
      Never turn off  [server names        ]
```

- `BlitzCheckboxStyle` checks with their label (Q18 and Q20 share the first, Q21 the second), off on a new
  install; the caption in the caption tier, secondary.
- The fields are rounded-border text fields, 220 points at most, in the body font, with a placeholder. A
  comma- or space-separated list is saved on Return or when the field loses focus, then shown back as
  read (invalid ports dropped, duplicates once). They stay editable while the check is off.
- No new screen, no first-run popup.

## October 31 Show real strain only, and free memory once (N12)

The user: "the information repeate. and memory low should be show only if it's under real pressure.
iinstead we will have it everytime", then "Yes, like this" to the mock (decisions N12). macOS
reports "warning" nearly all day on his Mac, so the notch flashed and the menu bar and the card
kept "Memory low · 2 GB free · 13 GB swap" above the card's own "Memory 2 GB free · Strain none".

```
Normal day (warning, not struggling):
  Menu bar: [icon]        Notch: nothing
  ┌────────────────────────────────────────┐
  │ Memory 2 GB free · Strain none         │
  │ Today: ended 3 · slowed 2 · 4 GB back  │
  │ ⏸ 3 stopped                          › │
  │ [Ask Claude] [Ask Codex]      Open ›   │
  └────────────────────────────────────────┘

Mac struggling (fans, swap reads, heat, critical):
  Menu bar: [⚠] Struggling · fan 78%
  Notch:    ⚠ struggling · fan 78%  (4 s)
  ┌────────────────────────────────────────┐
  │ ⚠ Memory 1.1 GB free · Struggling:     │  (orange)
  │   fan 78%                              │
  │ Today: ended 3 · slowed 2 · 4 GB back  │
  │ Waiting for memory (when any)          │
  │ ⏸ 3 stopped                          › │
  └────────────────────────────────────────┘
```

- **What counts as pressure:** Q19's strain, as the Tamebar that acts judges it (the same
  `StrainPlanner` that writes `strain.json` and `tamebar status`'s Strain line: swap reads, the fan,
  heat, critical), or macOS's memory critical. Never warning alone: a normal day shows the icon
  alone, nothing in the notch, and the card's white memory line. `IslandState.pressure` carries
  the free memory, critical, and the strain's reasons (nil for critical without strain).
- **The menu bar:** the wings' ⚠, then "Struggling · fan 78%", the first reason ("Struggling" with
  none), for as long as the strain lasts; critical without strain reads "Memory is critical · 1,1
  GB". The symbol is orange, red at critical (Status colors, as before). Its accessibility label is
  the menu bar's text, since the card has no line for it.
- **The notch:** "⚠ struggling" in the left wing and the reason in the right one ("fan 78%"), a 4 s
  flash as before: again only when it reaches critical, or comes back after the strain eased.
  Critical without strain keeps "mem" and "1,1 GB free". Full screen is N4's rule: only critical
  shows there; struggling short of critical waits.
- **The card:** no state line for pressure. The memory line itself turns orange (red at critical),
  the line and a leading ⚠ in that color, and says the strain in place of "Strain none": "Memory
  1 GB free · Struggling: fan 78%" (free memory in the card's compact format; every reason,
  comma-separated; it may wrap to a second line). Critical before the strain is judged so, or in a Tamebar that doesn't judge it, reads
  "Memory 600 MB free · Critical" in red. Free memory is on the card once.
- **Unchanged:** a call, a note, Resumed and an automatic pause keep their state line; the pause's
  card line now reads "3 paused for memory". Automatic actions keep their own triggers: this
  changes only what is shown. "Memory low" is no longer written anywhere in the app.
- **Renders** (`TAMEBAR_DESIGN_DIR`): "Island pressure" and "Island pressure critical" (the wings),
  "Island card" (a normal day at warning), "Island card pressure" (struggling, the wings' flash
  above the orange memory line), "Island card critical", "Island card waiting", and "Menu bar
  pressure" / "Menu bar critical".

## October 30 A background app: the card and one small window (N11)

The user: "we have to much things on the app, we should threat it as a bg app who manage the usage". He
picked "Card + small window" and "Remove them" for BlitzClean's disk tools (decisions N11).

- **No Dock icon.** Tamebar is an accessory app (`LSUIElement`, and the activation policy stays
  `.accessory`). Opening the window activates Tamebar and brings the window to the front; closing it
  or pressing ⌘Q keeps monitoring. A normal launch opens the window; the login item's `--background`
  launch stays quiet.
- **The hover card** (notch and menu bar alike), as mocked:
  ```
  ┌──────────────────────────────────────┐
  │ Memory 2 GB free · Strain none       │
  │ Today: ended 3 · slowed 2 · 4 GB back│
  │ Waiting for memory (when any)        │
  │ 3 stopped ›                          │
  │ [Ask Claude] [Ask Codex]      Open › │
  └──────────────────────────────────────┘
  ```
  The memory line is free memory as the menu bar formats it, then the strain (Q19): "Strain none",
  or "Struggling: fan 78%, …" with its signals while the Mac struggles (in orange since N12). "Today" counts what Tamebar did
  on its own today from the usage record (ended, quit, paused, slowed; a zero is left out) and the
  memory it freed, "Today: nothing yet" before anything. The Waiting block (Q19) shows only while a
  session waits. "N stopped ›" opens the window on Activity. Ask Claude / Ask Codex (N8) share the
  last row with a quiet "Open ›" on the right. The state line (a call, a pause, a note; not pressure since N12) still
  leads the card while one is going on, as the wings say it; it is one short line. The session rows,
  the RAM · CPU · Disk line and the heat line are gone.
- **Clicks:** Open ›, a click on the card's body, a click on the wings and a click on the menu-bar
  item in full screen all open the window. The notch panel and the menu-bar tray are gone.
- **The window:** 520 × 600 (at least 460 × 420), two tabs in a segmented control in the toolbar.
  ```
  ┌─────────── [ Activity | Settings ] ───────────┐
  │ Stopped                       [Resume all]    │
  │ ■ web-frontend          ended · 2 GB [Resume] │
  │ …                                             │
  │ Trend · 7 days                                │
  │ ▁▃▅▂▁▁▂   Before v0.2: 35% · after: 17%       │
  └───────────────────────────────────────────────┘
  ```
  Activity: the Stopped list with Resume (Q15), then the Trend card (Q16) over 7 days. Settings:
  Automatic actions with the apps list (Q11, Q17), Show Tamebar in (N9), Meetings (the Calendars
  permission and the Google Calendar row), Launch at login, Updates, then Quit Tamebar (N10) and the
  about line. ⌘, opens Settings.
- **Removed, code and tests:** the Overview, Memory, CPU, Storage (Drive, Browse, Cleanup), Revive
  apps and Projects pages, the sidebar, and BlitzClean's disk tools: large and old files, media review
  and export, worktree and cleanup reviews, quick clean, the folder explorer, the drive breakdown, the
  removal log, the storage-cleanup report import and Remove again.
- **Kept:** every automatic action (Q9, Q12, Q13, Q17 to Q21), the low-disk 4 s note once per
  episode, the CLI (`tamebar status` keeps its Disk line), the e2e, and the Emergency controls helper.

## October 30 End a session and its dev server once both have been unused 24 h (Q20)

The user: "we are always under pressure, why ?", then "End both after 24 h unused" (decisions Q20). Codex
sessions in web-frontend had been up 9 to 10 days, two of them serving vite on :5180 and :5181 with no
connection, and Q7's "serving" protection kept Q18 away from them.

- **The clock:** at each scan Tamebar notes, for every port a session serves, the last time it saw an
  established TCP connection on it (`lsof -iTCP -sTCP:ESTABLISHED`, run only while a session serves; its
  own port probes don't count). It is kept in `served-ports.json`, so a restart doesn't reset it. A port
  seen for the first time starts at that scan: nothing is judged unused retroactively.
- **The rule:** the session has had no interaction for 24 h (Q18's meaning: no turn, no keystroke in its
  terminal), every port it serves has had no connection for 24 h, none is a protected port (the ones listed in
  Settings, empty by default since P2; the portless proxy's 1355, 443 and 80, every port in `~/.portless/routes.json`, and
  anything run through `portless`), it isn't kept or in a kept project, it runs nothing else besides its
  server (Q10's background jobs, less the server's tree), and no call is on. At any pressure level, one
  session at a time; one that doesn't end isn't tried again for an hour.
- **The server:** the agent's direct child whose tree holds the listener (`npm run dev`, or the shell a
  Codex tool call started), with that tree. An MCP helper that listens isn't a dev server; it ends with the
  session.
- **The end:** after a fresh scan the session is judged again and its agent's status re-read (Q7). The
  server gets Quit (SIGTERM to its tree, a stopped process continued to take it; no SIGKILL, as every
  Tamebar Quit); once every process of it exited, the session gets Q4's Quit with Q18's re-checks right
  before its signal. A server that doesn't exit leaves the session running.
- **Shown:** one 4 s note, "Ended web-frontend and its server :5180 · 2 GB back" ("Ended web-frontend's
  server :5180 · 40 MB back" when the session itself didn't end). Both are in the Stopped list: the
  session as "ended · unused 1d" with Resume and ⧉, the server as its own row, "web-frontend :5180",
  "ended · unused 2d", whose Resume opens Terminal on `cd '<folder>' && <command line>` (the command as
  `ps` shows it, `npm run dev` with its `--` put back), with ⧉. `tamebar stopped` lists both, kind
  `session` and `server`. A server leaves the list once something listens on its port from its folder.
  ```
  │ ■ web-frontend :5180          40 MB  [Resume]  ⧉    │
  │   ended · unused 2d                                  │
  ```

## October 30 Turn off the Codex plugins nobody uses (Q21)

Each Codex session starts its own copy of every MCP server in `~/.codex/config.toml`, again for each
sub-agent: 40 to 53 helper processes and 1 to 2 GB per session. The user picked "Trim unused plugins"
(decisions Q21), then, shown the list, asked for no Settings screen ("I don't like this remove it").

- **Calls:** once a day, at any pressure level, Tamebar reads the Codex rollouts written in the last 30
  days (`~/.codex/sessions/**`, the compressed `.jsonl.zst` ones through the installed `zstd`) and counts
  the MCP calls by server: the `McpToolCall` items (`item_completed` events, code-mode calls included),
  and the `mcp__<server>` function calls of older builds. Only lines holding those markers are parsed.
  It judges nothing unless the rollouts go back 30 days and every one in the window could be read.
- **Turned off:** every `[mcp_servers.<name>]` with no call, and every bundled `[plugins."<id>"]` whose own
  MCP servers (from its `.mcp.json` in Codex's plugin cache) had none, get `enabled = false`, in that
  table only. A plugin without MCP servers (skills only) starts nothing and is left alone. chat, chat-ext
  and courier are never touched: they receive messages, which call counts don't show.
- **The edit:** never while the file was written in the last minute (a Codex session may be starting);
  a backup first (`codex-config-backups/config-<time>.toml` in Tamebar's folder, readable by the user only,
  the newest 20 kept); then one line per server, the existing `enabled` value replaced in place or
  `enabled = false` added under the table's header; nothing else in the file changes. Written beside the
  file and renamed over it, only if the file is still what was read.
- **A hand edit wins:** a server the user sets `enabled = true` (or whose key he removes) after Tamebar turned
  it off is never turned off again; one he sets `enabled = false` stays off. New sessions only: running
  ones keep their servers.
- **Shown:** one 4 s note, "Turned off 3 unused Codex plugins". Each is in the Stopped list, "context7",
  "off · unused 30d", with Undo, which turns it back on (after a backup) and never off again; it stays
  there while it is off. `tamebar stopped` lists it (kind `codex plugin`, "Undo in Tamebar's Stopped
  list"), and `tamebar status` prints a `Codex` line. Nothing else is shown.
  ```
  │ ■ context7                            [Undo]         │
  │   off · unused 30d                                   │
  ```

## October 30 New sessions wait at start while the Mac is really struggling (Q19, after spike S5)

The user: "if we start new session, we should not block the old one, just don't make the new one start", and
"when we show waiting for memory add a little button to resume" (decisions Q19, settled after S5: "Yes, these
four", "Card + CLI only", "Both, add the hooks").

- **Struggling:** any of swap-ins averaged over 30 s above 4,000 pages/s while macOS pressure is warning or
  critical; the fan averaged over 60 s above 70 % of its max (AppleSMC, no root; no fan or a failed read is no
  signal); thermal state serious or critical; pressure critical. It clears after 60 s with none. Read on the
  pressure sentinel's 2-second tick, in the Tamebar that acts: one Mach call and one SMC read per fan. "Warning"
  alone, macOS's state nearly all day on this Mac, never counts.
- **The hook:** Claude Code's and Codex's `SessionStart` run `tamebar wait` (timeout 660 s). It returns at
  once unless Tamebar is running and the Mac is struggling, and only a fresh start waits (a resume, clear,
  compact or fork never does). It prints nothing; Claude shows its own "running SessionStart hooks… Ns", and
  the prompt box still takes typing. It gives up after 10 minutes, so the session then starts anyway.
- **Release:** once the strain clears, the oldest waiting session starts at once, then one a minute, so ten
  sessions don't all start together; if the strain returns, the rest keep waiting.
- **Start now, on the hover card** (notch and menu-bar item), shown only while something waits, above the
  stopped line, with its divider; nothing changes in the notch or the wings:
  ```
  │ Waiting for memory                      │
  │ dashboard-app · Claude   1m  [Start now]│
  │ They start on their own when it eases.  │
  ```
  The title in the card's `captionEmphasis`, one row per session, oldest first (the project, the tool, how
  long it has waited in the caption tier, a small secondary Start now), the line in the caption tier. Start now
  releases that session at once and its row leaves; the card stays open. The block takes its own clicks, so a
  click beside the button never opens the panel.
- **Start now, on the command line:** `tamebar start <project|all>` prints what it started, exits 1 when
  nothing waiting matched.
- **Shown:** `tamebar status` has a Strain line ("Strain   struggling (fan 78%)", "Strain   none") and a
  Waiting line per session; the usage record counts the in-use time struggling each day, and `tamebar trend`
  shows it as a Struggling column and in `--compare`.

## October 30 Running sessions are never held for memory (Q19, removes Q14's work queue)

On October 30 at 11:30 the installed Tamebar queued (SIGSTOP) a Claude session that had been running for
11 minutes, and waited for memory to read "normal" to resume it. macOS reports "warning" nearly all the
time on this Mac, so it never came. The user: "if we start new session, we should not block the old one,
just don't make the new one start" (decisions Q19).

- **Removed:** Q14's work queue. No busy session is paused for memory, at warning or critical, for any
  length of time. Its note ("Queued 3 · memory"), the "queued" count and row in the hover card, the
  Stopped list's "queued · memory" with Run now, `state: "queued"` in `tamebar sessions`, the "Queued"
  line in `tamebar status` and "Run now in Tamebar's card" in `tamebar stopped` are gone with it. Past days
  in the usage record keep their "queued" count.
- **Upgrade:** a session an older build queued is resumed (SIGCONT, by the identities recorded at its
  stop) at the first scan after launch, whatever holds then (pressure, a call, heat), and its terminal
  gets its title back (the empty title then the pop, as before). Until that scan, a few seconds, it
  reads "paused · memory".
- **Kept:** pausing for a call (Q9) and heat (Q13), ending long-idle sessions (Q18), slowing apps in the
  background (Q17), the quit list (Q11) and the Stopped list (Q15).
- **Apps slowed together (Q17 per Q19):** once one app's trigger fires (over 150 % CPU for 2 minutes, not
  in front), every other app busy in the background now (over 150 %, not excluded) is slowed in the same
  tick, without waiting for its own 2 minutes. The note names the busiest and counts the rest ("Slowed
  ChatGPT and 2 more apps · 490% CPU").
- **Next (Q19, after spike S5):** new sessions wait at start while the Mac is really struggling, with a
  way to start now. Built on October 30, above.

## October 29 Under memory pressure, end long-idle sessions instead of pausing them (Q18)

The user: "yes" to ending the largest session idle more than 12 h once pressure lasts 2 minutes (decisions
Q18). Pausing an idle session freed nothing: on October 29 Tamebar paused 12, force-resumed each after
5 minutes, and memory never moved.

- **When:** memory at warning or critical for 2 minutes unbroken (one reading under warning, or a sleep,
  starts the 2 minutes again). Then one session every 2 minutes while it holds; it stops when pressure
  clears.
- **Which:** the largest session the agent says has been idle 12 h or more, with a resume command (a
  Claude Code or Codex CLI session with a session id and a folder). Never one with a protection (busy or
  shell, Keep, inside a Keep running project, serving a port), a background job (Q10's rule), a paused
  one, or a Codex desktop worker. It doesn't wait for the user to be away.
- **Idle means no interaction (October 30):** the 12 h run from the later of the agent's last status
  change (a message, a turn) and the last keystroke in its terminal (the later of the agent's own tty and
  its pane's, read from the tty's access time), so a session being typed in or read with the keyboard is
  never 12 h idle. A session with no terminal goes by its agent alone.
- **How:** Q10's automatic end, the same path: a fresh scan, the agent's status re-read right before the
  Quit (root first), and memory re-checked still at warning or critical. An end that doesn't land
  (became active, still running) isn't tried again in that episode.
- **Shown:** one 4 s note, "Ended Atlas · 2.0 GB back" (the folder's name, then what it held; "Ended
  Atlas" when that is unknown). The session is in the Stopped list as "ended · memory" with Resume (it
  opens Terminal on its resume command) and ⧉, and in `tamebar stopped` with its command. The usage record
  counts it in "ended".
- **No more memory pauses of idle sessions.** Under memory pressure alone nothing pauses a session: idle
  ones under 12 h are left alone, busy ones are never held (Q19). A call (Q9) and heat (Q13) still pause idle
  sessions, and what heat paused is resumed when heat clears, even under memory pressure (memory no longer
  takes it over). Opted-in dev-server projects still pause under memory pressure, and Q11's apps still
  quit after them.

## October 29 Quit Tamebar in Settings (N10)

With the menu bar off (N9), Tamebar could no longer be quit: Quit lived only in the tray's gear menu.
The user: "yes" to a "Quit Tamebar" at the bottom of Settings (decisions N10). It sits after Automatic
actions, above the about line:
```
[Quit Tamebar]  Closing the window or pressing ⌘Q keeps monitoring.
Tamebar 1.7.0. Based on BlitzClean (MIT). Your data stays on your Mac.  License
```
- A secondary small button (`SettingsQuitRow`) with the caption beside it, in the caption font and
  secondary text. One click, no confirmation, like the gear menu's.
- It calls `AppLifetime.stopMonitoringAndQuit`, the gear menu's "Stop monitoring and quit": what was
  paused is resumed, what was slowed restored, and apps quit under pressure reopened, as before.
- It shows whatever Show Tamebar in holds. The Show Tamebar in card loses its quit caption ("To exit,
  turn the menu bar on, then choose Stop monitoring and quit from its gear menu."): the way out is on
  the same page, and the gear menu keeps its own.

## October 29 macOS's own processes are never slowed (Q12, Q13, Q17)

While Q17 was checked live, CPU strain slowed callservicesd, chronod and photoanalysisd. They were a booted
iOS Simulator's copies: run as the user under `launchd_sim`, from the runtime's root
(`…/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/System/Library/…`), so no system folder matched and
each became a terminal job row of its own. `SystemExecutable` now names macOS's own code: the system
folders (`/System/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/`, `/Library/Apple/`), anything in a simulator
runtime, and any Apple platform binary except the commands in `/bin` and `/usr/bin`, the Command Line Tools
and an app's own code (Xcode's compilers read as platform binaries). On the CPU and Memory pages these
processes join the macOS services row. Every slow, whatever row it comes in, refuses them whatever their CPU,
and the restore of a listener that inherited background leaves them alone, since macOS runs some daemons in
background itself.

## October 29 Apps: slow them in the background, suggest which to quit (Q17)

The user: "about app like chatgpt we should magane this also" (decisions Q17, mockup approved). The ChatGPT app
had run at about 490 % CPU in the background for hours and Tamebar did nothing.

- **Slow in background (CPU, amends Q12).** An app with a regular activation policy that isn't in front and
  uses more than 150 % CPU for 2 minutes in a row gets Q12's lever, Darwin background priority, on its busy
  processes (10 % CPU or more each). "In a row": a reading at or under 150 % breaks the run only once the
  app has stayed under the line for 15 s, since `ps` reads a starved process low now and then (seen in e2e
  under load: 280 % with single readings of 24 %). Its CPU is its row on the CPU page: every process of its
  bundle, without AI sessions' processes, which are Q12's and Q13's. It keeps running; it is never stopped or quit. It is
  restored as soon as it comes to the front, or once its CPU has stayed under 50 % for 60 s (the hysteresis,
  so an app hovering at the line isn't slowed and restored in a loop). Back in the background it needs two
  whole minutes again, unless another app's trigger fires: then every app busy in the background (over
  150 %) is slowed with it, in the same tick (Q19). Never: the front app, an app holding the mic or camera
  (or unknown), Tamebar, an app
  with "Slow in background" unticked, an agent process (the ChatGPT app's `codex app-server`, whose workers
  would inherit background), anything on a server's line, macOS's own apps (Finder, Music, Safari: under
  `/System/`). Codex desktop workers are AI sessions here, so Q1
  holds: never a target. It goes through Q12's ledger (`background.json`): restored on quit and at the next
  launch, adopted children restored with it, only the targets' trees in e2e mode, and the user's Normal
  priority from the app's row holds for as long as Tamebar runs. Q12's own episode ending leaves a slowed app
  alone.
- **Shown:** one 4 s note when it starts, "Slowed ChatGPT · 490% CPU" ("Slowed ChatGPT and 1 more app · …"
  for several), none when it ends. The hover card adds a caption line under "Memory: normal" while an app is
  slowed, "Slowed: ChatGPT · 490% CPU" (several: "Slowed: ChatGPT, Chrome"), in the memory line's
  secondary colour. `tamebar status` lists it under `slowed` with `kind: "app"`, and the usage record counts
  its processes in "slowed".
- **Settings → Automatic actions → "Apps under pressure"** replaces the Q11 list, as mocked:
  ```
  Apps under pressure
                         Slow in background   Quit under pressure
    ChatGPT   6 GB · 490% CPU   [✓]                  [ ]   suggested
    Chrome    4 GB              [✓]                  [ ]   suggested
    Docker    9 GB              [✓]                  [ ]   suggested
    Loom      1 GB              [✓]                  [✓]
    + Add app
  Slow in background is on for every app unless you untick it.
  ```
  One row per app, by name: its icon, name, then its memory in monospaced digits (and " · 490% CPU" when
  its peak over the last hour, or its latest slow in the last day, reached the 150 % line; "Not running"
  when it isn't), then two `BlitzCheckboxStyle` checks under caption headers, "Slow in background" (on unless
  unticked; unticking stores an opt-out by bundle id, `apps.slowInBackground.off.v1`, and restores the app
  at the next scan) and "Quit under pressure" (Q11's opt-in, `apps.quitUnderPressure.v1`), then a caption
  "suggested" in the secondary colour on an app that keeps topping memory under pressure and isn't ticked.
  The list holds the apps with a setting, the suggested ones, the ones slowed in the last week, and those
  added or changed while Settings shows (a row never jumps away under the pointer). "+ Add app" is a quiet
  small button that opens the system's app chooser in Applications; the app gets a row with its defaults,
  and ticking or unticking is what keeps it. No popup ever suggests anything.
- **"Keeps topping memory":** among the three app rows using the most memory while memory pressure is at
  warning or critical, in at least 3 separate half-hours over the last 7 days (a half-hour counts once,
  however long or flappy the episode). Each scan under pressure records the half-hour in the usage record
  (`usage-daily.json`, `pressureTops`, kept 30 days); the first run takes in `memory-history.json`'s day of
  pressure events. Tamebar, macOS's apps and terminals are never suggested; ChatGPT and Claude are.
- **AI apps quit only once quiet (Q17.3).** ChatGPT (`com.openai.codex` on this Mac, `com.openai.chat`
  before) and Claude (`com.anthropic.claudefordesktop`), once ticked, are quit under Q11's rules only after
  5 minutes under 5 % CPU over their whole tree (Codex workers included), so a task running inside them is
  never killed. Otherwise they are skipped that time and the next listed app goes first. Ticked, they are no
  longer kept open as AI apps; unticked, they are never quit.

## October 29 Ask Claude / Ask Codex on the card (N8)

*Card layout superseded by N11 (October 30): the asks share the last row with Open ›.*

The user: "it miss a little button to spawn a terminal of a claude or codex to do action" (decisions N8,
mockup approved). It amends Q4 as Q15's Resume did: Tamebar opens Terminal.

- **Where:** the hover card's last rows, on the notch and under the menu-bar item (one view,
  `UsageCardView`): after the AI sessions and "5 stopped ›", a row of small secondary buttons, "Ask
  Claude" and "Ask Codex", from the card's left text edge, 8 pt over them; then Open Tamebar, unchanged.
  A button shows only while its tool is installed; with neither, there is no row.
  ```
  │ AI sessions  3 busy · 5 idle · 2 paused │
  │  …                                      │
  │ ⏸ 5 stopped                           › │
  │─────────────────────────────────────────│
  │ [ Ask Claude ]  [ Ask Codex ]           │
  │             Open Tamebar ↗              │
  ╰─────────────────────────────────────────╯
  ```
- **What a click does:** a new Terminal window in the home folder runs `cd ~ && claude '<prompt>'`
  (or `codex`), with the prompt "The Mac is under pressure. Use `tamebar status` and `tamebar
  sessions`, propose what to end or quit, and ask me before ending anything." It goes through the
  Stopped list's Resume (`TerminalLauncher`: `osascript`, `do script`), which types the command into
  the user's interactive login shell, so the bare name runs their own alias or function for it (on
  the user's Mac `agentrun run claude`). The prompt is one single-quoted word for the shell, escaped
  again for AppleScript's string; a control character gives no command. The card closes at once,
  with no grace, as Open Tamebar closes it, whether it is still growing, fading in or open; the
  button's click never reaches the card, so it never opens the panel or the tray.
- **Installed:** an executable of the tool's name on the PATH the user's interactive login shell
  sets (read once at launch, off the main thread, `$SHELL -lic`, 5 s at most), the app's PATH, or
  the known install folders (`~/.local/bin`, `~/.claude/local`, `/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.npm-global/bin`, `~/.bun/bin`, `~/.volta/bin`). The files are looked at again
  when a card opens, at most once a minute, never per frame.

## October 29 Show Tamebar in: notch, menu bar (N9)

*Where it lives: superseded by N11 (October 30): Settings is a tab of the window.*

The user: "I want to activate or desactivate the notch option" (decisions N9, mockup approved). Settings'
"Show in menu bar" card (CPU, Memory, Memory value, Disk free, Status colors), which N7 left without
effect, becomes "Show Tamebar in":
```
Show Tamebar in
  [x] Notch      wings and hover card
  [x] Menu bar   icon, state and card
Closing the window or pressing ⌘Q keeps monitoring. To exit, choose Stop monitoring and quit from
the menu bar's gear menu.
```
*The quit caption moved to Quit Tamebar at the bottom of Settings (N10, above).*
- Checkboxes (`BlitzCheckboxStyle`), the place in the primary text and what it holds in the
  secondary. Both on by default (`show.notch`, `show.menuBar`).
- **At least one stays on:** the last one on is greyed out, its help "Tamebar shows in at least one
  place."
- **No notch screen connected** (the lid closed, an external display only, a Mac without a notch):
  Notch is greyed out, the menu bar shows and its box reads on, greyed, and a caption says "No screen
  with a notch is connected, so Tamebar shows in the menu bar." It follows display changes live.
- **Notch off:** the island controller has no window, as with no notch: no wings, no notes, no hover
  card and no hover area on the notch. The menu-bar item shows everything N7 gives it, which it does
  anyway; its state still resolves every second.
- **Menu bar off:** the status item is hidden (`isVisible`; the item stays, as it holds the
  dashboard's router), and an open card or tray under it closes. The gear is only in the tray, which
  opens from the menu-bar card, so Settings' Quit Tamebar is then the way out (N10).
- Both switch live, with no relaunch.

## October 29 Trend card on Memory (Q16)

*Superseded by N11 (October 30): the card is on the window's Activity tab, over 7 days.*

The user: "I want to track the over all usage to measure if we add somethings and if the ressource is less
under pressure" (decisions Q16, approved as mocked). A card on Memory, after the leaders and before the
pressure list (`UsageTrendCard`): "Trend · 30 days" with the legend on the right (an orange "Under
pressure" swatch and a red "Critical" one), then one bar per day for the last 30 days, the share of
in-use time under memory pressure, critical (`BlitzStatusTone.critical`, red) at the bottom of the bar
under warning (`BlitzUI.warning`, orange). The scale is 0 %, half and the top, the top the highest bar
rounded up to 20 % (at least 20 %), in monospaced digits. A day without in-use time has no bar, so a
day the Mac was off is a gap. Each marker is a dashed tick after its day with its label under it, cut at
18 characters; the first and last days are named at the two ends. Under the chart, one caption line: the
latest marker's before and after ("Before v0.2: 35% · after: 17% · swap peak 24 → 15 GB"), or the
share over the window when there is no marker. Under two days with in-use time, the card is its title
and one line, "The trend starts once Tamebar has recorded two days." Native Swift Charts, no
interaction.

## October 29 Stopped: one list of what Tamebar stopped, and how to bring it back (Q15)

*Where it lives: superseded by N11 (October 30): the list is the Activity tab; "N stopped ›" opens it.*

The user, when Docker Desktop had been quit by hand: "we should have like a log of what we quit to just
with the cli see what we have to bring back and the command attach to it. also on the client I want a
list and a button to resume what we have pause" (decisions Q15, both mockups approved). It replaces
the Ended sessions list that sat under Memory's list, and amends Q4: Tamebar now opens Terminal, on
an ended session's Resume.

- **What is in it:** everything Tamebar stopped that isn't back: sessions and projects it paused
  (memory, a call, heat), sessions it ended (on its own after N idle days, or End from the panel),
  apps it quit under memory pressure, and apps quit from the panel. It is built from the stores that
  already record each one (`StoppedLog`), plus a log of panel quits, which nothing kept before. An
  entry leaves when the thing is back (resumed, the session running again, the app launched since)
  or after 30 days. Something quit by hand outside Tamebar isn't in it.
- **The card:** "5 stopped ›" over Open Tamebar, only while there is one, in the notch's card and
  the menu-bar item's: a quiet full-width 30 pt row like Open Tamebar, a pause-circle glyph and the
  words on the left in `onNotch`, the chevron in the secondary color, the panel rows' hover
  highlight, its own divider. Its click opens the tray (the notch panel on the notch) on the list;
  a click on the rest of the card still opens it on its body.
- **The tray:** the list takes the place of the tray's body, under the tray's header and above its
  footer. The body also ends with the same "5 stopped ›" as a card row, so the list is reachable
  where no card opens (full screen). The list's header is "‹ Stopped · 5" (‹ goes back to the body)
  and a secondary Resume all; then one card of rows, eight before it scrolls, and the caption "⧉
  copies the command" when a row has one. Leaving the tray or the panel brings the body back.
  ```
  ‹ Stopped · 4                                 Resume all
  ╭─────────────────────────────────────────────────────╮
  │ ⏸ Agent                       600 MB  [Resume]       │
  │   paused · call                                      │
  │ ■ Atlas                         2 GB  [Resume]  ⧉    │
  │   ended · idle 3d                                    │
  │ ■ Docker Desktop                9 GB  [Reopen]  ⧉    │
  │   quit 11:24                                         │
  ╰─────────────────────────────────────────────────────╯
  ⧉ copies the command
  ```
  A row is ⏸ (paused) or ■ (ended, quit), the name, its state and reason in the caption
  ("paused · call", "paused · heat", "ended · idle 3d"; what the user did shows its time, "quit
  11:24", "ended Oct 27"), the memory it held in SF Mono, one secondary mini button and ⧉. In the
  tray's 340 points the name and the reason stack, as the tray's other rows do; the mock's one line
  didn't fit.
- **The button:** Resume on a paused session or project is the user's
  Resume, so it stays out of automatic pauses for the rest of the episode. Resume on an ended
  session opens a Terminal window running its resume command (`osascript`, `do script`; macOS asks
  once for Automation of Terminal). Reopen opens an app in the background, as Q11's reopen does. A
  clicked button spins until the row leaves, for at most 20 s. ⧉ copies the command and reads ✓
  for 2 s. An ended session without a command has no button.
- **Resume all** resumes the paused sessions and projects and reopens the apps. It
  never resumes the ended sessions: each would open a Terminal window running its agent, so they are
  resumed one by one. It shows only when there is something it would act on.
- **The command line:** `tamebar stopped [--json]` prints the same entries, what needs a command
  first, with the command under each (docs/CLI.md).

## October 27 The menu-bar item: Tamebar's icon, the notch's state and its card (N7)

*The tray: superseded by N11 (October 30): a click on the card opens the window.*

The user: "on display without notch I want an icon ('_ .') in the tab bar, but not only the RAM … the
same info as the notch" (decisions, N7, approved as mocked on October 27). This replaces N5's
label (the free RAM while all is well, a symbol and short text otherwise) and the old dropdown on
click.

- **The icon.** The Tamebar brand mark (`assets/brand/Tamebar.icon/Assets/Mark.svg`: a rounded
  square with a dash and a dot inside), drawn in code at 16 × 16 pt (`TamebarIcon`). It is a
  template image, so the menu bar draws it in its light, dark or tinted look, and it is the item's
  image in every state.
- **The label is the icon and the notch's state**, from the same words as the wings and the card's
  line (`IslandState.text`: one function writes all three, with one symbol and one tone):
  - all is well: the icon alone, with no text (never the RAM value);
  - pressure, for as long as it lasts: the wings' warning triangle, then "Memory low · 2,0 GB"
    ("Memory is critical · …");
  - a call: the wings' calendar or mic symbol, then "Call · 2 paused", or "Call";
  - an automatic pause, for as long as it lasts: the triangle, then "2 paused";
  - "Resumed 6" for 4 s;
  - a note for 4 s, then the state under it or the icon alone: its headline, cut at 24 characters
    between words, then what Tamebar freed when the note says it ("Paused 3 idle sessions · 2.4
    GB"). The rest of the note ("resumes when memory recovers") is the card's.

  The text is the menu bar's own (the menu-bar font, monospaced digits, no color of its own).
  Only the symbol of a warning or critical state is colored (Status colors, whose switch went
  with N9; a value saved before still applies); the icon and the text never are. The item's accessibility label is the card's whole line ("Tamebar, In a
  call · 2 sessions paused"), or "Tamebar, all is well".
- **Hover (0.3 s) or click opens the notch's card under the item** (`UsageCardLive`, the same view
  and data: the state line, the machine line, AI sessions, Open Tamebar). It hangs from the menu
  bar's bottom edge, centred on the item and kept 8 pt inside the item's screen, in the island's
  black with a square top and round bottom. It follows the notch card's rules: it grows down from
  a sliver under the item in 0.3 s and shrinks back in 0.2 s (a fade under Reduce Motion); it
  closes 0.2 s after the pointer has left both the item and the card, read from the pointer
  against the frame it opens to; it never becomes key or main, never shows in a shared screen
  (`sharingType = .none`), and doesn't open in full screen. A click opens it at once; a click on
  the item while it is open closes it.
- **A click on the card's body opens the tray** (`BlitzTrayView`: the header with the gear menu,
  the event header with Resume now or the Suggested fix, Resources, the top memory users, and the
  footer with Emergency controls, Revive apps and Open Tamebar) under the item, growing from the
  card while the card fades. The notch's panel hangs from the notch and has no gear or footer, so
  the item opens the tray instead, on every Mac. A click elsewhere, Esc, the item's click, or the
  dashboard taking the keyboard closes it. In full screen, where no card opens, the item's click
  opens the tray directly. Open Tamebar on the card works as on the notch card.
- **On a Mac with a notch** the item shows the same label and card on every menu bar, the
  external display's included; the island stays on the notch.

## October 27 Heat: Tamebar acts on a hot Mac, then says so

The user chose "Act on heat" (decisions Q13). When macOS reports the Mac serious or critical for 30 s,
Tamebar slows heavy builds and tests (the CPU lever, same targets) and pauses idle sessions still
using CPU (over 5 % for the last 30 s, every protection clear); 60 s back at nominal or fair undoes
both. Busy sessions, anything during a call and the front app are never touched, and heat never
quits an app. It says so in one 4 s note, the same note as the other automatic actions: "Mac hot ·
slowed 2 builds", "Mac hot · paused 1 idle session", "Mac hot · slowed 2 builds, paused 1 idle
session"; the wing reads "Mac hot". Nothing shows when it did nothing. The state shows in three
existing places, with no new layout:

- the hover card's pressure line, "Memory: normal · Heat: serious" (fair, critical) while not
  nominal, in the line's own secondary colour;
- `tamebar status`, a `Heat` line and `"thermal": {"state", "acting"}`;
- the CPU page's advice line: "Your Mac is hot (serious). Tamebar slowed 2 builds; they return to
  normal when it cools." It keeps the old advice when Tamebar did nothing.

## October 27 No banners: Tamebar acts, then says so in the notch

The user: "the notification system is very bad, it's too spammy and I want the app proactive not
informative" (decisions, amendment 2026-10-27). Tamebar posts no macOS notification and never asks for
that permission. It acts on its own (automatic pause, background priority, the apps opted in to quit
under pressure, ending unused sessions while away), then shows one 4 s note by the notch, and in the
menu-bar text where there's no notch, saying what it did and, when known, what it freed: "Paused 3 idle
sessions · 2.4 GB · resumes when memory recovers", "Quit Loom · 1.2 GB · reopens later", "Slowed 2
builds", "Ended 2 sessions idle 9+ days · 1.1 GB". The wing shows the part before the first " · "; the
panel header shows the rest. If Tamebar did nothing, nothing shows. A note outranks the states that last
(an automatic pause, pressure); in the notch an automatic pause is that note only, while the menu-bar item
keeps "N paused" with Resume now in its tray.

Low disk is a note too, never a deletion: "Disk reserve low · 24 GB free" once when free space falls
below the 30 GB reserve, and again only after it is back above the reserve by 1 GB and later falls again.
The cleanup suggestions stay in Storage; the menu bar and tray show disk state as before.

Settings no longer has the alerts card (Memory alerts, Disk alerts, the permission status line, Send test
alert, Notification settings…), and Finish setup no longer lists Notifications.

## October 20 Tamebar: the notch island and the menu-bar state

*The notch panel and the tray: superseded by N11 (October 30): a click opens the window.*

Built as approved in decisions N1–N5 (plan Task 9.3). While all is well nothing shows
around the notch. When Tamebar acts or memory is short, black wings ease out of the notch (0.3 s ease-out, no
bounce or pulse, none under Reduce Motion): a symbol and a word on the left, a short line on the right. They
use `BlitzUI.notchFill` and `onNotch` in light and dark, since the camera housing is black. A click opens the
tray's body under the notch, led by one event header (title, detail, at most one button: Resume now, or the
Suggested fix under pressure); a click elsewhere or Esc closes it. The island never appears in a shared screen.
Without a notch, and on every menu bar, the menu-bar item shows Tamebar's icon and the same state (rewritten
October 27, N7, above: the icon alone while all is well, the card on hover or click, and the tray from the
card), and its tray opens with the same header. The header is one view (`IslandEventHeader`) and the tray body one view
(`TrayBody`), shared by both surfaces. One filled accent per view still holds: the header's button, else the
fix, else Open Tamebar.

Memory pressure (warning or critical, nothing paused) is a 4 s flash around the notch, like the resumed
flash and the notes (N2, amended October 23: the user doesn't want it on screen for good). It shows again only
when it gets worse (warning to critical) or comes back after memory calmed; a level that holds, or dips and
returns, stays quiet. In full screen critical shows the same way, as a 4 s flash. Once the flash is over the
notch shows what comes next, such as a note on what Tamebar did. The menu-bar item and its tray keep the
pressure for as long as it lasts, and an open panel keeps its pressure header (for at most a minute) while
the pressure lasts. A call shows for as long as it lasts; "N paused" does in the menu bar, and since
October 27 the notch shows a pause as its 4 s note only.

The island follows the built-in screen's notch through display changes (a display plugged in or out, the
lid, the arrangement or a resolution): it moves and resizes at once, and goes when no notched screen is on.

Hovering the notch for 0.3 s shows a usage card under it (N6, October 27), whatever the island shows,
hidden included. It grows out of the notch, or out of the notch and the wings while they show (they stay up
under it): it starts at that shape in `notchFill` and widens and drops to its full size over the wings' 0.3 s ease-out, its content fading in; it shrinks back in 0.2 s
once the pointer has left both the notch and the card for 0.2 s. "Left" is read from where the pointer
is against the frame the card opens to, with the notch, the wings and 6 pt around, never the window's
frame while it grows: moving down while the card still grows keeps it opening, with no grace started,
and coming back while it shrinks grows it again at once from where it is (the user, October 27: "The
expansion should not close and open"). Under Reduce Motion it only fades (0.15 s). It is the panel's width (360, or the wings when wider), hanging from the top edge, all black
with `onNotch` text and secondary captions, the panel's divider, and no accent: it is information only,
but for its last row, Open Tamebar (below). Its top strip draws the wings as they are, so over the
wings it reads as the same island. While an event goes on, the card opens with its line and a
divider, from the same state as the wings, with their symbol and tone: "In a call · 2 sessions
paused", "Memory low · 2,0 GB free · 17 GB swap" (or "Memory is critical · …"), "Memory low · 3
paused", "Resumed 6", or the note's whole text. It
follows the event, not the wings: after the notch's 4 s pressure flash the wings are gone but the line
stays while memory is short. With nothing going on there is no line. Then the approved mock:
"RAM 6 GB free · CPU 34% · Disk 88 GB free" in the menu bar's
formats, "Memory: normal" (macOS's pressure: normal, warning or critical), a divider, then "AI sessions"
with "3 busy · 5 idle · 2 paused" (a count of zero is left out; agents that report no state count as
"running"), up to three rows by RAM (a dot, white when busy and gray otherwise, or a pause mark; the tool
in gray; the project, cut in the middle; RAM in SF Mono; "busy", "idle", "idle 2d" from a day up, or
"paused"), then "+ 7 more · 3.2 GB". With no session it reads "No AI sessions running". While Tamebar has stopped something that isn't back, "5 stopped ›" follows (October 29, Q15, above). Every card
then ends with a divider and "Open Tamebar ↗" (amendment, October 27): a quiet, full-width 34 pt row,
the title in `onNotch` at the secondary button's weight and the arrow in the secondary color, with the
panel rows' hover highlight (`BlitzRowButtonStyle`) and no accent fill. Its click opens the main window
on Memory and brings Tamebar to the front, by the tray's route (`IslandController.openMemory`: the page,
then `openDashboard`), and closes the card at once, with no grace or fade; the panel doesn't open.
Only that click activates Tamebar; the card still never becomes key or main. A click on the rest of the
card or the notch opens the panel, which grows from the card while the card fades; the bare notch with
no wings and no card still does nothing. The card never takes the keyboard, never shows in full screen
or a shared screen, and doesn't exist without a notched screen.

## October 20 Settings: Automatic actions

The user wants Tamebar proactive but not intrusive (decisions Q10–Q12, approved as mocked). Settings gains an
"Automatic actions" card above the footer. "Unused AI sessions" is a two-choice radio, Ask me (the default)
or End after [N] days, with a 1–30 stepper that is only active once End after is chosen, captioned "Ends idle
sessions while you’re away. Resume them from the Stopped list on Tamebar’s card." (Ended sessions until October 29.) Below a hairline, "Quit under memory
pressure, reopen after" lists the apps opted in from their ⋯ menu on Memory, each with its icon, name and a
quiet Remove, captioned "Add apps from their ⋯ menu on Memory." An empty list is just the caption. (Replaced
on October 29 by Q17's "Apps under pressure", above.)
`BlitzRadioButton` (16-point circle; selected, it fills with the system accent, which `BlitzUI.mint` now
is, and shows a white `onAccent` dot) and `BlitzDayStepper` (minus, the
value in monospaced digits, plus, on a chip group) are the shared controls for this; use the segmented
picker for value choices that need no extra field.

## October 20 Google Calendar row

Settings → Meetings holds one row, Google Calendar, right under Finish setup. It uses the Calendars permission
row's layout: symbol, title, one caption line, and a secondary action (Connect…, Sign in…, Disconnect), or a
spinner with a quiet Cancel while the browser sign-in is open. It isn't a permission, so it's never in Finish setup's
count or the sidebar badge. When Google ends a Testing-mode sign-in, the title carries a warning "Sign in again"
badge. Outside the shipped app the row is hidden. In a build without a client id, it reads "Not configured in
this build." with no action.

## October 19 Tamebar: native light look

The user approved the restyle as mocked on October 20 (decisions, Restyle; plan Phase 8,
Task 8.1). The reference is the bottom row of the "chat desktop app flow" canvas, "Light mode (opaque
materials)", C2: a window with a sidebar and a pane, in Apple system colors. The app follows the system's light
or dark setting; nothing forces dark any more (the app delegate, `blitzTheme()` and Emergency controls each did).

- Tokens keep their names; only their definitions in `BlitzUI` changed. Canvas is
  `windowBackgroundColor`, panel `controlBackgroundColor`, sidebar `underPageBackgroundColor`. Text uses
  `.primary` and `.secondary` (captions too: `tertiaryLabelColor` is too faint for text in light mode, so it is
  kept for strokes, swatches and the off-switch knob). Fills are `Color.primary` at 0.04, 0.06 and 0.1; strokes and
  separators are `separatorColor`. The accent is `Color.accentColor` (system blue unless the user picked
  another); good is green, warning orange, critical red. Resource and Drive colors are system colors
  (Storage blue, Memory purple, CPU orange). No raw `Color(red:)`, `Color(white:)` or white or black opacity
  remains in the views.
- Radius 8 for cards (`cardRadius`, `PanelMetrics.cardRadius`, `heroRadius`), 6 for rows and controls.
- SF Pro 13 rows, 12 body, 11 captions; row values (`BlitzType.numeric`) in SF Mono 11. Large figures keep the
  rounded face.
- Buttons are flat: `.accent` is an accent fill with white text, `.secondary` a 0.06 fill with a hairline,
  destructive secondary red text on a light red tint. No gradient, glow, top highlight or drop shadow, on
  buttons or the dropdown menu. A disabled accent button turns neutral, so its label stays readable.
- One filled accent button per view. Where a page could show two, the second became secondary: Reopen on
  Revive apps, Empty Trash on Drive, "Remove N again…" and "Review selected…" on Cleanup.
- `BlitzColorTile` and `BlitzIconTile` are plain SF Symbols in the secondary color (amber or red only for a
  warning tile), in the same square so rows keep their layout ("stay simple"). Switches are accent with a white
  knob; checkboxes are accent with a white check. Area charts use a flat 0.12 tint instead of a gradient.
- `TAMEBAR_DESIGN_DIR=<dir> swift test --no-parallel --filter DesignRenderTests` renders every page twice,
  `<page>-light.png` and `<page>-dark.png`.

This supersedes the October 18 buttons, the colored squircles and 12-point cards of "October 18 Apple and Linear
visual language", the dark-only tokens, mint accent and 8-point controls in Shared patterns, the Emergency
panel's mint action (October 9), and the white-opacity ring and text rules of the October 7 revamp.

## October 18 stable layouts

The user asked for no layout shifts or disappearing items. A rescan keeps the last complete Drive breakdown and
worktree list on screen and swaps the result in once; live partial results appear only on the very first scan.
Groups and rows keep the order of the last complete scan, and a row emptied by a deletion stays in place with its
action disabled. Controls that change state keep a fixed width, and spinners occupy a reserved slot. Pages no
longer repeat the capacity bottleneck in a banner; the sidebar caption and the Overview header carry it.

## October 18 buttons

*Superseded by "October 19 Tamebar: native light look" above; kept as history.*

The user disliked flat gray buttons and the generic "Do it" label. Accent buttons use a mint gradient with a
top highlight and a soft glow; secondary buttons are raised (light top edge, hairline border, drop shadow);
destructive secondary buttons are tinted red. Labels name the action and carry its glyph through
`BlitzActionLabel` (Stop, Pause, Delete, Review…); never use vague labels such as "Do it" or "OK".

## October 18 tray and Projects follow the new language

*Superseded by N11 (October 30): removed.*

The tray drops the rings and alert banner: a header with a status dot, one issue row when capacity is at risk,
Resources (Memory, CPU, Storage rows with their squircle, value and bar or sparkline, each opening its page), one
Suggested fix the tray can run directly (pause a runaway task, stop the largest idle item), and the three largest
memory users with Stop or Quit on hover. Emergency controls moved to a footer icon button with its shortcut in the
tooltip; Open Tamebar is the accent only when no fix is suggested.

Projects show the project's own logo: an app it builds (matched by name in Applications or its dist folder), then
apple-touch, app and asset-catalog icons, then logos and favicons anywhere in the repository or its monorepo apps,
skipping dependencies, build output and fixtures; wordmarks are skipped. Framework badges remain the fallback.
Terminal workloads on Memory, CPU and the tray use the same logo. Each running project states what Stop ends, the
memory those processes hold, and that code, files and database volumes stay. Listening ports are localhost links.
Revive rows for helper binaries such as chrome-headless-shell name their origin: the tool that installed them
(Remotion, Puppeteer, Playwright), the project, the launcher, uptime, and whether the launcher already exited;
hovering shows the parent chain.

## October 18 Apple and Linear visual language

*Superseded by "October 19 Tamebar: native light look" above; kept as history.* Its interaction rules (clickable storage, worktrees, one accent per view) still hold.

The user found the interface ugly and asked for visuals, icons and an Apple/Linear feel. The app now uses
System Settings–style colored squircles (`BlitzColorTile`) in the sidebar, page headers, Drive groups and Quick
wins; each resource keeps one identity color (Storage blue, Memory purple, CPU orange) for its icon and chart.
Cards share one surface (`blitzCard`: panel fill, hairline border, 12-point corners) with no tinted washes or glows.
Large figures use the rounded face. Group labels are small uppercase text. One mint button per view at most marks
the recommended fix; tile and row actions are secondary. This supersedes the mint-only chart rule and the earlier
"dark utility" restraint on color, and replaces the October 12 Overview: a status header, three resource tiles
(value, bar or sparkline, what drives it, one action) and a Quick wins list that acts directly, with the original
checkup below as Deep checkup. The Overview rings the user rejected stay out; bars and sparklines replace them.

Everything that shows storage can be clicked: a Drive bar segment or legend entry scrolls to its group, and a row
opens its folder in Browse, where Delete permanently is available. Browse may delete app-managed data the user
picks (Codex, Claude, app support folders) after a warning; macOS, Git history, credentials, app bundles and
top-level Library folders stay protected, and automatic lists keep the stricter rule. Git worktrees from project
folders and Codex/Claude sessions are listed on Drive and Overview; merged ones are removed through Git, and ones
blocked only by local files can be removed anyway after a warning that the branch and its commits stay.

## October 18 actionable Memory and CPU

*Superseded by N11 (October 30): removed.*

The user found Memory and CPU informative but not useful. Both pages now open with a verdict card: one state
title that matches the sidebar (Memory uses the same pressure assessment), the numbers that explain it, and one
recommended fix with its button (stop the largest idle item, or pause a runaway task). Below it, one ranked list
replaces the separate AI and Apps sections: each row is a consumer the user recognizes (an AI session, an app with
its helpers, a terminal tool grouped by program and project such as `node · fmx_ws`, or macOS services) with one
primary action and a menu. Memory rows stop or quit; CPU rows pause, since pausing frees the CPU at once and keeps
state. Every row also offers Run in background (Darwin background priority, reversible), Force Quit with
confirmation, and Show in Finder. Consumers are tracked across refreshes and relaunches: no CPU for 30 minutes earns
an Idle badge, sustained 80% CPU for 5 minutes earns a Busy badge. Free N GB stops every idle item after an inline
review. macOS daemons get plain names and no buttons. History spike rows offer Stop or Pause while that program
still runs. This supersedes the Suspend-others header action.

## October 18 Drive breakdown and permanent delete

*Superseded by N11 (October 30): removed.*

The user could not see what filled the main drive, could not delete folders, and did not want to review
simulators or caches file by file. Storage now opens on Drive (replacing Inventory): one bar for the whole
Macintosh HD, then groups (your files, projects, caches, simulators, AI tools, Docker, apps, messages, app data,
Trash, macOS and system) whose units are logical things such as "Simulator devices" or "App caches", never files.
Groups plus macOS, swap and unreadable System Data add up to used space. The scan stays on the Data volume, so
mounted iPhones (DeviceFS), simulator runtime images and disk images are never counted; folder measuring in
Browse and Cleanup now also stops at mount points.
Each unit has one action matching its consequence: Delete (permanent, for rebuildable data; open and recently used
items are kept), Delete all for caches, Empty Trash, Delete devices through `simctl` (running ones shut down
first), Delete per iOS simulator version (`simctl runtime delete`, or an administrator prompt for versions Xcode no
longer lists), Move to Trash for apps,
Review for project caches and Docker, and Browse for personal folders. Data an owning app manages (Messages, Mail,
WhatsApp, Claude, Codex history) is shown with where to remove it, not deleted here. Every removal is confirmed
inline with its size and written to the removal log. Browse adds Delete permanently beside Move to Trash and allows
selecting rebuildable caches.

## October 12 sidebar insights, simpler Overview, large personal files

*Superseded by N11 (October 30): removed.*

The user asked for a sidebar that shows what is slow and what needs attention, rejected the Overview rings
("the rounded thing") and asked for a simpler Overview. Each sidebar page now has one live caption: the limiting
resource on Overview, free RAM and its top app, CPU load and its top app, free disk, apps not responding, and
running projects or leftovers. Warning and critical captions take their tone color and a dot; this replaces the
Revive apps count badge. Overview drops the rings and the resource strip, since the sidebar now owns those values,
and shows one headline, one line, Check my Mac and a progress bar while checks run. The tray keeps its rings.

The user could not find big videos, images or folders to remove. Storage Cleanup adds Large personal files after
old files: files over 50 MB and top-level Downloads, Desktop and Movies folders over 300 MB, filtered by type.
Git working trees and apps are excluded. Each row has Move to Trash, with Undo, after an identity and open-file check.
Search every drive links to Browse → Largest files, which still owns the all-drive ranking.

## October 12 old files and spike causes

*Superseded by N11 (October 30): removed.*

The user could not tell what to delete or what caused CPU and RAM spikes, and asked to remove old downloads in one click.
Storage Cleanup now opens with Old downloads and screenshots: top-level Downloads items and screenshots unused for
3 months, 6 months (default) or 1 year. Added, changed (anywhere inside a folder) and last-opened dates all count as use.
Move N to Trash is a single click without `BlitzConfirmation`, an exception to the bulk-review rule at the user's request:
items go to the Trash, each is rechecked for identity, age and open files first, and Undo puts the batch back.
Rows have Keep as their action; kept items persist and collapse to one caption line with Show again.
Overview's check gains Old files and links its finding to this section; it never moves files from Overview.

CPU and Memory show the biggest users for the chart's selected range below the chart. Each sample stores the top app
by CPU and by RAM; helpers count toward their app, and command-line tools are split by repository (node · project).
The seven-day archive keeps each five-minute bucket's peak and its cause rather than the last reading.

## October 9 storage ownership and cleanup

*Superseded by N11 (October 30): removed.*

Storage rows show the owning app icon when known, including installed apps that are not running.
Codex history, Claude VM data, Docker disks, Git history and system data are kept out of raw file deletion.
Rows explain whether data is rebuildable, app-managed or needs personal review; size alone is never a safe-delete claim.
Inventory offers direct review of checked rebuildable data and links other managed data to its cleanup flow.
Inventory includes on-demand drive and folder scans. External scans are bounded and report partial results.
The capacity display follows the selected external drive. Personal files retain the reviewed Trash flow.

## October 9 resource recovery

*Superseded by N11 (October 30): removed.*

The user needs controls when memory pressure makes the dashboard unusable.
Emergency controls therefore run in a separate process with a small native AppKit panel and a global
Control–Option–Command–R shortcut, available from the tray and Tools menu.
This is an intentional exception to the single-dashboard rule and SwiftUI component rules below:
the recovery path must not depend on that dashboard's main thread, scans, or view graph.
The panel uses one selection, Stop and a secondary action menu, with confirmation text inline.
The user rejected the initial grey utility styling: the fallback shares Tamebar's canvas,
panel surfaces, mint action, type sizes and rounded controls. (Superseded: the panel now uses native
`windowBackgroundColor`, `controlBackgroundColor`, label colors and the accent, in light or dark.) Normal work stays in Memory and Projects.
Shared Codex app actions require confirmation and explicitly affect all chats.

Memory rows make Stop primary while running and Resume primary while paused.
The October 9 paused-Codex report exposed an unconditional Stop button; paused rows keep Stop in the menu.
Running rows keep Suspend in the menu.
Suspend keeps memory; Stop ends local work. Worker groups must not claim to cancel remote Codex turns.
Projects include Docker-only workloads, with manual association for unlabeled containers.
Project Stop preserves database volumes and reports incomplete shutdowns instead of forcing termination.
Docker cleanup shows eligible dangling images and build cache, separately from Docker's broader estimates.
These decisions supersede earlier Pause-first and single-window instructions for these controls.

## User requirements

The September 26, 2026 redesign brief asks for Apple/Linear-level restraint,
a consistent interface, less repetition, and at most two visible actions per row.
The process follows [Vercel's product-design guidance](https://vercel.com/blog/teaching-agents-product-design-at-vercel):
resolve the user's task, use shared components, preserve consequential states, and inspect the rendered result.

## Shared patterns

- Use `BlitzPageHeader` for one page title. Put at most two actions beside it.
- A data row has one primary action and, when necessary, `BlitzActionMenu` for secondary actions.
  A selection checkbox also counts as an interaction; selection rows use at most one other control.
- Use `blitzRow` inside one `blitzTable` for a list. Use `panelCard` for a distinct summary or result.
- Use `BlitzUI` and `BlitzType` for surfaces, text, accent, and spacing: a dark-only near-black canvas,
  0.105 panel surfaces, white-opacity fills and text tiers, and the bright mint accent with dark text. Green identifies actions and charts; warning and destructive states
  keep their semantic colors.
  *Superseded by "October 19 Tamebar: native light look" above; kept as history.*
- Buttons use `BlitzButtonStyle` (`.accent`, `.emphasized`, `.secondary`, `.quiet`) and shared
  control metrics: 8-point radius (6 since October 19); 24/28/34/40-point heights for mini/small/regular/large.
  Toggles use `BlitzSwitchStyle` (38 × 22 track) or `BlitzCheckboxStyle` (18-point square), never native styles.
  Status uses `BlitzStatusBadge` or `BlitzStatusDot` with a `BlitzStatusTone`; do not draw custom pills.
- The window has a hidden titlebar. `BlitzSidebar` sits on the panel surface with a 52-point drag area for the
  window controls; destinations use quiet/secondary buttons, a filled symbol when selected, and ⌘1 to ⌘6.
  Use `BlitzSegmentedPicker` for value choices and filters; the user dislikes dropdowns in settings and storage.
  History ranges use direct segmented choices. Secondary action menus have 36-point rows and
  `blitzDropdownHost` draws them inside the current window without opening an NSMenu or popover window.
  Titled menus align with the left of their trigger; row action menus align to the right.
  Menu actions dismiss after activation, never via a competing container tap gesture.
  Navigation choices are not action buttons; keep category navigation separate from actions.
- Align values on the trailing edge with monospaced digits. App and file names truncate before values or actions.
- Keep a control's label stable while it runs. Show progress beside it and disable conflicting actions.
- Permissions (Accessibility, Full Disk Access, Calendars; never Notifications) are requested only from
  Settings → Finish setup, which lists the missing ones and disappears when all are granted; the Settings sidebar item badges the count.
  Pages never show their own permission prompts. Individual rows show their measured state.
- Use the action's actual consequence: Quit selected apps, Force Quit, Move to Trash, Delete selected caches.
  Single-app Quit, single-thread Quit, and single-project Stop run immediately, per the October 2 request.
  Keep identity checks and native save dialogs; confirm Force Quit, bulk termination, and file removal inline.
- Keep advanced file controls in Filters and Media tools. Preserve their selection and filter state.
- Keep all app sections in the single `dashboard` window. Sidebar navigation remains visible during recovery,
  project work, settings, and storage tasks. Tray actions and legacy launch flags route there too.
- Storage opens directly into Browse, followed by Inventory and Cleanup. The separate Files tab was removed.
  Cleanup and inventory sections are always open in one scrolling list, with no collapse chevrons or
  disclosure groups; long lists cap their rows and offer Show all. Never add another tab bar inside a storage view.
  Browse owns drives, directory navigation, largest files and media review; Inventory owns category sizes; Cleanup owns rebuildable data.
- Open filters, project setup, and media export inline. Use `BlitzConfirmation` for an inline destructive review;
  use it for irreversible and bulk actions, not routine individual Quit/Stop. System choosers and permissions stay native.
- Use real app icons for processes and app-owned data when available; use a neutral fallback for unknown tools.
- Define each feature once. A second entry point may link to the owner (an Overview suggestion row) but never
  re-render its list or controls.
- Badges report exceptions only: Not responding, Detached, Paused, Not back, Revived. Normal states (Running, Normal,
  Shutdown, Not checked) get no badge. No "needs attention" labels, no live/status pills in headers, and no header
  subtitle that repeats a section count. Empty states are one line of text, with no icon, title, or blurb.

## Implementation decisions

The redesign replaces the storage dial with a capacity bar and explicit free/used values.
The sidebar has six pages (Overview, Memory, CPU, Storage, Revive apps, Projects) plus Settings. Pages removed in
1.0.12 and where they went: AI workers and Processes into Memory (AI threads) and CPU, History into Memory's
pressure section, Worktrees and Developer storage into Storage Cleanup, Project folders into Settings. Saved page
names from older versions redirect through `CleanPage.restored`. The tray gear menu has Settings and Stop monitoring and quit.
Overview shows storage, memory, CPU, then the AI sessions using the most RAM. Pause (SIGSTOP) and
Resume (SIGCONT) are direct row actions. Quit and Force Quit are in the secondary menu.
A header action pauses every thread except the largest. Suggestion rows only appear when something else
is actionable: stopped or frozen apps, and folders that grew back.
Recovery lists Stopped or frozen apps first, Running apps next, and Quit or crashed apps last. Each row shows its own
live status and owns its action, so a revive never waits for the full scan. Process state is read first, so stopped
apps and the bulk Revive action appear before window checks finish. A revive reports a definite result: Revived,
Not responding, Still stopped, Quit, or Crashed (confirmed by a macOS crash
report written after the attempt). Recent app crashes from DiagnosticReports stay listed with Reopen until dismissed.
Revive remains available for every eligible running app, including apps with no health result yet.
Built-in user apps such as Mail, Terminal, and Safari are included. Resume eligibility is separate from Quit
eligibility: protected built-in apps have Revive, while Force Quit stays disabled. Core macOS services remain hidden.
A successful single-app Revive brings that app to the front; bulk revive keeps the dashboard visible.
Each row has direct Revive and Force Quit actions; there is no action dropdown. Normal Quit stays in Memory.
A responsive window returns an explicit result instead of silently removing the Revive action.
The sidebar badge counts stopped and unresponsive apps from background process-state reads.
Memory lists AI threads before apps, with a persistent search field above the scroll area. An AI thread is one agent session (Claude Code, Codex CLI, Cursor agent, or a
Codex desktop thread grouped by launch time) with its tool servers, ranked by RAM. Its row has direct Pause/Resume; Quit (SIGTERM) lives in its menu.
Pause keeps the RAM. Force Quit (SIGKILL) stays in the menu. A thread whose root was reparented to launchd without
a terminal is marked Detached, and the section header offers to quit all detached threads. Each app row has Quit
as its primary action and Force Quit in its menu. An explicit Quit skips suggestion-only guards (active, pinned,
AI app) and still re-checks the process identity; macOS system apps and Tamebar keep a lock instead of Quit.
Storage Cleanup includes Removed before: every folder removed earlier that tools rebuild (build output,
dependencies, shared caches), its current size, and Remove again. Cleanup reports written by agents to
`~/Library/Application Support/BlitzClean/reports/` are imported into the same history. The Removal log closes
the page with every recorded removal.
History ranges are direct segmented choices. Folder navigation uses visible drive and Home buttons,
breadcrumbs and back/forward buttons. Secondary actions alone use menus.

These decisions implement this brief; a later user request can change them.
Record the reason beside a changed pattern instead of adding another competing component.

## Verification

Inspect the changed surface at compact and standard window sizes.
Check loading, empty search, populated rows, long names, large values, menu actions, and disabled states.
`TAMEBAR_DESIGN_DIR=/tmp/shots swift test --no-parallel --filter DesignRenderTests` hosts the dashboard in an
offscreen window and writes every page, in light and dark, with scripted recovery states.
Verify the installed app too, because offscreen rendering can omit native controls and composited layers.
A successful build does not count as visual acceptance.

## October 2 pressure prevention

Overview now leads with the limiting resource and a clear instruction to avoid new threads/builds under pressure.
A compact Running projects row links into Projects, which owns searchable project groups, aggregate memory/CPU, child-process counts and Pause/Resume.
Projects distinguish active background workers from saved inactive projects without requiring a listening port.
The row menu owns per-project automatic-pause consent, Keep running and Stop servers; no extra window is opened.

## October 2 immediate actions and drive browsing

*Superseded by N11 (October 30): removed.*

Applies [UI Skills Baseline UI](https://www.ui-skills.com/skills/baseline-ui) to the existing native controls:
strong hierarchy, monospaced values, stable labels, larger hit targets, and errors beside the action.
The user explicitly asked to skip routine confirmations. Quit and Stop are single clicks; Force Quit and bulk
termination still use inline confirmation. Apps appear ahead of AI threads in Memory. Search stays visible on
Memory, Revive apps, and Projects. Project Stop includes eligible background runtimes and handles paused workers.

Browse opens on all mounted local drives, with drive cards, same-page directory navigation, and largest files
across the selected roots. Hidden files, app packages, and dependency trees are visible. Directory listing is
separate from recursive file ranking, so navigation does not wait for folder-size subprocesses. A streaming
scan shows file count, elapsed time, and unreadable paths. Results are capped at the largest 5,000, not the first
5,000 encountered; rows are paged. Cancellation keeps current results. Browse adds no nested tabs or windows.

Browse defaults to the directory browser. A folder's full row and its arrow are a single Button, opened in one
click. Files and folders have selection checkboxes and an inline Move to Trash review; files can be revealed in
Finder. Visible drive buttons switch locations, and breadcrumbs navigate parents. Largest files across all drives
is a secondary action within Browse and has no tab of its own. Inventory links route into this same browser.
Folder listings run off the main actor, then one native scan fills in child-directory sizes. Partial folder totals
use a lower-bound indicator. Navigating away cancels the previous traversal. Closed dropdown hosts do not hit-test.

## October 2 interaction simplification

The user rejected the dropdowns and click behavior. Drive and Home navigation, hidden-file visibility,
refresh, sorting and select-all are now direct controls. Each directory row has a full-height 52-point
button covering its name, size and arrow, with hover and pressed feedback. Navigation supports bounded
back/forward history. Checkboxes have at least 34-point hit targets. History range choices are visible
segments. Secondary action menus use quieter shadows, consistent spacing, left alignment for titled
triggers, and action-driven dismissal; disabled items cannot dismiss a menu or invoke an action.

The unlabeled back/forward/up arrow cluster was rejected. Back and Forward now have text labels;
Forward appears only when there is forward history. Parent navigation uses named breadcrumbs.
Navigation never opens Finder; Show in Finder is an explicit secondary action.

The browser groups folders before files, preserving size ordering within each group. Clicking a file
selects it or shows its path inline without opening Finder.
Home-folder files and user-created folders can be selected; core home folders and credential roots stay protected.

Directory rows show proportional size bars against the largest item in the folder. Returning to a folder
restores its saved listing immediately, including interrupted measurements. Refresh keeps prior sizes and
bars until the new traversal finishes; a saved estimate uses ~ and a measured minimum uses ≥.
Completed listings are reused for five minutes. Older or interrupted listings refresh in the background.
The last 60 listings persist across app relaunch. Identity checks prevent replaced folders inheriting old sizes,
and unavailable folders retain their saved listing with an inline explanation.

## October 2 live app recovery

*Superseded by N11 (October 30): removed.*

Revive uses the current macOS app roster, independent of the slower memory scan. Launch/exit notifications
refresh it immediately and a two-second loop reads process states while the screen is open. Window checks
expire after two seconds, run at bounded concurrency, and never disable a manual Revive. Rows stay sorted
by app name within their status group. A new health observation supersedes an old recovery outcome.
Repeated Stop/Revive cycles are allowed without an arbitrary ten-second lock. Window messages time out
after half a second, with two observations before reporting a frozen window; recovery verification has a
three-second budget. A resumed process is distinguished from a confirmed responsive window. Crash-report
lookups run at most every 30 seconds. Force Quit keeps the inline unsaved-work confirmation.

## October 3 AI session identity and direct pause

Pause/Resume is the primary action in both Overview and Memory, with Quit and Force Quit in the row menu.
Memory puts AI sessions immediately after its summary so the controls are easy to find.
Rows show a verified local session title when available, then provider, project, delegated providers, terminal
host and process ID. Search includes those identities. Claude launching Codex remains a Claude session
labeled "includes Codex CLI"; cmux is the terminal host, never the AI provider.

Claude PID metadata must match the process start time. Codex CLI titles require an explicit session ID or
a single open rollout file. Cursor titles require an explicit session ID matching local metadata.
Shared Codex desktop children remain launch-time worker groups, labeled Codex workers; the app does not
guess individual chat titles from their folder or launch time. Pause affects local processes only; cloud
generation can continue. No conversation bodies or encrypted message blobs are inspected for naming.

## October 3 direct file ranking and simulator devices

*Superseded by N11 (October 30): removed.*

Browse keeps its initial directory default and remembers the last chosen folders/largest-files mode across relaunch.
Largest files is a prominent action; file results follow a compact drive-scope header without a duplicate directory list.
Process and AI-session snapshots refresh every two seconds in the foreground, with non-overlapping scans and slower
background polling. Large-file rows use the shared icon cache.

Cleanup starts with Simulated devices, loaded independently of the slower storage inventory.
A booted device has Shut down; a shutdown device has Delete device with inline permanent-removal review.
Deletion uses Apple's simulator service for the exact current device identity, verifies disappearance, and records
the removal. Installed iOS runtimes stay available. Managed simulator directories link here with Manage devices;
generic Trash is unavailable for those directories and their contents.

## October 3 resident menu bar monitor

*The tray: superseded by N11 (October 30): the card and the window replace it.*

The dashboard and monitoring have separate close actions, per the user's request.
The red window button, Command-W, Command-Q, and Dock Quit close the dashboard while the monitor stays resident.
The app menu calls Command-Q Close dashboard. Only the tray gear menu offers Stop monitoring and quit
(since October 27 the tray opens from the menu-bar item's card, N7), and since October 29 Settings'
Quit Tamebar, the same action (N10).
System logout, restart, and shutdown remain normal termination paths; no relaunch loop or quit confirmation is added.

The October 7 request makes Dock and app-switcher presence follow the dashboard lifecycle.
Launch starts as a menu-bar accessory. Opening the dashboard switches to a regular app; closing it restores
accessory mode. Opening the tray alone never adds a Dock entry. A minimized dashboard remains open.

Settings used direct segments for the RAM value: Available GB, Used GB, or Used % (removed October 29
with the other "Show in menu bar" switches, N9; a value saved before still sets the tray's figure).
Available memory is the default, labeled free in the menu bar; used bytes are explicitly labeled used.
The tray card follows the same saved choice, and unavailable readings use a dash.
CPU remains a utilization percentage. Available RAM includes reclaimable memory, as described in the control's help.

## October 6 tray and dashboard polish

*Superseded by N11 (October 30): removed.*

Applies [UI Skills](https://www.ui-skills.com/) baseline-ui and better-ui: one accent per view, tabular values,
exceptions only, errors beside the action, and nested radii that match their padding.
The tray is a 340-point panel: header with the gear menu, a pressure alert only when `PressureAssessment.risk`
is above normal, a Memory tile (saved RAM display, 60-second plot, pressure badge only at warning or critical),
CPU and Storage tiles, the three apps using the most memory (rows link to Memory without controls), and a footer
with Revive apps (attention count) and Open dashboard. Every tile opens its page.
`PressureAssessment.limit` names the limiting resource; disk alerts lead to Storage Cleanup with disk advice,
memory and CPU alerts lead to Projects. The Overview banner is tinted by severity when actionable and a single
status line otherwise. Storage location choices use `BlitzChip` inside `blitzChipGroup`; both Browse modes
share one toolbar row with chips on the left and the mode switch on the right, and every Storage surface uses
`BlitzUI.pagePadding`. Status text for a scan stays on one caption line.

## October 6 shared components and permissions

Shared views live in `BlitzComponents.swift`: `BlitzSectionHeader`, `BlitzEmptyRow`, `BlitzShowAllButton`,
`BlitzStatusLine`, `BlitzTrailingValue`, `BlitzCountBadge`, `AppRowIdentity`, `PageSearchBar`, `MenuCheckLabel`,
`StorageActionBar`, and the `Finder`/`Pasteboard` helpers. Row buttons use `BlitzRowButtonStyle`; whole cards use
`BlitzCardButtonStyle` with `BlitzChevron`; alerts use `blitzToneCard`. Add to these before writing a new variant.
Views derive filtered/sorted lists once per render and pass them down; app icons go through `ApplicationIcon`.
`PermissionsModel` probes Full Disk Access and reads the Calendars status (never prompting; only the row's Allow… asks);
permission state refreshes whenever Tamebar becomes active. The Calendars row shows only in an installed build.
Storage Cleanup has one page-level Scan again; sections do not carry their own refresh buttons.

## October 6 one-click cleanup

*Superseded by N11 (October 30): removed.*

At the user's request, Overview owns a Quick clean summary with a direct Clean action for the known,
rebuildable cache allowlist. This explicit action replaces the extra confirmation for this narrow batch only;
the consequence is visible beside it. Storage Cleanup keeps item selection and its existing inline review.
Both entry points share one model, activity checks, deletion checks, progress, and removal history.
Overview scans on first appearance. Scan again refreshes the estimate; Details opens Storage Cleanup.
Caches now lead Storage Cleanup so this link lands at the relevant section. Skipped locations and cleanup
results remain visible even when no candidates remain; simulated devices follow caches.
The mint orbit runs only while work is active, honors Reduce Motion, and becomes a check after real removals.
Progress counts checked candidates. Removed cache bytes and observed free-space changes remain separate.

## October 6 process memory and System Data

*Superseded by N11 (October 30): removed.*

Launch feedback requested individual process RAM and System Data cleanup. Memory now has an Apps & AI /
Processes choice below its summary, using the existing live resource snapshot rather than a second polling loop.
Process rows show a single PID's footprint, owner, and unavailable readings explicitly; search includes PIDs.
Storage Cleanup starts with System Data cleanup, replacing the narrower Caches heading. This section owns
selection, review, retention rules, and skipped-item explanations for browser/developer caches and old diagnostic
reports. Overview's direct Clean action excludes reports. Its Details link leads to this section.
Inventory labels the shared-folder scan System folders to avoid presenting it as Apple's System Data total.

## October 6 cleanup overview correction

*Superseded by N11 (October 30): removed.*

The user rejected the prominent 0 B cache card because it hid available Docker and project cleanup.
Overview now summarizes eligible caches, diagnostic reports, project data, regrown folders, shutdown simulators,
and Docker images/build cache, using the existing scanners. Overlapping filesystem paths count once; a pnpm
store's full size is excluded because pruning cannot reclaim it all. Values are estimates for review, not a promise
of freed space. Review cleanup opens the existing Storage flow. One-click Clean caches names its narrower size.
An empty result is a compact sentence with Scan again; skipped/unavailable locations retain a Details link.
No large zero, disabled Clean button, or decorative empty-state animation. Scans start from Overview, with cached
estimates retained and labeled while refreshing. Docker failures do not contribute stale reclaimable bytes.

## October 7 scan responsiveness

Overview and Storage Cleanup request the cleanup scope only: simulator status/cache and project dependencies.
The broad app, Library, system-folder, and Spotlight inventory runs when Inventory is opened or Scan Mac is used.
Its completion timestamp is separate, so a cleanup refresh cannot label old inventory as freshly measured.
Project age reads skip generated tool directories and stop at a time/entry budget. A partial read is Unknown,
never an old date; age-based recommendations exclude it. Cached category results stay visible during refresh.

## October 7 audit and action dashboard

*Superseded by N11 (October 30): removed.*

The user approved replacing the Overview stack with one audit-and-action flow. Check my Mac starts five
independent checks: resources, eligible caches, project data and regrown folders, Docker, and app responsiveness.
The dashboard no longer starts expensive storage work merely by opening. Findings appear as their checks finish;
a check still running never inherits a previous run's findings. The audit survives sidebar navigation.

Show three ranked findings by default, with Show all for the rest. Resource pressure and stopped/frozen apps
lead, followed by eligible caches, detached AI sessions, Docker, project data, simulators, and diagnostic reports.
Only Clean [size] removes anything from Overview, using the existing cache allowlist and deletion revalidation.
Other actions open the owning page; storage actions jump directly to the matching section.

After cleanup, keep actual removed bytes, skipped reasons, and measured free-space change visible while fresh
checks run. The empty result is compact text; partial checks disclose their limits and never report an all-clear.
Check details contains the per-check outcomes and reasons. The last-checked time changes only after all checks
finish. One compact resource strip links to Storage, Memory, and CPU; detailed charts and process lists stay in
their sidebar pages. Progress is driven by completed checks/items and respects Reduce Motion.

## October 7 audit latency and ready actions

*Superseded by N11 (October 30): removed.*

Eligible cache actions become available as soon as their own check finishes, while project checks continue.
Conflicting mutations stay disabled; every removal still performs the existing fresh activity and identity checks.
A successful cleanup queues one fresh audit if a check is still running, preserving the actual cleanup result.

Project and removal-history scans share measurements only within one audit, with at most four folder readers.
New audit measurements share a twenty-second traversal budget. A timed-out folder contributes no guessed or
partial size; Check details discloses unfinished folders, and Storage offers a deeper scan. Filesystem calls
already in progress may overrun the budget. Full scans started separately retain their own lifetime.
The pnpm store's full size is not a reclaimable estimate, so its separate measurement runs in detailed cleanup.
Opening that detail during an audit queues the full history check; unchecked folders never say Not back.
Docker inspection has a twelve-second deadline, and unavailable Docker never contributes stale cleanup bytes.

## October 7 Overview and tray revamp

*Superseded by N11 (October 30): removed.*

The user asked for a more playful, game-like Overview and tray, using [UI Skills](https://www.ui-skills.com/),
Emil Kowalski's motion guidance, Raycast, Shotbase, and DreamCut as references. They rejected eyebrows,
decorative or "AI" icons such as sparkles, and gradients; surfaces use flat fills and no glows.
A later pass removed common AI-generated design tells (from the "Signs of AI design" guide and Adrian Krebs'
list of 16 patterns): violet accents, multicolor icon tiles, stat banner rows, connected step sequences,
colored accent words in headlines, and cards inside cards. Tertiary text rose from 0.38 to 0.46 white for AA contrast.
(The white-opacity text and ring colors are superseded by "October 19 Tamebar: native light look".)

- `BlitzVitalRings` draws memory, CPU, and storage load as thin concentric rings: mint, then two white
  opacities. Ring colors never change with severity, because two amber rings merged into one shape; warnings
  color the legend value instead. The Overview center shows the busiest resource ("97% storage"); the tray
  center stays empty because its legend sits beside the rings. Rings show measured load only and never a composite score.
  `MacVital` holds each ring's value, compact value, caption, and page. The legend rows open that page.
- The Overview hero puts the rings beside the audit state and Check my Mac. When findings have reclaimable
  space, the headline reads "Up to [size] to reclaim". `AuditRecommendation.reward` carries each estimate.
- After the first check, one status row lists the five checks. They run in parallel, so they have no connecting
  path or numbering: a spinner while running, then a check mark or a warning mark.
- Findings are "Next moves": a neutral category tile (amber or red only for warnings), title, detail, and one action.
- A removal that frees space shows its size large, with a single short particle burst. This is the only
  celebratory motion, honors Reduce Motion, and does not play for unchanged or failed cleanups.
- One caption line below the card gives the last cleanup, space recovered, and cleanup count from the removal log.
- The tray uses the same rings and legend, followed by last-minute memory and CPU plots and the top three
  apps with share-of-RAM bars. Open dashboard is the panel's one accent button.
- Motion: no ring entrance animation (Overview opens many times a day). Value changes ease out over
  0.3 seconds, list changes over 0.22 seconds, and buttons scale to 0.97 when pressed.

## October 7 automatic updates

Settings > Updates shows the update status in one line, a single action (Check for updates, Update to [version],
or Restart to update to [version]) and the automatic-check switch. Builds without a feed say so and link to
the GitHub releases page. The tray shows the update action beside the gear only when an update is found or downloaded;
otherwise Check for updates lives in the gear menu. Scheduled updates never open a window on their own
(Sparkle's gentle reminders); a check the user starts uses Sparkle's native update window.

## October 7 other-apps section (removed)

Tamebar has no Our other apps section: the BlitzReels family links were removed in the rebrand.
Settings now ends with one caption line, "Tamebar <version>. Based on BlitzClean (MIT). Your data stays on your
Mac.", under Quit Tamebar (N10), and a License link that opens the bundled MIT notice; the link is hidden when the file is missing.

## October 7 leftover processes

*The page: superseded by N11 (October 30): removed; the scan still counts leftovers.*

Confirmations retain the process identity from the selected row even when the list refreshes.
Each signal rechecks the current folder and protections. Action feedback stays visible after the last row exits.

Projects adds Leftover processes between Active and Saved projects, shown only when there is one.
The section owns processes whose parent exited, without a project or AI session to own them;
it does not repeat AI sessions, which Memory owns, or projects marked Keep running. Each row has Quit as its
primary action. Force Quit, Show folder in Finder, Copy process ID, and Hide are in its menu.
Quit runs at once, like single-project Stop; Force Quit and the header's Quit all use `BlitzConfirmation`.
Hidden names collapse to one caption line with Show again, following the skipped-permissions pattern.
No badge is added: a leftover is not an exception on a normal row, it is the reason the row exists.

## October 7 skippable permissions

The user asked why the Settings badge kept counting a permission they did not want. Each Finish setup row now
has Not needed (quiet) beside Allow…. A skipped permission leaves the list and the sidebar badge, and the section
shrinks to one caption line, "Not needed: …", with Ask again. Skips persist in `permissions.skipped`;
a permission granted later no longer counts as skipped. Features that need the permission keep their own
inline state, so skipping never hides why something is unavailable.
