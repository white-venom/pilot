# Pilot panel builder. Reads one project's pilot.json and writes, into that project's data folder:
#   live-data.js  the panel's data (the open page reloads it every 30 s and redraws in place)
#   STATUS.md     the short status every Claude session reads first (also copied to <project>\graphify-out\)
# and rebuilds the panel HTML when the template, data.js, the token or the fonts changed (always without -Auto).
# The task "Pilot panel - <name>" runs ".\build.ps1 -Config <data>\pilot.json -Auto" every 2 minutes.
# Windows PowerShell 5.1, no admin. Read-only on the project: git read commands and one optional health request.

param(
    [Parameter(Mandatory = $true)][string]$Config,
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'
$kit = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$cfg = [IO.File]::ReadAllText($Config, $utf8).TrimStart([char]0xFEFF) | ConvertFrom-Json
$here = Split-Path -Parent (Resolve-Path -LiteralPath $Config).Path      # the project's data folder
$repo = $cfg.project
$docsRel = if ($cfg.docsDir) { $cfg.docsDir } else { 'docs/project' }
$docsWin = $docsRel -replace '/', '\'
$mainBranch = if ($cfg.mainBranch) { $cfg.mainBranch } else { 'main' }
$templatePath = Join-Path $kit 'board.template.html'
$fontDir = Join-Path $kit 'fonts'
$dataPath = Join-Path $here 'data.js'
$livePath = Join-Path $here 'live-data.js'
$panelPath = Join-Path $here 'panel.json'
$tokenPath = Join-Path $here 'token.txt'
$Out = $cfg.panelHtml
$warnings = New-Object System.Collections.ArrayList
function Warn([string]$m) { [void]$warnings.Add($m) }

$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git -and $cfg.gitExe) { $git = $cfg.gitExe }
function G { $o = & $git -C $repo @args 2>$null; if ($LASTEXITCODE -ne 0) { return @() }; return @($o) }

