# Claude Notch V2: implementation plan

V1 is a toy that watches your agents. V2 is a cockpit for running them: answer, review, launch and steer every Claude Code session from the notch without breaking your flow. It stays fun, but the fun now carries information. Every delight below tells you something about your agents.

**Who it's for:** a developer running 2–10 Claude Code sessions in parallel, across repos and worktrees, in the terminal and the Claude app.

**Principles**
- **Depth on Claude Code, not breadth.** No music, crypto or dictation. Coucou covers breadth; we win on managing a fleet.
- **Keyboard first.** Every action has a key. The mouse is optional.
- **Never block Claude.** If the app is closed, slow or wrong, Claude carries on exactly as it would without us.
- **Delight = signal.** A delight that doesn't say something about the agents doesn't ship.

## What we've verified (and what's still a guess)

| Building block | Status | Notes |
|---|---|---|
| Hooks for every event, incl. `PermissionRequest`, `SubagentStart/Stop` | ✅ shipping | `HookServer` on 127.0.0.1:47474 |
| Allow / Deny from the notch | ✅ shipping | Hook output `decision.behavior` |
| "Always" via `decision.updatedPermissions` | 📄 documented | Reuse the request's `permission_suggestions` |
| Running sessions, titles, busy/idle | ✅ shipping | `~/.claude/sessions/<pid>.json`. Terminal and Claude-app sessions register; sessions started *inside* another Claude Code session don't (hooks still catch those) |
| Answer `AskUserQuestion` from the notch | ✅ spike passed | It goes through `PermissionRequest`; reply `allow` with `updatedInput` = the input plus `answers: {"<question text>": "<label>"}` |
| Plan usage (5-hour, weekly) | ⚠️ spike: cache only | `plan-usage-history.json` is written only when the Claude app fetches usage, at most every 4.5 min. Show it with its age; never read tokens to fetch it ourselves |
| Start a session with a prompt | ⚠️ spike: draft only | `claude://code/new?folder=…&q=…` opens a *draft* in the Claude app (you press Enter). A terminal launch, `claude "prompt"`, starts right away |
| Reply to a running session | ❌ spike: not via socket | `/tmp/cc-socks/<pid>.sock` is Claude Code's session-to-session messaging, authenticated per session; whatever arrives is labelled as from another session, never the user. Use keystrokes instead (tmux, iTerm) |
| Interrupt a turn | ❌ spike: not via SIGINT | SIGINT to the process **quits** Claude Code ("Resume this session with…"). Interrupt with an Esc keystroke instead (tmux, iTerm) |

## Milestones

### v2.0: Answer everything, review everything
*Goal: you never have to visit a terminal just to unblock or check on an agent.*

**1. Always-allow.** A third button on permission cards. The reply sends `allow` plus the request's `permission_suggestions` as `updatedPermissions`, so Claude Code saves the rule.
- Code: `HookEvent` keeps `permission_suggestions`; `PermissionDecision.always`; `HookServer.hookOutput` writes `updatedPermissions`.
- Tests: hook-output JSON for all three answers; the suggestions round-trip.
- ✨ **Delight 1, Trust stickers:** each Claude wears tiny pixel stickers for the tools you've marked Always (a terminal sticker for Bash, a pencil for Edit). Glance at a Claude and you know how much rope it has.

**2. Answer Claude's questions.** `AskUserQuestion` becomes buttons on the card (single or multi-select, up to 4 questions), plus "Answer in terminal".
- Verified: the question arrives as a `PermissionRequest` for `AskUserQuestion`. Answer with `allow` and `updatedInput` set to the original input plus `answers` (question text → option label, or a list for multi-select). Same hold, timeout and release rules as permission prompts.
- ✨ **Delight 2, Thinking bubble:** while waiting on a question, the Claude holds up a speech bubble with a "?" that bobs. Answering pops the bubble into confetti in the colour of the option you picked.

**3. Fleet board.** The open panel becomes a board: **Needs you · Working · Ready for review · Idle**, each sorted by wait time. Every card leads with the conversation's name (from the session registry, or the transcript's latest `custom-title`), with the folder, time and cost beneath it, as V1 cards already do. Keyboard: ↑↓ to move, `A` allow, `D` deny, `L` always, `⏎` jump to the session, `Space` to peek.
- Code: `Board` view replacing the card grid; `NotchPanel` may become key while open so keys and text fields work (closes on Esc or when the pointer leaves).
- ✨ **Delight 3, Wait-time wilt:** a waiting Claude's flag starts upright and slowly droops as the minutes pass. At 10 minutes the flag sags and the Claude sits down on the edge of the notch, legs dangling. You feel the wait without reading a timer.

