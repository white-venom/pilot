## Pilot rules (how sessions and helpers work on {{NAME}})

**Start of every session and every helper**
- A new session already got the current status from the SessionStart hook (`graphify-out/STATUS.md`, rewritten every 2 minutes from the docs, git, the live health check and the user's panel). If not, read `graphify-out/STATUS.md` first.
- Then read only the top rules of `{{DOCS}}/COORDINATION.md`. Open other docs (PROGRESS, REQUESTS, DECISIONS, …) **only for the one section you need**, when STATUS.md lacks it, or when stuck. Never re-read whole docs or old chats to "catch up".
- Code questions go to the code map first: `graphify query "<question>"` (also `explain "<name>"`, `path "A" "B"`); read only the files it points to. The map refreshes itself after every commit.
- Before taking the next item, read the user's notes, ticks and queue order: STATUS.md shows them (source: `{{DATA}}\panel.json`).

**Talking to the user**
- Reply in simple {{LANGUAGE}}, short lists, no long explanations. The user may write in another language or mix languages.
- Relate every answer to the project; side topics in one line.
- Never answer "not possible": say how it will be done, what the issue is, and the workaround.
- The user leaves technical "how" decisions to Claude: decide, then say it briefly. Ask only when blocked on a decision that is really the user's.
- Never ask the user to do a step that can be automated. Steps that need the user (passwords, payments, physical access, approvals) come as one exact command or a short click list.

**Work order**
- **Queue, don't jump:** an ask that arrives while a task is running goes to the end of the Queue in `{{DOCS}}/REQUESTS.md` (`pilot.ps1 ask -Text "<ask>" -Queue`), with a one-line reply ("queued as #N"). The running task finishes first. Start at once only when the user says "now" or "urgent". Plain questions are answered straight away.
- **Every ask** goes into REQUESTS.md (`pilot.ps1 ask`). **Every question the user asks in chat** goes into QA.md with its answer (`pilot.ps1 qa -Q "…" -A "…" -Who <session>`), so it is never asked or answered twice.
- Each item runs Build → Test locally → Deploy → Test live → Done. One item goes live at a time.
- Don't start building a new phase until the user says "start".

**Several sessions and helpers at once**
- Before any live step (deploy, data change on the live system): take the live lock (`pilot.ps1 lock -Who <session> -What "<what>"`), release it after (`pilot.ps1 unlock -Who <session>`).
- Before editing shared files: a row under "File claims" in COORDINATION.md; remove it when committed.
- When an item is done: one log line (`pilot.ps1 log -Who <session> -Text "<what, where, tests>"`).
- Talk to other sessions with messages; never undo another session's work.

**Helpers (sub-agents) and tokens**
- One helper at a time by default. Choose the model per task: the cheapest that does it well (lookups and simple edits: small model; clear single-area changes, UI, docs, re-checks: mid model; first security audits, migrations, cross-cutting design: top model).
- Small briefs: name only the files the helper needs, give a step budget (~40 tool calls), tell it to read STATUS.md and use graphify. Helpers run targeted tests; the lead runs the full suites once per release.
- A helper stopped by a safety filter is restarted on another model with a narrower, plain brief; one stopped by a usage limit is resumed after the reset. Finished security-sensitive work gets an audit (`{{DOCS}}/AUDIT.md`); weak work is redone.
- One job per session; start a fresh session for a new job (the hook gives it the status for free).

**Docs and commits**
- After each batch of work (not each small edit): PROGRESS (status, next steps, a dated log line), PHASES (when a phase changes), DECISIONS (real choices), REPO-MAP (layout changes), then commit and push.
- Every test-phase shortcut (simple passwords, test servers, skipped checks) gets a row in `{{DOCS}}/BEFORE-ROLLOUT.md` in the same commit. No secrets in any doc.
- Before pausing or handing over: update `{{DOCS}}/RESUME.md` (what is done, what is next, exact commands), release the lock, commit, push.
- Commit messages in plain human language; never mention Claude or AI, no co-author lines. Push after every commit.
- Keep docs small: `pilot.ps1 archive` moves old log rows out (the panel warns when a doc grows past the limit).
- Status marks in the docs (the panel reads them): ✅ done · 🟢 built, not live · 🔨 being built · ⏳ waiting on the user · ⚪ not started.

**The panel** (`{{NAME}} panel.html` on the Desktop) updates itself every 2 minutes; sessions never edit it. Kit and commands: `{{KIT}}\pilot.ps1` (`doctor` repairs everything).
