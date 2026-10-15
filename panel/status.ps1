# Writes STATUS.md: the short status every Claude session and helper reads first (instead of the big docs).
# Called by build.ps1 every 2 minutes. The user's ticks, notes and queue order (panel.json) are applied.
param($Info, [string]$PanelJson, [string[]]$Out, [string]$Name)

$utf8 = New-Object System.Text.UTF8Encoding($false)
$P = $null; if ($PanelJson -and $PanelJson -ne 'null') { $P = $PanelJson | ConvertFrom-Json }
function Short([string]$s, [int]$n) { $t = ($s -replace '\*\*', '' -replace '`', '' -replace '\s+', ' ').Trim(); if ($t.Length -gt $n) { $t.Substring(0, $n - 1) + '…' } else { $t } }
function MarkOf([string]$key) { if ($P -and $P.marks -and $P.marks.PSObject.Properties[$key]) { return $P.marks.$key } return $null }
$closed = @('done', 'answered', 'dropped')
$markedLabels = @{}
if ($P -and $P.marks) { foreach ($pr in $P.marks.PSObject.Properties) { if ($pr.Value.status -and $pr.Value.label) { $markedLabels[(Short $pr.Value.label 60)] = $pr.Value.status } } }
$sb = New-Object System.Text.StringBuilder
function L([string]$s) { [void]$sb.AppendLine($s) }

L ('# ' + $Name + ' status (auto, ' + (Get-Date).ToString('d MMM yyyy HH:mm') + ')')
L 'Rewritten every 2 minutes from the project docs, git, the live health check and the user''s panel. Read this first; open a big doc only for the one section you need. Code questions: graphify.'
L ''
$line = @()
if ($Info.live) { $line += ('**Live:** ' + $(if ($Info.live.ok) { 'up' + $(if ($Info.live.version) { ' ' + $Info.live.version } else { '' }) } else { 'NOT answering' })) }
if ($Info.git -and $Info.git.main) { $line += ('**Main:** ' + $Info.git.main.hash + $(if ($Info.git.main.version) { ' (' + $Info.git.main.version + ')' } else { '' })) }
if ($Info.lock) { $line += ('**Live lock:** ' + (Short $Info.lock.held 40) + ' — ' + (Short $Info.lock.what 140)) }
if ($Info.graph) { $line += ('**Code map:** ' + $(if ($Info.graph.behind -gt 0) { $Info.graph.behind.ToString() + ' commits behind (refreshing)' } else { 'current' })) }
L ($line -join ' · ')
foreach ($w in @($Info.warnings)) { L ('> ' + $w) }
L ''

L '## Built, not on main'
$bs = @($Info.git.branches | Where-Object { $_.unique -gt 0 })
if (-not $bs.Count) { L '- (none)' }
foreach ($b in $bs) { L ('- `' + $b.name + '`' + $(if ($b.version) { ' v' + $b.version } else { '' }) + ': ' + $b.unique + ' commits; last: ' + (Short $b.subject 110)) }
L ''

L '## Queue (the user''s order and ticks applied; open rows only)'
$q = @($Info.queue | ForEach-Object { $id = ($_.id -replace '\*\*', '').Trim(); $k = if ($id -and $id -ne '—' -and $id -ne '-') { 'q:' + $id } else { '' }; $m = if ($k) { MarkOf $k } else { $null }
    [pscustomobject]@{ key = $k; id = $id; title = $_.title; state = $_.state; status = $(if ($m -and $m.status) { $m.status } else { $_.status }); note = $(if ($m) { $m.note } else { '' }); mine = [bool]($m -and $m.status) } })