**4. Timeline and live diffs.** Each session keeps a timeline of steps: tool, target, result, duration. Edits show `NotchView.swift +12 −3`, and tapping one opens the diff.
- Code: `PreToolUse` keeps `tool_input` (`old_string`/`new_string`, `content`, `command`); `SessionTimeline` is a ring buffer of the last 200 steps per session, saved to `~/Library/Application Support/Claude Notch/timelines/`. The diff is computed locally from the edit inputs. Failures come from `PostToolUseFailure`.
- Tests: line counting for Edit, MultiEdit and Write; the ring buffer stays capped; persistence round-trips.
- ✨ **Delight 4, Cardboard boxes:** a Claude carries one tiny box per file it has changed this turn, stacked on its head (max 5, then the stack wobbles). On "Ready for review" it sets the boxes down in a neat pile.

**5. Review handoff.** When a session stops, its card moves to *Ready for review* with Claude's last message (from `Stop.last_assistant_message`), the files changed, a test result if one ran, and buttons: **Open diff**, **Open PR** (`gh pr create --web` in its folder), **Jump**.
- Code: `ReviewSummary` built from the timeline plus `git -C <cwd> diff --stat`; test detection from Bash steps that look like test runs (`xcodebuild test`, `npm test`, `pytest`, `go test`, …) and their exit status.
- ✨ **Delight 5, The parcel:** a finished Claude holds up a little wrapped parcel instead of a plain green flag. Green bow if the tests passed, red bow if they failed, plain if none ran. You can read "ready, and is it good" from across the room.

### v2.1: Launch and budget
*Goal: start work and keep an eye on limits from the notch.*

**6. Task launcher.** ⌃⌥N opens a prompt field in the notch: pick a repo (recent folders from the registry), type the task, Enter. It launches in a terminal (`claude "…"` in Terminal, iTerm or Ghostty, which starts immediately) or in the Claude app (`claude://code/new?folder=&q=`, which opens a filled-in draft you send with Enter), per a setting. Terminal launches must use a clean environment: a `claude` started with another session's `CLAUDE*` variables counts as nested and doesn't register.
- **Templates:** "Fix failing tests", "Review this branch", "Bump dependencies", "Write tests for staged changes". Stored as JSON and editable in Settings.
- **Worktree per task (optional):** `git worktree add ../<repo>-<slug> -b claude/<slug>`, then launch there, so parallel agents don't collide. The card shows the branch.
- ✨ **Delight 6, Parachute drop:** a Claude you launch from the notch doesn't walk out of it; it parachutes in from the top of the screen and lands on the wing with a puff of dust. Claudes started elsewhere still walk out of the notch, so you can tell yours apart at a glance.

**7. Plan usage.** A header pill shows 5-hour and weekly usage from `plan-usage-history.json` (latest sample), with a warning colour at 80% and "as of N min ago".
- Verified: the Claude app appends a sample only when it fetches usage itself (at most every 4.5 minutes, and only while its usage display is in use), keeping 30 days. Treat it as a cache: hide the pill when the newest sample is over an hour old. The live numbers come from an endpoint that needs the user's login token, which we won't read. The sample also has keys for other limits (`so` Opus weekly, `sn` Sonnet weekly).
- ✨ **Delight 7, Stamina:** as your 5-hour usage climbs, all Claudes slow slightly and yawn more often. At the limit they put up a tiny "brb" sign and sit down, and stand back up the moment the window resets. Your rate limit, felt rather than read.

**8. Alerts.** Context over 80% ("compact soon"), a session costing more than $X, or a session waiting longer than N minutes. Each alert fires once and can be snoozed.
- ✨ **Delight 8, The tap:** when someone has waited too long, the closed notch gives a single gentle bounce, like a tap on the shoulder. It happens once and never repeats for the same wait. With Reduce Motion on, it's a brief glow instead.

**9. Ledger and weekly recap.** Spend today, sessions, approvals, PRs opened. Every Monday a recap card: "Your Claudes made 212 edits across 9 repos and opened 6 PRs".
- Code: `Ledger` appends daily totals to a JSONL file; the recap is rendered with `ImageRenderer` to a shareable PNG.
- ✨ **Delight 9, The yearbook:** the weekly recap is a pixel-art class photo of every session's Claude from the week, each holding its stats on a tiny placard, with a "Most edits" ribbon and a "Longest thinker" ribbon. Shareable, and the only time all your Claudes pose together.

