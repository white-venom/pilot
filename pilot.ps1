<#
.SYNOPSIS
    Pilot: a self-updating project panel + the working rules that let several Claude sessions and helper agents
    coordinate on one project and spend few tokens. One command sets it up in any git project.

.DESCRIPTION
    pilot.ps1 install  -Project <path> [-Name <name>] [-HealthUrl <url>] [-VersionFile 'Label=path[=regex]'] [-Areas a,b]
                       [-Language English] [-NoTasks]
        Sets up the project: docs/project/* templates (never overwrites), the rules block in CLAUDE.md, Claude commands
        (/status /resume /handoff /qa /summary), a SessionStart hook that feeds STATUS.md into every new session, graphify
        (code map + its git hook), the data folder Documents\Pilot\<slug>, two per-user tasks (panel refresh every 2 min;
        the local save helper) and the panel on the Desktop. Safe to run again (repairs, keeps your data).
    pilot.ps1 doctor   [-Project <path>] [-Fix]        checks tasks, helper, data age, code map, doc sizes; -Fix repairs
    pilot.ps1 status   [-Project <path>]               prints STATUS.md
    pilot.ps1 context  [-Project <path>]               what the SessionStart hook prints (STATUS.md + the key rules)
    pilot.ps1 lock     -Who <session> -What <text> [-Force]    takes the live lock (COORDINATION.md)
    pilot.ps1 unlock   -Who <session>                          releases it
    pilot.ps1 log      -Who <session> -Text <text>             adds a line to the coordination log
    pilot.ps1 ask      -Text <text> [-Queue]                   adds the user's request to REQUESTS.md (+ the queue)
    pilot.ps1 qa       -Q <question> -A <answer> [-Who <session>]   records a question asked in chat and its answer
    pilot.ps1 archive  [-Days 14]                              moves old log rows to docs/project/archive/
    pilot.ps1 build    [-Project <path>]                       refreshes the panel now
    pilot.ps1 uninstall [-Project <path>]                      removes the tasks (docs and data stay)
    -Project defaults to the git project of the current folder. Windows PowerShell 5.1; no admin.
#>
param(
    [Parameter(Position = 0)][ValidateSet('install', 'doctor', 'status', 'context', 'lock', 'unlock', 'log', 'ask', 'qa', 'archive', 'build', 'uninstall', 'help')]
    [string]$Command = 'help',
    [string]$Project, [string]$Name, [string[]]$HealthUrl, [switch]$HealthInsecure, [string[]]$VersionFile, [string[]]$Areas,
    [string]$Language = 'English', [switch]$NoTasks, [switch]$Fix, [switch]$Force, [switch]$Queue,
    [string]$Who, [string]$What, [string]$Text, [string]$Q, [string]$A, [int]$Days = 14
)

$ErrorActionPreference = 'Stop'
$Kit = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$utf8 = New-Object System.Text.UTF8Encoding($false)
$StatusMarks = @{ done = [string][char]0x2705; built = [char]::ConvertFromUtf32(0x1F7E2); wip = [char]::ConvertFromUtf32(0x1F528); wait = [string][char]0x23F3; todo = [string][char]0x26AA }

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function ReadText([string]$p) { return [IO.File]::ReadAllText($p, $utf8).TrimStart([char]0xFEFF) }
function WriteText([string]$p, [string]$t) { $d = Split-Path -Parent $p; if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; [IO.File]::WriteAllText($p, $t, $utf8) }
function Cell([string]$s) { return (($s -replace '\|', '/') -replace '\r?\n', ' ').Trim() }
function Now { return (Get-Date).ToString('yyyy-MM-dd HH:mm') }

function Get-ProjectRoot {
    $start = if ($Project) { $Project } else { (Get-Location).Path }
    $root = (& git -C $start rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $root) { throw "Not a git project: $start (run 'git init' first)" }
    return ($root -replace '/', '\')
}
function Get-Slug([string]$n) { $s = ($n.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); if (-not $s) { $s = 'project' }; return $s }
function Get-DataDir([string]$slug) { return Join-Path ([Environment]::GetFolderPath('MyDocuments')) ('Pilot\' + $slug) }
function Find-Config([string]$root) {
    $marker = Join-Path $root '.pilot'
    if (Test-Path -LiteralPath $marker) { $c = (ReadText $marker).Trim(); if (Test-Path -LiteralPath $c) { return $c } }
    $slug = Get-Slug (Split-Path -Leaf $root)
    $c = Join-Path (Get-DataDir $slug) 'pilot.json'
    if (Test-Path -LiteralPath $c) { return $c }
    throw "Pilot is not installed in $root. Run: pilot.ps1 install -Project `"$root`""
}
function Load-Config([string]$root) { $p = Find-Config $root; $c = ReadText $p | ConvertFrom-Json; Add-Member -InputObject $c -NotePropertyName _path -NotePropertyValue $p -Force; return $c }
function DocPath($cfg, [string]$file) { return Join-Path $cfg.project ((($cfg.docsDir) -replace '/', '\') + '\' + $file) }

# Insert a row at the top (or end) of the markdown table under "## <heading>".
function Add-TableRow([string]$path, [string]$heading, [string]$row, [switch]$Append) {
    $lines = [Collections.Generic.List[string]]([IO.File]::ReadAllLines($path, $utf8))
    $h = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match ('^##\s+' + [regex]::Escape($heading))) { $h = $i; break } }
    if ($h -lt 0) { throw "No '## $heading' section in $path" }
    $sep = -1; for ($i = $h + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^##\s') { break }; if ($lines[$i] -match '^\s*\|\s*:?-{2,}') { $sep = $i; break } }
    if ($sep -lt 0) { throw "No table under '## $heading' in $path" }
    if ($Append) { $j = $sep + 1; while ($j -lt $lines.Count -and $lines[$j] -match '^\s*\|') { $j++ }; $lines.Insert($j, $row) } else { $lines.Insert($sep + 1, $row) }
    [IO.File]::WriteAllLines($path, $lines, $utf8)
}
function Get-TableRows([string]$path, [string]$heading) {
    $rows = @(); $in = $false; $hdr = $false
    foreach ($l in [IO.File]::ReadAllLines($path, $utf8)) {
        if ($l -match '^##\s+(.+)$') { $in = $Matches[1].StartsWith($heading); $hdr = $false; continue }
        if (-not $in -or $l -notmatch '^\s*\|') { continue }
        if ($l -match '^\s*\|\s*:?-{2,}') { $hdr = $true; continue }
        if ($hdr) { $rows += , @($l.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() }) }
    }
    return $rows
}
function Set-LockRow([string]$path, [string]$row) {
    $lines = [Collections.Generic.List[string]]([IO.File]::ReadAllLines($path, $utf8))
    $h = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^##\s+Live lock') { $h = $i; break } }
    if ($h -lt 0) { throw "No '## Live lock' section in $path" }
    for ($i = $h + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\|\s*:?-{2,}') {
            if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s*\|') { $lines[$i + 1] = $row } else { $lines.Insert($i + 1, $row) }
            [IO.File]::WriteAllLines($path, $lines, $utf8); return
        }
    }
    throw "No table under '## Live lock' in $path"
}

# ---------------------------------------------------------------- scheduled tasks (per user, no admin, no password)
function Register-PilotTasks($cfg) {
    $dir = Split-Path -Parent $cfg._path
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    function Launcher([string]$file, [string]$cmd) {
        $vbs = Join-Path $dir $file
        WriteText $vbs ('CreateObject("WScript.Shell").Run "' + $cmd.Replace('"', '""') + '", 0, True' + "`r`n")
        return $vbs
    }
    $log = Join-Path $dir 'auto-update.log'
    $vb = Launcher 'run-build.vbs' ('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& ''' + (Join-Path $Kit 'panel\build.ps1') + ''' -Config ''' + $cfg._path + ''' -Auto *> ''' + $log + '''"')
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $logon = New-ScheduledTaskTrigger -AtLogOn -User $user
    $every = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 2)
    # Priority 6 = normal: the default (below normal) can starve the 2-second refresh on a busy machine for minutes.
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -Priority 6
    $task = New-ScheduledTask -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "' + $vb + '"') -WorkingDirectory $dir) -Trigger @($every, $logon) -Settings $set -Principal $principal -Description ('Pilot: refreshes the ' + $cfg.name + ' panel and STATUS.md (read-only).')
    Register-ScheduledTask -TaskName $cfg.taskName -InputObject $task -Force | Out-Null
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { $node = (Get-ChildItem (Join-Path $env:USERPROFILE 'tools') -Recurse -Filter node.exe -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
    if ($node) {
        $vs = Launcher 'run-helper.vbs' ('"' + $node + '" "' + (Join-Path $Kit 'panel\panel-server.js') + '" "' + $dir + '" ' + $cfg.helperPort)
        $sset = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Priority 6 -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
        $stask = New-ScheduledTask -Action (New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "' + $vs + '"') -WorkingDirectory $dir) -Trigger @($logon) -Settings $sset -Principal $principal -Description ('Pilot: local save helper for the ' + $cfg.name + ' panel (127.0.0.1:' + $cfg.helperPort + ').')
        Register-ScheduledTask -TaskName ($cfg.taskName + ' (helper)') -InputObject $stask -Force | Out-Null
        Start-ScheduledTask -TaskName ($cfg.taskName + ' (helper)')
    } else { Say '  Node.js not found: the panel saves in the browser only (install Node and run "pilot.ps1 doctor -Fix").' Yellow }
    Start-ScheduledTask -TaskName $cfg.taskName
}

# ---------------------------------------------------------------- install
function Invoke-Install {
    $root = Get-ProjectRoot
    $displayName = if ($Name) { $Name } else { Split-Path -Leaf $root }
    $slug = Get-Slug $displayName
    $dataDir = Get-DataDir $slug
    $cfgPath = Join-Path $dataDir 'pilot.json'
    Say "Pilot install: $displayName ($root)" Cyan
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

    # 1. config (kept when it exists; new values from the command line win)
    $cfg = if (Test-Path -LiteralPath $cfgPath) { ReadText $cfgPath | ConvertFrom-Json } else { [pscustomobject]@{} }
    function SetC([string]$k, $v) { if ($null -ne $v) { Add-Member -InputObject $cfg -NotePropertyName $k -NotePropertyValue $v -Force } }
    $port = if ($cfg.helperPort) { $cfg.helperPort } else { $h = 0; foreach ($ch in $slug.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 100000 }; 47300 + ($h % 600) }
    $main = (& git -C $root symbolic-ref --short HEAD 2>$null); if (-not $main) { $main = 'main' }
    SetC name $displayName; SetC slug $slug; SetC project $root; SetC helperPort $port; SetC taskName ('Pilot panel - ' + $displayName)
    if (-not $cfg.docsDir) { SetC docsDir 'docs/project' }
    if (-not $cfg.mainBranch) { SetC mainBranch $main }
    if (-not $cfg.panelHtml) { SetC panelHtml (Join-Path ([Environment]::GetFolderPath('Desktop')) ($displayName + ' panel.html')) }
    if ($HealthUrl) { SetC healthUrls @($HealthUrl); SetC healthInsecure ([bool]$HealthInsecure) } elseif (-not $cfg.healthUrls) { SetC healthUrls @() }
    if ($VersionFile) { SetC versionFiles @($VersionFile | ForEach-Object { $p = $_.Split('=', 3); [ordered]@{ label = $p[0]; path = $p[1]; regex = $(if ($p.Count -ge 3) { $p[2] } else { $null }) } }) } elseif (-not $cfg.versionFiles) { SetC versionFiles @() }
    if ($Areas) { SetC areas @($Areas) } elseif (-not $cfg.areas) { SetC areas @('Frontend', 'Backend', 'Infra', 'Live system', 'Docs', 'Process', 'Other') }
    if (-not $cfg.docWarnKb) { SetC docWarnKb 60 }
    WriteText $cfgPath ($cfg | ConvertTo-Json -Depth 6)
    WriteText (Join-Path $root '.pilot') $cfgPath
    $tokenPath = Join-Path $dataDir 'token.txt'
    if (-not (Test-Path -LiteralPath $tokenPath)) { $b = New-Object byte[] 32; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); WriteText $tokenPath (($b | ForEach-Object { $_.ToString('x2') }) -join '') }
    Say "  config: $cfgPath (helper port $port)"

    # 2. docs (never overwritten)
    $docs = Join-Path $root (($cfg.docsDir) -replace '/', '\')
    $vars = @{ '{{NAME}}' = $displayName; '{{DATE}}' = (Get-Date).ToString('yyyy-MM-dd'); '{{DATA}}' = $dataDir; '{{KIT}}' = $Kit; '{{LANGUAGE}}' = $Language; '{{DOCS}}' = $cfg.docsDir }
    function Fill([string]$t) { foreach ($k in $vars.Keys) { $t = $t.Replace($k, $vars[$k]) }; return $t }
    foreach ($f in Get-ChildItem (Join-Path $Kit 'templates\docs') -File) {
        $dst = Join-Path $docs $f.Name
        if (Test-Path -LiteralPath $dst) { Say "  keep  $($cfg.docsDir)/$($f.Name)" DarkGray } else { WriteText $dst (Fill (ReadText $f.FullName)); Say "  added $($cfg.docsDir)/$($f.Name)" }
    }

    # 3. CLAUDE.md rules block (between markers; your own text around it stays)
    $claude = Join-Path $root 'CLAUDE.md'
    $block = (Fill (ReadText (Join-Path $Kit 'templates\CLAUDE.block.md'))).Trim()
    $block = "<!-- pilot:start (managed by pilot.ps1; edit the kit's templates\CLAUDE.block.md, not here) -->`n" + $block + "`n<!-- pilot:end -->"
    if (Test-Path -LiteralPath $claude) {
        $t = ReadText $claude
        if ($t -match '(?s)<!-- pilot:start.*?<!-- pilot:end -->') { $t = [regex]::Replace($t, '(?s)<!-- pilot:start.*?<!-- pilot:end -->', [Text.RegularExpressions.MatchEvaluator] { param($m) $block }) }
        else { $t = $t.TrimEnd() + "`n`n" + $block + "`n" }
        WriteText $claude $t; Say '  CLAUDE.md: rules block updated'
    } else { WriteText $claude ("# $displayName`n`n(Describe the project here: what it is, the stack, how to run and test it.)`n`n" + $block + "`n"); Say '  CLAUDE.md: created' }

    # 4. Claude commands and the SessionStart hook (settings.local.json: per machine, not committed)
    foreach ($f in Get-ChildItem (Join-Path $Kit 'templates\commands') -File) {
        $dst = Join-Path $root ('.claude\commands\' + $f.Name)
        if (-not (Test-Path -LiteralPath $dst)) { WriteText $dst (Fill (ReadText $f.FullName)); Say "  added .claude/commands/$($f.Name)" }
    }
    $settingsPath = Join-Path $root '.claude\settings.local.json'
    $settings = if (Test-Path -LiteralPath $settingsPath) { ReadText $settingsPath | ConvertFrom-Json } else { [pscustomobject]@{} }
    $hookCmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Kit 'pilot.ps1') + '" context -Project "' + $root + '"'
    if (-not $settings.hooks) { Add-Member -InputObject $settings -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) -Force }
    $ss = @($settings.hooks.SessionStart | Where-Object { $_ -and -not ((($_.hooks | ForEach-Object { $_.command }) -join ' ') -match 'pilot\.ps1') })
    $ss += [pscustomobject]@{ hooks = @([pscustomobject]@{ type = 'command'; command = $hookCmd }) }
    Add-Member -InputObject $settings.hooks -NotePropertyName SessionStart -NotePropertyValue $ss -Force
    WriteText $settingsPath ($settings | ConvertTo-Json -Depth 10)
    Say '  SessionStart hook: every new session starts with STATUS.md'

    # 5. .gitignore + graphify (code map and its git hook)
    $gi = Join-Path $root '.gitignore'
    $giText = if (Test-Path -LiteralPath $gi) { ReadText $gi } else { '' }
    $need = @('graphify-out/', '.pilot', '.claude/settings.local.json') | Where-Object { $giText -notmatch ('(?m)^' + [regex]::Escape($_) + '\s*$') }
    if ($need) { WriteText $gi ($giText.TrimEnd() + "`n# Pilot (local only)`n" + ($need -join "`n") + "`n"); Say ('  .gitignore: ' + ($need -join ', ')) }
    $gExe = (Get-Command graphify -ErrorAction SilentlyContinue).Source
    if (-not $gExe) { $c = Join-Path $env:APPDATA 'Python\Python312\Scripts\graphify.exe'; if (Test-Path $c) { $gExe = $c } }
    if ($gExe) {
        Push-Location $root
        try { & $gExe hook install *> $null; Say '  graphify: git hook installed (map refreshes after each commit)' } catch { Say "  graphify hook: $($_.Exception.Message)" Yellow }
        if (-not (Test-Path -LiteralPath (Join-Path $root 'graphify-out\GRAPH_REPORT.md'))) { Start-Process -FilePath $gExe -ArgumentList 'update', '.' -WorkingDirectory $root -WindowStyle Hidden | Out-Null; Say '  graphify: first code map building in the background' }
        Pop-Location
    } else { Say '  graphify not found: pip install graphifyy (then run "pilot.ps1 doctor -Fix"); the panel works without it.' Yellow }
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'graphify-out') | Out-Null

    # 6. tasks + first build
    $cfg = Load-Config $root
    if (-not $NoTasks) { Register-PilotTasks $cfg; Say ("  tasks: '" + $cfg.taskName + "' every 2 min, '" + $cfg.taskName + " (helper)' at sign-in") }
    & (Join-Path $Kit 'panel\build.ps1') -Config $cfg._path | ForEach-Object { Say "  $_" }
    Say ''
    Say "Done. Open: $($cfg.panelHtml)" Green
    Say 'Commit the new docs, CLAUDE.md and .claude/commands; the data folder and .claude/settings.local.json stay on this PC.' Green
}

# ---------------------------------------------------------------- doctor
function Invoke-Doctor {
    $root = Get-ProjectRoot; $cfg = Load-Config $root; $dir = Split-Path -Parent $cfg._path; $bad = 0
    function Check([bool]$ok, [string]$m, [string]$fixHint) { if ($ok) { Say "  OK    $m" Green } else { $script:bad++; Say "  FIX   $m — $fixHint" Yellow } }
    Say "Pilot doctor: $($cfg.name)" Cyan
    foreach ($n in @($cfg.taskName, ($cfg.taskName + ' (helper)'))) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        $i = if ($t) { Get-ScheduledTaskInfo -TaskName $n } else { $null }
        Check ([bool]$t -and ($t.State -ne 'Disabled')) ("task '$n'" + $(if ($i) { ' (last result ' + $i.LastTaskResult + ')' } else { '' })) 'pilot.ps1 doctor -Fix'
    }
    $live = Join-Path $dir 'live-data.js'
    Check ((Test-Path $live) -and ((Get-Date) - (Get-Item $live).LastWriteTime).TotalMinutes -lt 10) 'panel data refreshed in the last 10 minutes' 'check auto-update.log in the data folder'
    $up = $false; try { $tc = New-Object Net.Sockets.TcpClient; $ar = $tc.BeginConnect('127.0.0.1', [int]$cfg.helperPort, $null, $null); $up = $ar.AsyncWaitHandle.WaitOne(700) -and $tc.Connected; $tc.Close() } catch { }
    Check $up ("save helper on 127.0.0.1:" + $cfg.helperPort) 'pilot.ps1 doctor -Fix (needs Node.js)'
    $rep = Join-Path $root 'graphify-out\GRAPH_REPORT.md'
    Check (Test-Path $rep) 'graphify code map' 'pip install graphifyy; graphify update .'
    Check (Test-Path (Join-Path $root 'graphify-out\STATUS.md')) 'STATUS.md next to the code map' 'pilot.ps1 build'
    $sl = Join-Path $root '.claude\settings.local.json'
    Check ((Test-Path $sl) -and ((ReadText $sl) -match 'pilot\.ps1')) 'SessionStart hook' 'pilot.ps1 install (again)'
    foreach ($f in Get-ChildItem (Join-Path $root (($cfg.docsDir) -replace '/', '\')) -Filter *.md -ErrorAction SilentlyContinue) {
        if ($f.Length / 1KB -gt [int]$cfg.docWarnKb) { Check $false ("$($f.Name) is $([math]::Round($f.Length / 1KB)) KB") 'pilot.ps1 archive' }
    }
    if ($Fix -and $bad) { Say 'Repairing…' Cyan; Register-PilotTasks $cfg; & (Join-Path $Kit 'panel\build.ps1') -Config $cfg._path | Out-Null; Say 'Done. Run doctor again to check.' Green }
    elseif (-not $bad) { Say 'All good.' Green }
}

# ---------------------------------------------------------------- the doc commands (sessions use these instead of opening big docs)
switch ($Command) {
    'help' { Get-Help $MyInvocation.MyCommand.Path -Detailed | Out-String | Write-Host; break }
    'install' { Invoke-Install; break }
    'doctor' { Invoke-Doctor; break }
    'build' { $cfg = Load-Config (Get-ProjectRoot); & (Join-Path $Kit 'panel\build.ps1') -Config $cfg._path; break }
    'status' { $cfg = Load-Config (Get-ProjectRoot); Write-Output (ReadText (Join-Path (Split-Path -Parent $cfg._path) 'STATUS.md')); break }
    'context' {
        # Printed by the SessionStart hook into every new Claude session. Keep it short: it costs tokens every time.
        try {
            $cfg = Load-Config (Get-ProjectRoot)
            $s = Join-Path (Split-Path -Parent $cfg._path) 'STATUS.md'
            Write-Output ('[Pilot] ' + $cfg.name + ': current status below (auto, every 2 min). Rules: CLAUDE.md "Pilot rules". Doc commands: pilot.ps1 lock/unlock/log/ask/qa (kit: ' + $Kit + '). Open big docs only for the one section you need; code questions go to graphify.')
            if (Test-Path -LiteralPath $s) { Write-Output (ReadText $s) } else { Write-Output 'STATUS.md is not built yet: run pilot.ps1 build.' }
        } catch { Write-Output ('[Pilot] ' + $_.Exception.Message) }
        break
    }
    'lock' {
        if (-not $Who -or -not $What) { throw 'lock needs -Who and -What' }
        $cfg = Load-Config (Get-ProjectRoot); $p = DocPath $cfg 'COORDINATION.md'
        $cur = (Get-TableRows $p 'Live lock') | Select-Object -First 1
        if ($cur -and $cur[0] -notmatch 'free' -and $cur[0] -ne $Who -and -not $Force) { throw ("The live lock is held by " + $cur[0] + ": " + $cur[1] + " (since " + $cur[2] + "). Ask them, or -Force if they are gone.") }
        Set-LockRow $p ('| ' + (Cell $Who) + ' | ' + (Cell $What) + ' | ' + (Now) + ' |'); Say "Live lock taken by $Who." Green; break
    }
    'unlock' {
        $cfg = Load-Config (Get-ProjectRoot); $p = DocPath $cfg 'COORDINATION.md'
        $cur = (Get-TableRows $p 'Live lock') | Select-Object -First 1
        $last = if ($cur) { $cur[1] } else { '' }
        Set-LockRow $p ('| — (free) | Last: ' + (Cell ($(if ($Who) { $Who + ': ' } else { '' }) + $last)) + ' | ' + (Now) + ' |'); Say 'Live lock released.' Green; break
    }
    'log' {
        if (-not $Who -or -not $Text) { throw 'log needs -Who and -Text' }
        $cfg = Load-Config (Get-ProjectRoot); Add-TableRow (DocPath $cfg 'COORDINATION.md') 'Log' ('| ' + (Get-Date).ToString('yyyy-MM-dd') + ' | ' + (Cell $Who) + ' | ' + (Cell $Text) + ' |'); Say 'Logged.' Green; break
    }
    'ask' {
        if (-not $Text) { throw 'ask needs -Text' }
        $cfg = Load-Config (Get-ProjectRoot); $p = DocPath $cfg 'REQUESTS.md'
        $n = 1 + (@((Get-TableRows $p 'Requests') | ForEach-Object { $x = 0; if ([int]::TryParse(($_[0] -replace '\D', ''), [ref]$x)) { $x } else { 0 } }) + 0 | Measure-Object -Maximum).Maximum
        $date = (Get-Date).ToString('d MMM')
        Add-TableRow $p 'Requests' ('| ' + $n + ' | (' + $date + ') ' + (Cell $Text) + ' | ' + $StatusMarks.todo + ' | |') -Append
        if ($Queue) { Add-TableRow $p 'Queue' ('| Q' + $n + ' | #' + $n + ' ' + (Cell $Text) + ' | | ' + $StatusMarks.todo + ' |') -Append }
        Say ("Request #$n added" + $(if ($Queue) { ' (end of the queue)' } else { '' }) + '.') Green; Write-Output $n; break
    }
    'qa' {
        if (-not $Q -or -not $A) { throw 'qa needs -Q and -A' }
        $cfg = Load-Config (Get-ProjectRoot); $p = DocPath $cfg 'QA.md'
        $n = 1 + (@((Get-TableRows $p 'Questions') | ForEach-Object { $x = 0; if ([int]::TryParse(($_[0] -replace '\D', ''), [ref]$x)) { $x } else { 0 } }) + 0 | Measure-Object -Maximum).Maximum
        Add-TableRow $p 'Questions' ('| ' + $n + ' | ' + (Get-Date).ToString('yyyy-MM-dd') + ' | ' + (Cell $Q) + ' | ' + (Cell $A) + ' | ' + (Cell $(if ($Who) { $Who } else { 'session' })) + ' |') -Append
        Say "Question #$n recorded." Green; break
    }
    'archive' {
        # Moves log rows older than -Days out of COORDINATION.md and PROGRESS.md: every session reads these files.
        $cfg = Load-Config (Get-ProjectRoot); $cut = (Get-Date).AddDays(-$Days)
        foreach ($file in 'COORDINATION.md', 'PROGRESS.md') {
            $p = DocPath $cfg $file; if (-not (Test-Path -LiteralPath $p)) { continue }
            $lines = [IO.File]::ReadAllLines($p, $utf8); $keep = New-Object Collections.Generic.List[string]; $moved = New-Object Collections.Generic.List[string]; $in = $false
            foreach ($l in $lines) {
                if ($l -match '^##\s+(.+)$') { $in = $Matches[1].StartsWith('Log') }
                $d = [datetime]::MinValue
                if ($in -and $l -match '^\|\s*(\d{4}-\d{2}-\d{2})' -and [datetime]::TryParse($Matches[1], [ref]$d) -and $d -lt $cut) { $moved.Add($l) } else { $keep.Add($l) }
            }
            if ($moved.Count) {
                $arch = DocPath $cfg ('archive\' + [IO.Path]::GetFileNameWithoutExtension($file) + '-log.md')
                if (-not (Test-Path -LiteralPath $arch)) { WriteText $arch ("# Archived log rows from $file`n`n| When | Who | Done |`n|---|---|---|`n") }
                [IO.File]::AppendAllLines($arch, $moved, $utf8); [IO.File]::WriteAllLines($p, $keep, $utf8)
                Say ("{0}: {1} old log rows moved to archive/" -f $file, $moved.Count) Green
            } else { Say "${file}: nothing older than $Days days." }
        }
        break
    }
    'uninstall' {
        $cfg = Load-Config (Get-ProjectRoot)
        foreach ($n in @($cfg.taskName, ($cfg.taskName + ' (helper)'))) { if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $n -Confirm:$false; Say "Removed task '$n'." } }
        Say ('Docs, CLAUDE.md and the data folder ' + (Split-Path -Parent $cfg._path) + ' stay.') ; break
    }
}
