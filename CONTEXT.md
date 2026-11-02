# Tamebar domain language

This glossary covers the background usage manager. Current behavior is described in
`docs/DESIGN.md`; in particular, Q19 replaces the old running-session work queue and
N11 removes the older dashboard pages.

## AI session

A Claude Code or Codex run and the processes it owns. Its agent status, process identities,
terminal activity, Keep setting, project, and served ports determine what Tamebar may do to it.
A running AI session is never held for memory pressure (Q19). A new session may wait at start.

## Process scan

One observation of running processes, AI sessions, ports, working directories, and process
identities. A scan can be partial: missing port lines then mean unknown, not that a server ended.

## Applied process scan

The current process scan reconciled with prior serving observations. Serving protection retains
known listeners through a partial read; the unused-server clock uses only ports observed
now and never expires a port on an incomplete connection read.

## Session eligibility

The shared facts that allow an automatic end: an in-scope, running AI session with no signal in
flight, a resume command, and the required protection checks. Q10, Q18, and Q20 retain distinct
idle thresholds and triggers. Every end uses a fresh scan and rechecks status before signaling.

## Automatic action

An action Tamebar starts without a click, under the authority of the instance holding
`autopause.lock`. Q10 may end a long-idle session while away; Q18 may end one under sustained
memory pressure; Q20 may end an unused session and its unused dev server. These three ending
policies run in that order and only one end may be in flight at a time. Each confirmed end is
recorded for CLI recovery and the usage trend.

## Serving protection

A session's child process listening on a port normally protects that session from ending. Q20
may lift only that protection after both the session and its dev server have been unused for a
day, with protected ports and other work still excluded.