### v2.2: Talk back and guardrails
*Goal: steer agents, not just unblock them.*

**10. Reply to a session.** A text field on "Your turn" cards sends the next prompt.
- Verified: the per-session socket is off the table. It's Claude Code's session-to-session channel; messages on it are labelled as from another session, not from you, and it's authenticated per session.
- Instead, type the reply as keystrokes where the session runs: `tmux send-keys` (the registry records the tmux pane), or iTerm's `write text`. For Terminal.app and Claude-app sessions: jump to the session with the reply on the clipboard, ready to paste.
- ✨ **Delight 10, Paper airplane:** your reply folds into a paper airplane that flies from the card to the Claude, who catches it, reads it, and starts walking again.

**11. Stop a turn.** A Stop button and `S` key interrupt a session going off the rails.
- Verified: SIGINT quits Claude Code entirely, so never send it. Send an Esc keystroke instead: `tmux send-keys Escape`, or iTerm `write text` with an escape character and no newline. Terminal.app and Claude-app sessions: jump to them and let the user press Esc (or the app's Stop button). Show Stop only where it can work.
- ✨ **Delight 11, Freeze frame:** the Claude freezes mid-step with a "!" above its head, then shakes it off and sits down to wait for you.

**12. Guardrails.** Rules checked before a permission prompt is held: *auto-allow* (read-only tools, `git status`, tests), *always ask* (`git push`, `rm -rf`, anything touching `.env` or production configs), per repo or global. Every decision, by you or a rule, goes to an audit log you can browse and export.
- Code: `PolicyEngine` (pure, heavily tested) evaluated in `AgentStore.hold`; rules stored as JSON; `AuditLog` JSONL at `~/Library/Application Support/Claude Notch/audit.jsonl`.
- ✨ **Delight 12, Rubber stamp:** when a rule auto-approves something, a tiny "OK" stamp thumps onto the Claude's head and fades. You see your guardrails working without being interrupted by them.

**13. Other agents (stretch).** Adapters for Codex CLI and Gemini CLI hooks, mapped onto the same `HookEvent`.
- ✨ **Delight 13, Cousins:** other agents get their own original pixel critters, a little box robot and a twinkly star, that walk alongside the Claudes and high-five them too.

## Architecture changes
- **Sessions:** `Agent` grows into `Session` with `timeline`, `files`, `review`, `stickers` (Always rules) and `origin` (launched from the notch, or found). Keep `AgentStore` as the single main-actor source of truth.
- **Actions:** one `SessionActions` type with `allow`, `deny`, `always`, `answer`, `reply`, `stop`, `jump`, `launch`, `openPR`, so the board, keyboard shortcuts and global hotkeys all route the same way. Each action gets a unit test.
- **Storage:** `~/Library/Application Support/Claude Notch/` for timelines, audit log, ledger, templates and policies. JSON and JSONL only; no database.
- **Panel:** bigger open size with tabs (Board · Timeline · Usage). It becomes key only while open and a field or key handler needs it.
- **Sprites:** stickers, boxes, parcel, bubble, parachute, airplane and stamp become new `Sprite.Prop` and overlay cases, each with a snapshot render test.

## Testing and verification
- **Pure logic** (policies, diff counts, review summaries, usage parsing, launch URL building) is unit tested, as today.
- **Every new sprite** gets a snapshot render in `SnapshotRender`, checked by eye.
- **End to end:** a `scripts/simulate.sh` posts realistic hook sequences (permission prompt → Always → edits → test run → Stop) to the running app, so the board can be exercised without a real agent.
- **Demo mode becomes a guided tour:** a scripted fleet that shows every feature and delight in about two minutes. It doubles as the README GIF.

## Order of work
1. **Spikes:** done, see the table at the top and the notes under each feature. Two (socket, SIGINT) failed and were replaced by keystroke delivery; one (questions) passed; two (plan usage, `code/new`) work with limits.
2. **v2.0, about 2 weeks:** Always, questions, board, timeline with diffs, review handoff. Delights 1–5.
3. **v2.1, about 1 week:** launcher, templates, worktrees, plan usage, alerts, ledger and recap. Delights 6–9.
4. **v2.2, about 1–2 weeks:** reply, stop, guardrails and audit log; other agents if time allows. Delights 10–13.

## Out of scope for V2
Chat with models, dictation, music, phone apps, Windows or Linux, and a notarized App Store build. Each could come later; none makes managing agents better now.