if ($P -and $P.myQueue) { foreach ($pr in $P.myQueue.PSObject.Properties) { $x = $pr.Value; $q += [pscustomobject]@{ key = $x.id; id = 'user'; title = $x.title; state = 'added by the user in the panel'; status = $x.status; note = ''; mine = $true } } }
$order = @(); if ($P -and $P.queueOrder -and $P.queueOrder.ids) { $order = @($P.queueOrder.ids) }
$q = @($q | Sort-Object @{ Expression = { $i = [array]::IndexOf($order, $_.key); if ($i -lt 0) { 100000 } else { $i } } }, @{ Expression = { [array]::IndexOf($q, $_) } })
$open = @($q | Where-Object { $closed -notcontains $_.status })
if (-not $open.Count) { L '- (empty)' }
foreach ($x in $open) { L ('- ' + $x.id + ' [' + $x.status + $(if ($x.mine) { ', set by user' } else { '' }) + '] ' + (Short $x.title 150) + ' — ' + (Short $x.state 110) + $(if ($x.note) { ' — user note: ' + $x.note } else { '' })) }
L ''

L '## The user''s notes (open; answer questions in panel.json or QA.md)'
$notes = @(); if ($P -and $P.notes) { $notes = @($P.notes.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { $_.status -notin @('done', 'wontdo') } | Sort-Object prio, updated) }
if (-not $notes.Count) { L '- (none)' }
foreach ($n in $notes) { L ('- ' + ([string]$n.prio).ToUpper() + ' ' + $n.type + ' [' + $n.status + '] ' + (Short $n.title 140) + $(if ($n.body) { ' — ' + (Short $n.body 180) } else { '' }) + $(if ($n.answer) { ' — answer: ' + (Short $n.answer 140) } else { '' }) + ' (id ' + $n.id + ')') }
L ''

L '## Waiting on the user (not ticked)'
$seen = @{}; $any = $false
foreach ($w in @($Info.waitingResume) + @($Info.waitingReq)) {
    if (-not $w) { continue }
    $s = Short $w 60; if ($seen[$s] -or ($markedLabels[$s] -and ($closed -contains $markedLabels[$s]))) { continue }
    $seen[$s] = 1; $any = $true; L ('- ' + (Short $w 170))
}
if (-not $any) { L '- (none)' }
L ''

if (@($Info.qa).Count) {
    L '## Latest questions and answers (QA.md)'
    foreach ($x in @($Info.qa | Select-Object -Last 6)) { L ('- ' + $x.date + ' Q: ' + (Short $x.q 120) + ' — A: ' + (Short $x.a 160)) }
    L ''
}
if (@($Info.checks).Count) {
    $chOpen = @($Info.checks | Where-Object { -not $_.done -and -not ((MarkOf ('c:' + $_.id)) -and ($closed -contains (MarkOf ('c:' + $_.id)).status)) })
    L ('## Before rollout: ' + (@($Info.checks).Count - $chOpen.Count) + ' of ' + @($Info.checks).Count + ' done')
    L ('Open: ' + (($chOpen | ForEach-Object { '#' + $_.id + ' ' + (Short $_.what 34) }) -join '; '))
    L ''
}
if (@($Info.requirements).Count) {
    $rq = @($Info.requirements | Where-Object { $_.status -ne 'done' })
    L ('## Requirements: ' + (@($Info.requirements).Count - $rq.Count) + ' of ' + @($Info.requirements).Count + ' done')
    foreach ($r in $rq) { L ('- #' + $r.id + ' ' + (Short $r.title 50) + ' [' + $r.status + ']: ' + (Short $r.state 140)) }
    L ''
}
L '## Latest coordination log'
foreach ($l in @($Info.log | Select-Object -First 6)) { L ('- ' + $l.when + ' ' + (Short $l.who 20) + ': ' + (Short $l.text 240)) }
if (-not @($Info.log).Count) { L '- (empty)' }
L ''
L '## Latest commits (all branches)'
foreach ($c in @($Info.git.commits | Select-Object -First 10)) { L ('- ' + $c.hash + ' ' + ([string]$c.at).Substring(0, 16).Replace('T', ' ') + ' ' + (Short $c.subject 120)) }

foreach ($path in $Out) {
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $path))) { continue }
    [IO.File]::WriteAllText($path + '.tmp', $sb.ToString(), $utf8)
    Move-Item -LiteralPath ($path + '.tmp') -Destination $path -Force
}
