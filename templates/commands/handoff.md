---
description: Pause cleanly - write the handoff, update the docs, release the lock, commit and push
---
1. Stop running helpers (their work is committed or listed as unfinished).
2. Overwrite `{{DOCS}}/RESUME.md`: doing now, next steps with exact commands, waiting on the user, gotchas.
3. Update the REQUESTS.md rows you worked on (status marks) and add a PROGRESS.md log line.
4. `pilot.ps1 unlock -Who <you>` if you hold the live lock; remove your File claims rows;
   `pilot.ps1 log -Who <you> -Text "Paused: <one line>"`.
5. Commit (plain message) and push. Tell the user in 3 lines what is saved and what comes next.
