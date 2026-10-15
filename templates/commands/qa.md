---
description: Record the user's questions from this chat and their answers in QA.md
---
For every question the user asked in this chat that is not in `{{DOCS}}/QA.md` yet, run
`pilot.ps1 qa -Q "<the question, one line>" -A "<the answer, 1-3 lines>" -Who <you>`.
Also answer any open question in the user's notes (STATUS.md, "The user's notes") that you can answer now: write the
answer into the note's `answer` field in `{{DATA}}\panel.json` (set `updated` to the current UTC time).
