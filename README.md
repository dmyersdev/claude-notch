# Claude Notch

A Mac menu bar app that lives in the notch. Every running Claude Code or Claude Agent SDK session gets a little pixel Claude walking around the notch. When a session needs you, its Claude stops, turns to face you and waves a flag: red when it's blocked on a permission prompt, green when it has finished and it's your turn.

## Install

Needs macOS 15 (Sequoia) or later, on Apple silicon or Intel.

1. Download `Claude-Notch-<version>.zip` from the [Releases](../../releases) page and unzip it.
2. Drag **Claude Notch** into Applications and open it.
3. macOS blocks the first open because the app isn't notarized. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Claude Notch. (Or run `xattr -dr com.apple.quarantine "/Applications/Claude Notch.app"` once.)
4. In the welcome window, click **Install hooks**. Sessions you start from then on report everything; ones already open show up too.

The icon lives in your menu bar. Hover the notch to open the panel.

## Release

```bash
scripts/package.sh 1.0
gh release create v1.0 dist/Claude-Notch-1.0.zip --title "Claude Notch 1.0" --notes-file notes.md
```

`package.sh` builds a universal Release app, signs it ad hoc, and zips it into `dist/`. Without a Developer ID the app isn't notarized, hence the Open Anyway step, and macOS asks again for permissions (like controlling Terminal) after each update.

## Build and run

```bash
xcodegen generate
xcodebuild test -scheme ClaudeNotch -destination 'platform=macOS' -derivedDataPath build
open "build/Build/Products/Debug/Claude Notch.app"
```

On first launch a welcome window offers to install the hooks; you can also choose **Install Claude Code hooks** from the menu bar icon (a tiny pixel Claude under a notch, which raises a flag when a session needs you). It adds one hook per event to `~/.claude/settings.json` and keeps your file's original as `settings.json.claude-notch-backup`. **Remove Claude Code hooks** takes them out again. Sessions that were already running show up on their next event.

After an update that adds hook events, the menu says **Update Claude Code hooks** instead.

The menu also has Jump to waiting session (⌃⌥J from anywhere), Demo mode (fake agents that spawn, wave flags and leave every few seconds), a Debug submenu, Settings and Quit.

## What the Claudes show

- **Flags:** red for a permission prompt or question, green for a finished turn. A finished turn first gets a couple of hops with sparkles.
- **Props** for the tool in use: a pencil while editing, a book while reading or searching files, a hammer while running commands, a magnifying glass on the web.
- **Sub-agents** trail their parent as tiny Claudes (up to three), and the card shows `+N`.
- **Dozing:** a session that has been working with no events for 5 minutes walks slowly, naps with its eyes closed, and may be stuck.
- **The pointer:** bring it near the notch from below and nearby Claudes stop to look at it while name tags appear under them.
- **Cards** lead with the conversation's name (renaming a conversation renames its card), with its folder, running time and cost beneath, and show how long each session has waited. A held permission prompt shows Allow and Deny right on the card.
- **Cost and context:** each card shows what the session would cost at API list prices, and a hairline along its bottom shows how full the context window is (amber past 40%, red past 70%). Hover for the numbers. Past 40% the Claude carries a backpack, and past 70% a big bulging one that slows it down. `UsageReader` reads only the lines appended to each session's transcript since last time (every 3 s), counts each API response once (Claude Code writes one line per content block), and leaves sub-agents out of the context figure. Sub-agents' own transcripts aren't counted in the cost.
- **Greetings:** two Claudes that walk into each other sometimes stop, face each other and high-five before parting.
- **Drag to rearrange:** in the open panel, pick a Claude up and drop it on the left or right half. In the closed notch it walks back through the notch and stays on that side.

## Settings

Answer permission prompts from the notch (on), a sound when a session needs you (off), notch width, show on all displays, launch at login, and the hooks.

## How it works

