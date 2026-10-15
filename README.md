# Pilot

**A self-updating project panel plus the working rules that let several Claude Code sessions and helper agents
work on one project together and spend few tokens.** One command sets it up in any git project.

## What you get
- **The panel** (`<Project> panel.html` on your Desktop). It opens from the Desktop with no server and no internet, and refreshes itself.
  - **Easy mode:** the project in plain words (done / being worked on / needs you), next up, a big "tell Claude something" box, the latest news.
  - **Advanced mode:** every page — queue (drag to reorder), board (kanban), notebook, requirements, features per phase, every ask, before-rollout checklist, releases and branches, activity, search everywhere.
  - **Summary button:** pick what to summarise (built not live, in progress, not started, needs you, done lately, questions and answers, …) and get plain text or Markdown to copy or save.
  - **Questions & answers:** every question you asked in chat, with its answer, searchable.
  - **Your own data:** your ticks, statuses, notes and queue order are saved automatically. Claude sessions read them.
- **STATUS.md:** a ~5–10 KB status, rewritten every 2 minutes from the docs, git, the live health check and your panel.
  A **SessionStart hook** feeds it into every new Claude session, so no session re-reads chats or big docs to catch up.
- **The rules** (a managed block in `CLAUDE.md`):
  - status first, graphify for code
  - queue, don't jump
  - one live action at a time (live lock)
  - file claims
  - log lines
  - every ask in REQUESTS.md, every question in QA.md
  - helper model choice and token budgets
  - handoffs
  - test shortcuts recorded before the rollout
- **Project docs** in `docs/project/` (created once, never overwritten): COORDINATION, REQUESTS, QA, PROGRESS, PHASES,
  DECISIONS, BEFORE-ROLLOUT, RESUME, REPO-MAP, AUDIT.
- **Doc commands** (`pilot.ps1 lock / unlock / log / ask / qa / archive`): sessions update the docs without opening them.
- **Claude commands:** `/status`, `/resume`, `/handoff`, `/qa`, `/summary`.
- **graphify:** the code map plus its git hook, so the map refreshes after each commit. The panel shows how fresh it is, and refreshes it when it falls behind.

## Set it up in a project
```powershell
git clone https://github.com/white-venom/pilot C:\Users\<you>\pilot        # once
powershell -ExecutionPolicy Bypass -File C:\Users\<you>\pilot\pilot.ps1 install -Project C:\path\to\project -Name "My Project"
```
Options:
- `-HealthUrl https://server/api/health [-HealthInsecure]` shows the live server.
- `-VersionFile 'App=package.json="version":\s*"([^"]+)"'` shows a version, from a file and an optional regex.
- `-Areas Frontend,Backend,Infra` sets the note areas.
- `-Language English` sets the reply language for the rules.

It's safe to run again: it repairs, and keeps your docs and data. Then commit the new `docs/project/`, `CLAUDE.md` and `.claude/commands/`.

Needs Windows 10/11 or Server with Windows PowerShell 5.1 and git. Node.js runs the save helper (without it, your edits stay in the browser only). graphify is optional (`pip install graphifyy`). Use Chrome or Edge for the panel.

## Every day
| You want | Do |
|---|---|
| See how it's going | Open the panel (Easy mode) |
| Tell Claude about a bug / wish / question | Home → "Tell Claude something", or the Notebook |
| A report | **Summary** → pick the parts → Copy |
| Change the order of work | Advanced → Queue (drag) or Board |
| Start a session | Just start it: the hook gives it the status. `/resume` takes the next item |
| Pause | `/handoff` |
| Something looks stale | `pilot.ps1 doctor -Fix` |

## Commands
```
pilot.ps1 install  -Project <path> [-Name ..] [-HealthUrl ..] [-VersionFile ..] [-Areas ..] [-Language ..] [-NoTasks]
pilot.ps1 doctor   [-Fix]                 tasks, helper, data age, code map, hook, doc sizes
pilot.ps1 status | context | build        print STATUS.md / what the hook prints / refresh now
pilot.ps1 lock -Who s -What "deploy 1.4"  ·  unlock -Who s  ·  log -Who s -Text "…"
pilot.ps1 ask -Text "…" [-Queue]          ·  qa -Q "…" -A "…" -Who s  ·  archive [-Days 14]
pilot.ps1 uninstall                        removes the two tasks (docs and data stay)
```
`-Project` defaults to the git project of the current folder.

## How it works
- Each project's private data folder is `Documents\Pilot\<project>\`. It holds `pilot.json` (settings), `panel.json` (your notes, ticks and order), `token.txt` (the helper's secret), `live-data.js`, `STATUS.md` and the logs.
- **Task "Pilot panel - <name>":** runs every 2 minutes and at sign-in, as your user (no admin), at normal priority. It reads the docs and git and writes the files above.
  - For each doc it uses the newest copy in the main folder or any worktree with unshipped work.
- **Task "Pilot panel - <name> (helper)":** runs `panel/panel-server.js` on `127.0.0.1:<port>` with a secret key. The panel saves your edits through it, and the refresh task restarts it if it stops.
- **The panel:** loads `live-data.js` every 30 seconds and redraws in place. Your edits merge item by item (the newest wins), so a session can answer a question in `panel.json` and you see it in the panel.
- **Status marks the panel reads in the docs:** ✅ done · 🟢 built, not live · 🔨 being built · ⏳ waiting on the user · ⚪ not started.

## Layout
```
pilot.ps1                 the command (install, doctor, doc commands)
panel/board.template.html the panel (one file; fonts and data are embedded at build)
panel/build.ps1           reads the project, writes live-data.js + STATUS.md, builds the HTML
panel/status.ps1          writes STATUS.md
panel/panel-server.js     the local save helper (Node, no packages)
panel/fonts/              Inter + JetBrains Mono (SIL Open Font License 1.1)
templates/docs/           the project docs
templates/CLAUDE.block.md the rules block put into CLAUDE.md
templates/commands/       the Claude commands
```
