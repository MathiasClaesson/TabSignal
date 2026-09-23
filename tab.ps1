# tab - start a Claude Code or GitHub Copilot session with a project directory, a session
# name and a tab color.
#
#   tab                              project list -> name -> tool -> color
#                                    (numbered lists; the color menu shows swatches)
#   tab "Name"                       skips the name prompt (color derived from the name);
#                                    at the prompt, Enter gives the display name from
#                                    projects.txt, or else the directory name
#   tab "Name" -Color cyan           a chosen color  (see TabSignal.exe colors)
#   tab "Name" -Color none           no tab color
#   tab -Dir C:\proj                 skips the project list
#   tab -NewTab                      open the session in a new tab instead
#   tab -KeepTab                     with -NewTab: leave the tab you ran tab in open
#   tab -Tool copilot                skips the tool prompt (claude or copilot)
#   tab -Update                      run `<tool> update` before starting, whenever it last ran
#   tab -NoUpdate                    skip the daily update check
#   tab -Args "--resume"             extra arguments for the tool (split on whitespace)
#
# The tool is updated (`claude update` / `copilot update`) at most once a day, just
# before it starts; the time of the last run is kept per tool in
# %LOCALAPPDATA%\TabSignal.
#
# Default: the session takes over the tab you are standing in - directory, title
# and color are set there and the tool starts. Nothing is opened and nothing is
# closed, so no window can be taken down by mistake. The title is the name followed
# by the git branch, kept up to date by the hooks (Claude Code's own title is turned
# off by install.ps1). The color is set with an escape sequence rather than
# wt --tabColor, so that it can be changed later with:
#   TabSignal.exe color purple
#
# -NewTab opens the session in a new tab instead and closes the tab tab was run in
# once the new one has reported back from the same Windows Terminal window - if tab
# runs as the PowerShell function installed by install.ps1, and unless -KeepTab was
# given. It is left open anywhere else, so that closing it cannot take a window with it.
#
# The project list is projects.txt next to this script (override with the
# TABSIGNAL_PROJECTS environment variable): one directory per line, optionally
# followed by "| Display name". If the file is missing it is created by scanning
# the roots in TABSIGNAL_PROJECT_ROOTS (';'-separated; default: the system drive
# root and your home directory) two levels deep for .git, .claude or CLAUDE.md.
param(
    [Parameter(Position = 0)] [string]$Name,
    [string]$Color,
    [string]$Dir,
    [string]$Args = '',
    [ValidateSet('', 'claude', 'copilot')] [string]$Tool = '',
    [string]$Command = '',
    [switch]$Update,
    [switch]$NoUpdate,
    # -Here is what the default does now; it is still accepted so that habits and
    # older shortcuts keep working.
    [switch]$Here,
    [switch]$NewTab,
    [switch]$KeepTab,
    [switch]$InTab,
    # Set by the launcher on the copy that runs inside the new tab: the file to
    # write its Windows Terminal window id into once it is alive, so the launcher
    # knows the new tab exists and whether it landed in the same window.
    [string]$Ready = '',
    # Test seams (see tests/Tab.Tests.ps1); the defaults are the real behavior.
    [string]$WtCommand = 'wt.exe',
    [int]$ReadyTimeoutSeconds = 15,
    [string]$WindowId = '',
    [string]$UpdateStampDir = (Join-Path $env:LOCALAPPDATA 'TabSignal')
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'TabSignal.exe'
$projectsFile = if ($env:TABSIGNAL_PROJECTS) { $env:TABSIGNAL_PROJECTS } else { Join-Path $root 'projects.txt' }
if (-not (Test-Path -LiteralPath $exe)) { & (Join-Path $root 'build.ps1') }

# Quotes one argument for a Windows command line. Trailing backslashes are doubled,
# or they escape the closing quote ("C:\" becomes C:\" and swallows the rest).
function Quote-Arg([string]$s) {
    if ($null -eq $s) { $s = '' }
    $t = $s -replace '"', '\"'
    $t = $t -replace '(\\*)$', '$1$1'
    return '"' + $t + '"'
}

# Runs the tool with the session name as a real argument (claude only; copilot has no --name). Building a command string
# and calling Invoke-Expression would re-parse the name: $ would expand, and a ;
# or $() in it would execute. -Args is split on whitespace, so an extra argument
# containing spaces is not supported.
function Start-Tool([string]$toolName, [string]$exeName, [string]$sessionName, [string]$extra) {
    $a = @()
    if ($toolName -eq 'claude') { $a += @('--name', $sessionName) }
    if ($extra) { $a += @($extra -split '\s+' | Where-Object { $_ }) }
    & $exeName @a
}

function Update-Tool([string]$toolName, [string]$exeName) {
    if ($NoUpdate) { return }
    $stamp = Join-Path $UpdateStampDir "update-$toolName.stamp"
    if (-not $Update -and (Test-Path -LiteralPath $stamp) -and (Get-Item -LiteralPath $stamp).LastWriteTime -gt (Get-Date).AddDays(-1)) { return }
    Write-Host "Updating $toolName (once a day, -NoUpdate skips it) ..." -ForegroundColor DarkGray
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $exeName update
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { Write-Warning "$toolName update failed ($code); trying again tomorrow." }
    New-Item -ItemType Directory -Force $UpdateStampDir | Out-Null
    [System.IO.File]::WriteAllText($stamp, (Get-Date -Format o))
}

function Select-Tool {
    while ($true) {
        $ans = (Read-Host 'Tool  1 claude  2 copilot [Enter = 1]').Trim()
        if (-not $ans -or $ans -match '^(1|claude)$') { return 'claude' }
        if ($ans -match '^(2|copilot)$') { return 'copilot' }
    }
}

function Get-TabTitle([string]$sessionName, [string]$directory) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $branch = "$(& $exe branch $directory 2>$null)".Trim()
    $ErrorActionPreference = $prev
    if ($branch) { return $sessionName + ' ' + [char]0x00B7 + ' ' + $branch }
    return $sessionName
}