# ---------------------------------------------------------------- where the docs are read from
# The main folder, plus each worktree whose branch has work the main branch doesn't have yet. For each doc, the copy
# whose CONTENT changed last wins: an uncommitted edit counts with its file time, else the last commit that changed it
# (file times mislead after a checkout; line counts mislead when an old branch holds a longer copy).
$docRoots = New-Object System.Collections.ArrayList
[void]$docRoots.Add($repo)
$wtPath = $null
foreach ($l in (G worktree list --porcelain)) {
    if ($l -like 'worktree *') { $wtPath = $l.Substring(9) -replace '/', '\' }
    elseif ($l -like 'branch refs/heads/*' -and $wtPath -and $wtPath -ne $repo) {
        $b = $l.Substring(18)
        if ($b -ne $mainBranch -and @((G cherry $mainBranch $b) | Where-Object { $_ -like '+*' }).Count -gt 0) { [void]$docRoots.Add($wtPath) }
    }
}
function Newest([string]$name) {
    $best = $null; $bestAt = 0
    foreach ($root in $docRoots) {
        $path = Join-Path $root ($docsWin + '\' + $name)
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $rel = $docsRel + '/' + $name
        & $git -C $root diff --quiet HEAD -- $rel 2>$null
        $at = 0
        if ($LASTEXITCODE -ne 1) { $at = [int64](((& $git -C $root log -1 --format=%ct -- $rel 2>$null) | Select-Object -First 1)) }
        if (-not $at) { $at = [int64]([DateTimeOffset](Get-Item -LiteralPath $path).LastWriteTime).ToUnixTimeSeconds() }
        if ($at -gt $bestAt) { $bestAt = $at; $best = Get-Item -LiteralPath $path }
    }
    return $best
}
function ReadLines($item) { if (-not $item) { return @() }; return [IO.File]::ReadAllLines($item.FullName, $utf8) }
function Src($item) { if (-not $item) { return $null }; return [ordered]@{ path = $item.FullName; at = $item.LastWriteTime.ToString('s'); kb = [math]::Round($item.Length / 1KB) } }
function Squash([string]$s) { return ($s -replace '\s+', ' ').Trim() }
function Cells([string]$line) { return @($line.Trim().Trim('|').Split('|') | ForEach-Object { Squash $_ }) }
function TableRows($lines, [string]$prefix) {
    $rows = New-Object System.Collections.ArrayList; $in = $false; $hdr = $false
    foreach ($l in $lines) {
        if ($l -match '^##\s+(.+)$') { $in = $Matches[1].StartsWith($prefix); $hdr = $false; continue }
        if (-not $in -or $l -notmatch '^\s*\|') { continue }
        if ($l -match '^\s*\|\s*:?-{2,}') { $hdr = $true; continue }
        if ($hdr) { [void]$rows.Add((Cells $l)) }
    }
    return $rows
}
function FirstTable($lines) {
    $rows = New-Object System.Collections.ArrayList; $hdr = $false
    foreach ($l in $lines) {
        if ($l -notmatch '^\s*\|') { if ($rows.Count) { break } else { continue } }
        if ($l -match '^\s*\|\s*:?-{2,}') { $hdr = $true; continue }
        if ($hdr) { [void]$rows.Add((Cells $l)) }
    }
    return $rows
}
function Bullets($lines, [string]$prefix) {
    $out = New-Object System.Collections.ArrayList; $in = $false
    foreach ($l in $lines) {
        if ($l -match '^##\s+(.+)$') { $in = $Matches[1].StartsWith($prefix); continue }
        if (-not $in) { continue }
        if ($l -match '^\s*-\s+(.+)$') { [void]$out.Add((Squash $Matches[1])) }
        elseif ($l -match '^\s{2,}\S' -and $out.Count) { $out[$out.Count - 1] = $out[$out.Count - 1] + ' ' + (Squash $l) }
    }
    return $out
}
# Status marks used in the docs: done, built-not-live, in progress, waiting, not started.
$E_DONE = [string][char]0x2705; $E_BUILT = [char]::ConvertFromUtf32(0x1F7E2); $E_WIP = [char]::ConvertFromUtf32(0x1F528)
$E_WAIT = [string][char]0x23F3; $E_NEXT = [string][char]0x25B6
function StatusOf([string]$s) {
    if ($s.Contains($E_WIP) -or $s.Contains($E_NEXT)) { return 'wip' }
    if ($s.Contains($E_BUILT)) { return 'code' }
    $d = $s.Contains($E_DONE)
    if ($d -and $s.Contains($E_WAIT)) { return 'part' }
    if ($s.Contains($E_WAIT)) { return 'wait' }
    if ($s -match '(?i)\banswered\b' -and $d) { return 'answered' }
    if ($s -match '(?i)\b(reversed|dropped)\b') { return 'dropped' }
    if ($d) { return 'done' }
    return 'todo'
}

$info = [ordered]@{ generatedAt = (Get-Date).ToString('s'); project = $cfg.name; sources = [ordered]@{} }

# ---------------------------------------------------------------- the project docs
try {
    $f = Newest 'REQUESTS.md'; $lines = ReadLines $f; $info.sources.requests = Src $f
    $info.queue = @(TableRows $lines 'Queue' | Where-Object { $_.Count -ge 4 } | ForEach-Object { [ordered]@{ id = $_[0]; title = $_[1]; who = $_[2]; state = $_[3]; status = (StatusOf $_[3]) } })
    $info.asks = @(TableRows $lines 'Requests' | Where-Object { $_.Count -ge 4 } | ForEach-Object {
        $asked = $_[1]; $date = ''
        if ($asked -match '^\((\d{1,2}(?:-\d{1,2})? \w{3})[^)]*\)\s*') { $date = $Matches[1]; $asked = $asked.Substring($Matches[0].Length) }
        [ordered]@{ id = $_[0]; date = $date; title = $asked; state = $_[2]; notes = (($_[3..($_.Count - 1)]) -join ' | '); status = (StatusOf $_[2]) } })
    $info.waitingReq = @(Bullets $lines 'Waiting on')
} catch { Warn ('REQUESTS.md: ' + $_.Exception.Message) }
try {
    $f = Newest 'BEFORE-ROLLOUT.md'; $lines = ReadLines $f; $info.sources.checks = Src $f
    $info.checks = @(FirstTable $lines | Where-Object { $_.Count -ge 6 } | ForEach-Object { [ordered]@{ id = $_[0]; what = $_[1]; since = $_[2]; target = $_[3]; how = $_[4]; done = $_[5].Contains($E_DONE); state = $_[5] } })
} catch { Warn ('BEFORE-ROLLOUT.md: ' + $_.Exception.Message) }
try {
    $f = Newest 'PROGRESS.md'; $lines = ReadLines $f; $info.sources.progress = Src $f
    $info.requirements = @(TableRows $lines 'Requirements' | Where-Object { $_.Count -ge 3 } | ForEach-Object { [ordered]@{ id = $_[0]; title = $_[1]; state = $_[2]; status = (StatusOf $_[2]) } })
    $info.rightNow = @(Bullets $lines 'Right now')
} catch { Warn ('PROGRESS.md: ' + $_.Exception.Message) }
try {
    $f = Newest 'PHASES.md'; $lines = ReadLines $f; $info.sources.phases = Src $f
    $info.phaseTable = @(FirstTable $lines | Where-Object { $_.Count -ge 4 } | ForEach-Object { [ordered]@{ phase = $_[0]; scope = $_[1]; estimate = $_[2]; state = $_[3]; status = (StatusOf $_[3]) } })
} catch { Warn ('PHASES.md: ' + $_.Exception.Message) }
try {
    # Questions the user asked in chat and their answers (sessions append them: "pilot.ps1 qa").
    $f = Newest 'QA.md'; $lines = ReadLines $f; $info.sources.qa = Src $f
    $info.qa = @(TableRows $lines 'Questions' | Where-Object { $_.Count -ge 4 } | ForEach-Object { [ordered]@{ id = $_[0]; date = $_[1]; q = $_[2]; a = $_[3]; by = $(if ($_.Count -ge 5) { $_[4] } else { '' }) } })
} catch { }
try {
    $f = Get-Item -LiteralPath (Join-Path $repo ($docsWin + '\COORDINATION.md')) -ErrorAction Stop
    $lines = ReadLines $f; $info.sources.coordination = Src $f
    $lock = @(TableRows $lines 'Live lock')
    if ($lock.Count) { $info.lock = [ordered]@{ held = $lock[0][0]; what = $lock[0][1]; since = $lock[0][2] } }
    $info.sessions = @(TableRows $lines 'Sessions' | Where-Object { $_.Count -ge 4 } | ForEach-Object { [ordered]@{ name = $_[0]; role = $_[1]; owns = $_[2]; since = $_[3] } })
    $info.claims = @(TableRows $lines 'File claims' | Where-Object { $_.Count -ge 3 } | ForEach-Object { [ordered]@{ what = $_[0]; owner = $_[1]; since = $_[2] } })
    $info.log = @(TableRows $lines 'Log' | Where-Object { $_.Count -ge 3 } | Select-Object -First 60 | ForEach-Object { [ordered]@{ when = $_[0]; who = $_[1]; text = (($_[2..($_.Count - 1)]) -join ' | ') } })
} catch { Warn ('COORDINATION.md: ' + $_.Exception.Message) }
try { $f = Newest 'RESUME.md'; $lines = ReadLines $f; $info.sources.resume = Src $f; $info.waitingResume = @(Bullets $lines 'Waiting on') } catch { }

# Doc sizes: every session pays for big docs in tokens, so the panel and STATUS.md say when to archive old rows.
$limitKb = if ($cfg.docWarnKb) { [int]$cfg.docWarnKb } else { 60 }
foreach ($k in @($info.sources.Keys)) { $s = $info.sources[$k]; if ($s -and $s.kb -gt $limitKb) { Warn ("{0} is {1} KB: run 'pilot.ps1 archive' to move old log rows out." -f (Split-Path -Leaf $s.path), $s.kb) } }

# ---------------------------------------------------------------- git (read-only)
function VersionAt([string]$ref, $vf) {
    $text = (G show ($ref + ':' + $vf.path)) -join "`n"
    if (-not $text) { return $null }
    if ($vf.regex) { if ($text -match $vf.regex) { return $Matches[1] } else { return $null } }
    return $text.Trim()
}
try {
    $gitInfo = [ordered]@{}
    $vfs = @($cfg.versionFiles | Where-Object { $_ })
    $m = (G log -1 '--format=%h|%cI|%s' $mainBranch) | Select-Object -First 1
    if ($m) { $p = $m.Split('|', 3); $gitInfo.main = [ordered]@{ hash = $p[0]; at = $p[1]; subject = $p[2]; version = $(if ($vfs.Count) { VersionAt $mainBranch $vfs[0] } else { $null }) } }
    $gitInfo.versions = @($vfs | ForEach-Object { [ordered]@{ label = $_.label; path = $_.path; value = (VersionAt $mainBranch $_) } })
    $wt = @{}; $cur = $null
    foreach ($l in (G worktree list --porcelain)) { if ($l -like 'worktree *') { $cur = $l.Substring(9) } elseif ($l -like 'branch refs/heads/*' -and $cur) { $wt[$l.Substring(18)] = $cur } }
    $branches = New-Object System.Collections.ArrayList
    $cutoff = (Get-Date).AddDays(-14)
    foreach ($l in (G for-each-ref --sort=-committerdate '--format=%(refname:short)|%(objectname:short)|%(committerdate:iso-strict)|%(subject)' refs/heads)) {
        $p = $l.Split('|', 4)
        if ($p.Count -lt 4 -or $p[0] -eq $mainBranch) { continue }
        if ([datetime]::Parse($p[2]) -lt $cutoff -and -not $wt.ContainsKey($p[0])) { continue }
        $ahead = [int]((G rev-list --count ($mainBranch + '..' + $p[0])) | Select-Object -First 1)
        if ($ahead -eq 0 -and -not $wt.ContainsKey($p[0])) { continue }
        $unique = $ahead
        if ($ahead -gt 0 -and $ahead -le 60) { $unique = @((G cherry $mainBranch $p[0]) | Where-Object { $_ -like '+*' }).Count }
        if ($unique -eq 0 -and -not $wt.ContainsKey($p[0])) { continue }
        [void]$branches.Add([ordered]@{ name = $p[0]; hash = $p[1]; at = $p[2]; subject = $p[3]; ahead = $ahead; unique = $unique; worktree = $wt[$p[0]]
            version = $(if ($unique -gt 0 -and $vfs.Count) { VersionAt $p[0] $vfs[0] } else { $null })
            commits = @(if ($unique -gt 0) { G log --no-merges -n 15 '--format=%h|%cI|%s' ($mainBranch + '..' + $p[0]) }) })
    }
    $gitInfo.branches = $branches
    $gitInfo.commits = @(G log --all --date-order -n 80 '--format=%h|%cI|%D|%s' | ForEach-Object { $p = $_.Split('|', 4); if ($p.Count -ge 4) { [ordered]@{ hash = $p[0]; at = $p[1]; refs = $p[2]; subject = $p[3] } } })
    $info.git = $gitInfo
} catch { Warn ('git: ' + $_.Exception.Message) }

# ---------------------------------------------------------------- live server (optional: healthUrls in pilot.json)
$urls = @($cfg.healthUrls | Where-Object { $_ })
if ($urls.Count) {
    $info.live = [ordered]@{ ok = $false; checkedAt = (Get-Date).ToString('s') }
    foreach ($u in $urls) {
        try {
            $rq = [Net.HttpWebRequest]::Create($u); $rq.Timeout = 5000; $rq.ReadWriteTimeout = 5000
            if ($cfg.healthInsecure) { $rq.ServerCertificateValidationCallback = { $true } }
            $rs = $rq.GetResponse()
            try { $raw = (New-Object IO.StreamReader($rs.GetResponseStream())).ReadToEnd(); $code = [int]$rs.StatusCode } finally { $rs.Close() }
            $h = $null; try { $h = $raw | ConvertFrom-Json } catch { }
            $ok = $code -ge 200 -and $code -lt 300 -and -not ($h -and $h.status -and $h.status -notmatch '^(ok|up|healthy|pass)$')
            $info.live = [ordered]@{ ok = $ok; version = $(if ($h) { $h.version } else { $null }); db = $(if ($h) { $h.db } else { $null }); url = $u; checkedAt = (Get-Date).ToString('s') }
            break
        } catch { }
    }
}

# ---------------------------------------------------------------- the save helper: start it again when it stopped
$helperUp = $false
try { $tc = New-Object Net.Sockets.TcpClient; $ar = $tc.BeginConnect('127.0.0.1', [int]$cfg.helperPort, $null, $null); $helperUp = $ar.AsyncWaitHandle.WaitOne(700) -and $tc.Connected; $tc.Close() } catch { }
if (-not $helperUp) { try { Start-ScheduledTask -TaskName ($cfg.taskName + ' (helper)') -ErrorAction Stop } catch { Warn 'The save helper is not running: run "pilot.ps1 doctor".' } }
$info.helper = $helperUp

# ---------------------------------------------------------------- the code map (graphify): freshness, refresh when behind
try {
    $gDir = Join-Path $repo 'graphify-out'; $gRep = Join-Path $gDir 'GRAPH_REPORT.md'
    if (Test-Path -LiteralPath $gRep) {
        $head = [IO.File]::ReadAllText($gRep)
        $built = if ($head -match 'Built from commit: `([0-9a-f]+)`') { $Matches[1] } else { '' }
        $behind = 0; if ($built) { $behind = [int]((G rev-list --count ($built + '..' + $mainBranch)) | Select-Object -First 1) }
        $info.graph = [ordered]@{ builtFrom = $built; at = (Get-Item -LiteralPath $gRep).LastWriteTime.ToString('s'); behind = $behind
            stats = $(if ($head -match '([\d,]+) nodes [^\d]+([\d,]+) edges') { $Matches[1] + ' nodes, ' + $Matches[2] + ' edges' } else { '' })
            html = ('file:///' + ((Join-Path $gDir 'graph.html') -replace '\\', '/')) }
        $stamp = Join-Path $here '.graphify-refresh'
        $last = if (Test-Path -LiteralPath $stamp) { (Get-Item -LiteralPath $stamp).LastWriteTime } else { [datetime]::MinValue }
        $gExe = (Get-Command graphify -ErrorAction SilentlyContinue).Source
        if (-not $gExe) { $c = Join-Path $env:APPDATA 'Python\Python312\Scripts\graphify.exe'; if (Test-Path $c) { $gExe = $c } }
        if ($behind -gt 0 -and ((Get-Date) - $last).TotalMinutes -ge 30 -and $gExe) {
            [IO.File]::WriteAllText($stamp, (Get-Date).ToString('s'))
            Start-Process -FilePath $gExe -ArgumentList 'update', '.' -WorkingDirectory $repo -WindowStyle Hidden | Out-Null
            $info.graph.refreshing = $true
        }
    }
} catch { Warn ('graphify: ' + $_.Exception.Message) }

# ---------------------------------------------------------------- the user's panel.json
$panelJson = 'null'
if (Test-Path -LiteralPath $panelPath) {
    try { $t = [IO.File]::ReadAllText($panelPath, $utf8).TrimStart([char]0xFEFF); $null = $t | ConvertFrom-Json; $panelJson = $t.Trim(); $info.sources.panel = Src (Get-Item -LiteralPath $panelPath) }
    catch { Warn ('panel.json is not valid JSON, ignored: ' + $_.Exception.Message) }
}
$info.warnings = $warnings

# ---------------------------------------------------------------- live-data.js
function SafeScript([string]$s) { return ([regex]::Replace($s, '</(script)', '<\/$1', 'IgnoreCase')).Replace('<!--', '<\!--') }
$autoJson = ConvertTo-Json -InputObject $info -Depth 8 -Compress
$liveJs = SafeScript ('window.__pilotLive && window.__pilotLive(' + $autoJson + ', ' + $panelJson + ');' + "`n" + 'window.PILOT_AUTO = ' + $autoJson + ';' + "`n" + 'window.PANEL_FILE = ' + $panelJson + ';' + "`n")
[IO.File]::WriteAllText($livePath + '.tmp', $liveJs, $utf8); Move-Item -LiteralPath ($livePath + '.tmp') -Destination $livePath -Force

# ---------------------------------------------------------------- STATUS.md (status.ps1)
$statusTargets = @((Join-Path $here 'STATUS.md'))
if (Test-Path -LiteralPath (Join-Path $repo 'graphify-out')) { $statusTargets += (Join-Path $repo 'graphify-out\STATUS.md') }
try { & (Join-Path $kit 'status.ps1') -Info $info -PanelJson $panelJson -Out $statusTargets -Name $cfg.name }
catch { Write-Output ('STATUS.md failed: ' + $_.Exception.Message) }
Write-Output ("{0}: queue {1}, asks {2}, checks {3}, requirements {4}, questions {5}, branches {6}{7}" -f $cfg.name, @($info.queue).Count, @($info.asks).Count, @($info.checks).Count, @($info.requirements).Count, @($info.qa).Count, @($info.git.branches).Count, $(if ($warnings.Count) { '; ' + ($warnings -join '; ') } else { '' }))

# ---------------------------------------------------------------- the HTML
if ($Auto -and (Test-Path -LiteralPath $Out)) {
    $outAt = (Get-Item -LiteralPath $Out).LastWriteTime
    $inputs = @($templatePath, $dataPath, $tokenPath, $Config) + @(Get-ChildItem -LiteralPath $fontDir -File | ForEach-Object { $_.FullName })
    if (-not ($inputs | Where-Object { (Test-Path -LiteralPath $_) -and (Get-Item -LiteralPath $_).LastWriteTime -gt $outAt })) { return }
}
$template = [IO.File]::ReadAllText($templatePath, $utf8)
$data = if (Test-Path -LiteralPath $dataPath) { [IO.File]::ReadAllText($dataPath, $utf8).TrimStart([char]0xFEFF) } else { '' }
$faces = New-Object System.Text.StringBuilder
foreach ($f in @(@{ File = 'inter-latin-wght-normal.woff2'; Family = 'Inter Variable' }, @{ File = 'jetbrains-mono-latin-wght-normal.woff2'; Family = 'JetBrains Mono Variable' })) {
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fontDir $f.File)))
    [void]$faces.AppendLine("@font-face { font-family: '" + $f.Family + "'; font-style: normal; font-display: swap; font-weight: 100 900; src: url(data:font/woff2;base64," + $b64 + ") format('woff2'); }")
}
$pilotCfg = [ordered]@{ name = $cfg.name; slug = $cfg.slug; dataDir = $here; taskName = $cfg.taskName; helperPort = [int]$cfg.helperPort; areas = @($cfg.areas) }
$dataBlock = '<script>' + "`n" + (SafeScript $data) + "`n" + 'window.PILOT = ' + (ConvertTo-Json -InputObject $pilotCfg -Compress) + ';' + "`n" +
    'window.PILOT_AUTO = ' + (SafeScript $autoJson) + ';' + "`n" + 'window.PANEL_FILE = ' + (SafeScript $panelJson) + ';' + "`n" + '</script>'
$token = if (Test-Path -LiteralPath $tokenPath) { ([IO.File]::ReadAllText($tokenPath, $utf8)).Trim() -replace '[^0-9a-f]', '' } else { '' }
$nameHtml = [Net.WebUtility]::HtmlEncode($cfg.name)
$html = $template.Replace('/*@@PILOT_FONTS@@*/', $faces.ToString()).Replace('<!--@@PILOT_DATA@@-->', $dataBlock).Replace('@@PILOT_LIVE_URL@@', ('file:///' + ($livePath -replace '\\', '/'))).Replace('@@PILOT_TOKEN@@', $token).Replace('@@PILOT_NAME@@', $nameHtml)
$outDir = Split-Path -Parent $Out
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
[IO.File]::WriteAllText($Out + '.tmp', $html, $utf8); Move-Item -LiteralPath ($Out + '.tmp') -Destination $Out -Force
Write-Output ("Built {0} ({1:N0} KB)" -f $Out, [math]::Round((Get-Item -LiteralPath $Out).Length / 1KB))