- **Window:** a borderless panel that never takes focus (`NotchPanel`). It sits above the menu bar on every Space and over full-screen apps, and lets clicks through while closed.
- **Sizing:** `NotchMetrics` measures the notch from the gap between `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`. Without a notch (lid closed, external display) it draws a fake one as tall as the menu bar.
- **Shape:** the black shape grows wings sideways while any agent runs, and never gets taller than the menu bar. In the closed notch a Claude waves a short flag that fits in the strip, held on the side away from the notch.
- **Open panel:** hovering the notch opens it into a panel (`OpenNotchView`): a header beside the notch, a wide stage where the Claudes keep walking, and a card per agent (project, running time, last tool, or "Waiting on you"). Clicking a card clears its flag and brings the session's window to the front with keyboard focus (`WindowFocuser`): the session itself in Claude's desktop app (via a `claude://code/continue` link), the right tab in Terminal or iTerm (AppleScript, matched by tty, asks for Automation permission once), the folder's window in VS Code, Cursor, Windsurf or Zed, or just the app otherwise. The panel ignores the mouse while closed, so `NotchController` polls the pointer at 20 Hz to notice hovers; it closes 0.3 s after the pointer leaves.
- **Hooks:** every hook runs `curl -s -m 1 … http://127.0.0.1:47474/event || true`, posting the event JSON plus the Claude process ID (`$PPID`). It never prints and never fails, so Claude carries on whether or not the app is running. `HookServer` answers each post with 204 at once. `HookEvent` maps the event to a character, and `HookInstaller` edits the settings file.
- **Answering permissions:** the `PermissionRequest` hook posts to `/permission` instead and prints whatever comes back. The server holds that request for up to 20 s: Allow or Deny on the card replies with the hook's `decision` JSON. Everything else replies with nothing, and Claude asks as usual: the timeout, clicking the card (which hands the prompt back and focuses the window), the session moving on, or the app not running. The Claude Code docs don't say whether Claude shows its own prompt while the hook is still waiting. If it doesn't, a prompt you're not watching appears up to 20 s late. Turn the setting off if that bothers you.
- **Shortcut:** ⌃⌥J is a Carbon hot key (`GlobalShortcut`), so it needs no Accessibility permission.
- **Characters:** `Stage` is a pure, unit-tested simulation (walk, rest, attention, leave). `Sprite` draws the pixel art into a `Canvas`. Characters walk out of the notch, then stay on the wings either side of it and bump into each other instead of passing through. With Reduce Motion on they stand still and the flag doesn't ripple.

## Plan

1. **Notch window and fake walkers.** Done.
2. **Real agents through Claude Code hooks.** Done.

   | Event | Character |
   |---|---|
   | `SessionStart` | Walks out of the notch, labelled with the project folder |
   | `UserPromptSubmit`, `PreToolUse`, `PostToolUse(Failure)` | Walks around carrying a prop for the tool; clears the flag |
   | `PermissionRequest`, `Notification` (permission or question) | Stops, faces you, waves the red flag |
   | `Notification` (idle) | Waves the green flag |
   | `Stop` (finished its turn) | Hops, then waves the green flag |
   | `SubagentStart`, `SubagentStop` | A tiny Claude joins or leaves its trail |
   | `SessionEnd` | Walks back into the notch |

   Hooks aren't the only source: every 3 s the app also reads Claude Code's registry of running sessions (`~/.claude/sessions/<pid>.json`, `SessionRegistry`). That finds sessions that started before the hooks were installed, or haven't fired one since, with their title, folder and busy or idle status. Idle sessions doze.

   If a terminal is killed or a session crashes, so `SessionEnd` never fires, its Claude vanishes in a puff of smoke within 3 s of its process dying. Claude Agent SDK sessions post the same events from SDK hooks.
3. **Interaction.** Done.
4. **Polish.** Tool props, flag kinds, sub-agents, sound, settings and launch at login: done. Still to do: Developer ID signing and notarisation.

The pixel Claude is inspired by Anthropic's Claude Code mascot. That's fine for personal use; replace it with an original character before distributing.