# Identifies the Windows Terminal window this shell lives in, as the process id of
# the WindowsTerminal.exe that hosts it (one process per window). '0' means "not a
# Windows Terminal tab" - a plain console window, where closing the shell takes the
# whole window down. The process chain is powershell -> OpenConsole -> WindowsTerminal,
# so a handful of steps is enough; WT_SESSION keeps the walk out of the common case
# where we are not in Windows Terminal at all.
function Get-TerminalWindow {
    if ($WindowId) { return $WindowId }
    if (-not $env:WT_SESSION) { return '0' }
    $p = $PID
    for ($i = 0; $i -lt 8 -and $p -gt 0; $i++) {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
        if (-not $proc) { break }
        if ($proc.Name -eq 'WindowsTerminal.exe') { return [string]$proc.ProcessId }
        $p = [int]$proc.ParentProcessId
    }
    return '0'
}

function Get-Projects {
    if (-not (Test-Path -LiteralPath $projectsFile)) {
        $isProject = { param($d) (Test-Path -LiteralPath (Join-Path $d '.git')) -or (Test-Path -LiteralPath (Join-Path $d '.claude')) -or (Test-Path -LiteralPath (Join-Path $d 'CLAUDE.md')) }
        $roots = if ($env:TABSIGNAL_PROJECT_ROOTS) { $env:TABSIGNAL_PROJECT_ROOTS -split ';' | Where-Object { $_ } }
                 else { @(($env:SystemDrive + '\'), $env:USERPROFILE) }
        # Anchored at both ends: an unanchored prefix match would also skip real
        # project directories such as C:\templates or C:\various.
        $skip = '^([$].*|\..*|Windows|Program Files.*|ProgramData|Users|PerfLogs|Recovery|ESD|inetpub|temp|tmp|var|AppData|OneDrive.*)$'
        $found = @()
        foreach ($rootDir in ($roots | Where-Object { Test-Path -LiteralPath $_ })) {
            foreach ($d in (Get-ChildItem -LiteralPath $rootDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $skip })) {
                if (& $isProject $d.FullName) { $found += $d.FullName; continue }
                # one level further down, so that e.g. C:\code\myrepo is found too
                foreach ($sub in (Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                    if (& $isProject $sub.FullName) { $found += $sub.FullName }
                }
            }
        }
        [System.IO.File]::WriteAllLines($projectsFile, [string[]]($found | Select-Object -Unique), (New-Object System.Text.UTF8Encoding($false)))
    }
    Get-Content -LiteralPath $projectsFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
        $parts = $_ -split '\|', 2
        [pscustomobject]@{ Path = $parts[0].Trim(); Label = $(if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { Split-Path -Leaf $parts[0].Trim() }) }
    }
}

# A small truecolor swatch, for the menus.
function Swatch([string]$hex) {
    $e = [char]27
    $r = [Convert]::ToInt32($hex.Substring(0,2),16)
    $g = [Convert]::ToInt32($hex.Substring(2,2),16)
    $b = [Convert]::ToInt32($hex.Substring(4,2),16)
    return ($e + '[48;2;' + $r + ';' + $g + ';' + $b + 'm      ' + $e + '[0m')
}

function Select-Color([string]$Name) {
    # The palette comes from TabSignal.exe (colors), so it is defined in one place only.
    # An older exe without the colors subcommand prints its usage to stderr, and under
    # ErrorActionPreference=Stop that would be a terminating error rather than a fall
    # back to the plain prompt below, so the call runs with Continue.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $exe colors --for $Name 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) { $out = @() }
    $rows = @($out | ForEach-Object {
        $f = $_ -split ('[|]'), 3
        if ($f.Count -eq 3) { [pscustomobject]@{ N = $f[0]; Name = $f[1]; Hex = $f[2] } }
    })
    if ($rows.Count -eq 0) { $a = (Read-Host 'Tab color [Enter = automatic]').Trim(); if ($a) { return $a } else { return 'auto' } }
    $auto = $rows | Where-Object { $_.N -eq '0' } | Select-Object -First 1
    $list = @($rows | Where-Object { $_.N -ne '0' })
    Write-Host ''
    if ($auto) {
        $same = $list | Where-Object { $_.Hex -eq $auto.Hex } | Select-Object -First 1
        $note = $(if ($same) { '(' + $same.Name + ', from the name)' } else { '(from the name)' })
        Write-Host ('   0. {0,-12}' -f 'automatic') -NoNewline
        Write-Host (Swatch $auto.Hex) -NoNewline
        Write-Host ('  ' + $note) -ForegroundColor DarkGray
    }
    foreach ($c in $list) {
        Write-Host ('  {0,2}. {1,-12}' -f $c.N, $c.Name) -NoNewline
        Write-Host (Swatch $c.Hex)
    }
    Write-Host ('   n. no tab color') -ForegroundColor DarkGray
    Write-Host ''
    while ($true) {
        $ans = (Read-Host 'Tab color (number, name or #rrggbb, Enter = 0)').Trim()
        if (-not $ans) { return 'auto' }
        if ($ans -eq '0') { return 'auto' }
        if ($ans -match '^(n|none)$') { return 'none' }
        $hit = $list | Where-Object { $_.N -eq $ans } | Select-Object -First 1
        if ($hit) { return $hit.Name }
        if ($ans -match '^#?[0-9a-fA-F]{6}$') { return $ans }
        $hit = $list | Where-Object { $_.Name -eq $ans.ToLower() } | Select-Object -First 1
        if ($hit) { return $hit.Name }
    }
}

function Select-Project {
    $list = @(Get-Projects)
    if ($list.Count -eq 0) { return (Get-Location).Path }
    $cur = (Get-Location).Path
    $curLabel = '(current directory)'
    $w = [Math]::Max($curLabel.Length, (@($list | ForEach-Object { $_.Label.Length }) | Measure-Object -Maximum).Maximum) + 2
    Write-Host ''
    Write-Host ('  {0,2}. {1}' -f 0, $curLabel.PadRight($w)) -NoNewline
    Write-Host $cur -ForegroundColor DarkGray
    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host ('  {0,2}. {1}' -f ($i + 1), $list[$i].Label.PadRight($w)) -NoNewline
        Write-Host $list[$i].Path -ForegroundColor DarkGray
    }
    Write-Host ''
    while ($true) {
        $ans = (Read-Host 'Project (number, Enter = 0)').Trim()
        if (-not $ans) { return (Get-Location).Path }
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 0 -and $n -le $list.Count) {
            if ($n -eq 0) { return (Get-Location).Path }
            return $list[$n - 1].Path
        }
        if (Test-Path -LiteralPath $ans) { return (Resolve-Path -LiteralPath $ans).Path }
    }
}

