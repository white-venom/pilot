# {{NAME}} — coordination board

Every session and every helper agent reads the top of this file before working. Keep it short: old log rows go to `archive/` (`pilot.ps1 archive`).

## How to use it (read this first, every time)
1. The status comes first: `graphify-out/STATUS.md` (a new session gets it from the SessionStart hook). Open other docs only for the section you need.
2. Before any live step (deploy, data change on the live system), take the live lock: `pilot.ps1 lock -Who <session> -What "<what>"`. Release it right after: `pilot.ps1 unlock -Who <session>`. One live action at a time.
3. Before editing shared files, add a row under "File claims"; remove it when committed.
4. When an item is done, add one log line: `pilot.ps1 log -Who <session> -Text "<what changed, where, tests>"`.
5. Code questions: `graphify query "<question>"`, not whole-file reads.

## Sessions and roles (update when a session starts or stops)
| Session | Role | Owns | Since |
|---|---|---|---|

## Live lock (one live action at a time)
| Held by | What | Since |
|---|---|---|
| — (free) | | {{DATE}} |

## File claims (remove your row when committed)
| Area / files | Owner | Since |
|---|---|---|

## Log (newest first; one line per finished item)
| When | Who | Done |
|---|---|---|
| {{DATE}} | pilot | Pilot set up: panel, STATUS.md, rules, doc templates. |