if ($InTab) {
    if (-not $Tool) { $Tool = 'claude' }
    if (-not $Command) { $Command = $Tool }
    # --- Runs inside the new tab: color + tool ---
    # Report in first of all: the launcher waits for this before closing its own tab.
    # Written to a temp file and moved into place, so the launcher never reads a
    # marker that exists but is still empty and concludes "another window".
    if ($Ready) {
        try {
            $tmp = $Ready + '.tmp'
            [System.IO.File]::WriteAllText($tmp, (Get-TerminalWindow), (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination $Ready -Force
        } catch { }
    }
    Set-Location -LiteralPath $Dir
    & $exe cwd $Dir   # so that Duplicate tab opens in the same directory
    if (-not $Color -or $Color -eq 'auto') { & $exe color --for $Name } else { & $exe color $Color }
    Update-Tool $Tool $Command
    Start-Tool $Tool $Command $Name $Args
    return
}

# --- The prompts, in the tab where tab was run ---
if (-not $Dir) { $Dir = Select-Project }
$Dir = (Resolve-Path -LiteralPath $Dir).Path
# The last non-empty path segment. Split-Path -Leaf gives '' for a root such as
# C:\ or \\server\, and an empty default would make the prompt below unanswerable.
$segments = @($Dir -split '[:\\/]' | Where-Object { $_ })
$default = if ($segments.Count) { $segments[-1] } else { 'claude' }
if (Test-Path -LiteralPath $projectsFile) {
    $listed = @(Get-Projects) | Where-Object { $_.Path.TrimEnd('\') -eq $Dir.TrimEnd('\') } | Select-Object -First 1
    if ($listed) { $default = $listed.Label }
}
while (-not $Name) {
    $Name = (Read-Host "Session name [Enter = $default]").Trim()
    if (-not $Name) { $Name = $default }
}
if (-not $Tool) { $Tool = if ($Command) { 'claude' } else { Select-Tool } }
if (-not $Command) { $Command = $Tool }
if (-not $Color) { $Color = Select-Color $Name }
$title = Get-TabTitle $Name $Dir

if (-not $NewTab) {
    # This tab: set the directory, the title and the color, then hand it to the tool.
    # The title is the name (Claude Code's own title is disabled in settings.json).
    Set-Location -LiteralPath $Dir
    & $exe cwd $Dir
    if ($Color -eq 'auto') { & $exe color --for $Name } else { & $exe color $Color }
    $host.UI.RawUI.WindowTitle = $title
    Update-Tool $Tool $Command
    Start-Tool $Tool $Command $Name $Args
    return
}

# -NewTab: a new tab in the most recently used Windows Terminal window.
$readyDir = Join-Path ([System.IO.Path]::GetTempPath()) 'TabSignal\ready'
New-Item -ItemType Directory -Force $readyDir | Out-Null
Get-ChildItem -LiteralPath $readyDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
    Remove-Item -Force -ErrorAction SilentlyContinue          # markers from a launcher that died
$readyFile = Join-Path $readyDir ([Guid]::NewGuid().ToString('N'))

$inner = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Quote-Arg $MyInvocation.MyCommand.Path),
           '-InTab', '-Name', (Quote-Arg $Name), '-Color', (Quote-Arg $Color), '-Dir', (Quote-Arg $Dir),
           '-Tool', $Tool, '-Command', (Quote-Arg $Command))
if ($Update) { $inner += '-Update' }
if ($NoUpdate) { $inner += '-NoUpdate' }
# Only ask the new tab to report back when we intend to act on it.
if (-not $KeepTab) { $inner += @('-Ready', (Quote-Arg $readyFile)) }
if ($Args) { $inner += @('-Args', (Quote-Arg $Args)) }
$wt = @('-w', '0', 'new-tab', '-d', (Quote-Arg $Dir), '--title', (Quote-Arg $title))
if ($Tool -ne 'claude') { $wt += '--suppressApplicationTitle' }
$wt = $wt + @('powershell.exe') + $inner
# wt.exe treats ; as a command separator even inside quotes, so a session name or
# path containing one would split the command line and the tab would never start.
$wt = @($wt | ForEach-Object { $_ -replace ';', '\;' })
Start-Process -FilePath $WtCommand -ArgumentList $wt

# Close the tab tab was run in - but only once the new one has reported back.
# Closing on a timer used to be a race: on a cold wt.exe start the old tab could go
# first, and if it was the only tab in the window, the window went with it.
if ($KeepTab) { return }
$myWindow = Get-TerminalWindow
$deadline =(Get-Date).AddSeconds($ReadyTimeoutSeconds)
$appeared = $false
while ((Get-Date) -lt $deadline) {
    if (Test-Path -LiteralPath $readyFile) { $appeared = $true; break }
    Start-Sleep -Milliseconds 50
}
$newWindow = if ($appeared) { (Get-Content -LiteralPath $readyFile -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
Remove-Item -LiteralPath $readyFile -Force -ErrorAction SilentlyContinue
if (-not $appeared) {
    Write-Warning "The new tab did not report back within $ReadyTimeoutSeconds s, so this tab was left open."
    return
}
# Closing is only safe when this really is a Windows Terminal tab and the session
# landed in the same window: then that window still has the new tab in it. Anywhere
# else - a plain console window, or wt.exe picking a different window than the one
# we are in - closing would take a whole window down with it.
if ($myWindow -eq '0') {
    Write-Host ("Not a Windows Terminal tab (the new tab reported $newWindow), so this window was left open.") -ForegroundColor DarkGray
    return
}
if ($newWindow -ne $myWindow) {
    Write-Host ("The session opened in another window (this one $myWindow, the new tab $newWindow), so this tab was left open.") -ForegroundColor DarkGray
    return
}
# exit only closes the tab when tab is dot-sourced as a function in an interactive
# shell, which is how install.ps1 wires it up. From tab.cmd it is a no-op.
if ($MyInvocation.InvocationName -eq '.') { exit }
