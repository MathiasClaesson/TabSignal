# Tests the handshake that decides whether tab closes the tab it was run in.
# A fake wt.exe stands in for the real one and decides whether the new tab reports
# back, so no window is ever opened.
#
# NOT covered: the final `exit` that actually closes the tab. It only takes the
# shell down when tab.ps1 is dot-sourced in an interactive host; under
# powershell -Command, -File or piped stdin, exit from a dot-sourced script does
# not stop the caller, so no automated harness can observe it. What is covered is
# the decision that precedes it - whether the script gets that far at all.
#
# Run via .\test.ps1, or on its own. Exits non-zero if an assertion fails.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$tab = Join-Path $root 'tab.ps1'
$fakeWt = Join-Path $here 'fake-wt.cmd'
$timeout = 3

$script:passed = 0
$script:failed = 0

function Ok([bool]$cond, [string]$what) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL  $what" }
}

# Runs tab.ps1 against the fake wt and reports its output and how long it took.
#   Signal = does the fake wt report back
#   Extra  = extra arguments for tab.ps1 (e.g. -KeepTab); -NewTab is added for you
function Invoke-Tab([bool]$Signal, [string[]]$Extra = @(), [string]$Window = '1234', [string]$NewWindow = '1234') {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('TabSignalTab-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $dir | Out-Null
    $env:TABSIGNAL_FAKE_WT_SIGNAL = if ($Signal) { '1' } else { '0' }
    $env:TABSIGNAL_FAKE_WT_WINDOW = $NewWindow
    $env:TABSIGNAL_FAKE_WT_LOG = ''
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $tab,
           '-Name', 'session', '-Color', 'none', '-Dir', $dir,
           '-WtCommand', $fakeWt, '-ReadyTimeoutSeconds', $timeout,
           '-WindowId', $Window, '-NewTab') + $Extra
    $start = Get-Date
    $out = & powershell.exe @a 2>&1 | Out-String
    $elapsed = ((Get-Date) - $start).TotalSeconds
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Output = $out; Elapsed = $elapsed }
}

# ------------------------------------------------- the new tab reports back

$r = Invoke-Tab $true
Ok ($r.Output -notmatch 'did not report back') 'No warning when the new tab reports back'
Ok ($r.Output -notmatch 'left open') 'The tab is closed when the new one is in the same window'
Ok ($r.Elapsed -lt $timeout) 'The launcher stops waiting as soon as the new tab reports back'

# ------------------------------------------------- the new tab is in another window
# The regression this guards: wt.exe does not always put the tab in the window we
# are in, and then closing this tab takes our own window down with it.

$r = Invoke-Tab $true -NewWindow '9999'
Ok ($r.Output -match 'another window') 'A tab in another window leaves this one open'

# ------------------------------------------------- not a Windows Terminal tab
# A plain console window: there is no tab to close, only the window itself.

$r = Invoke-Tab $true -Window '0'
Ok ($r.Output -match 'Not a Windows Terminal tab') 'A plain console window is left open'

# ------------------------------------------------- the new tab never comes up
# The regression this guards: the old code slept 800 ms and closed regardless, so a
# slow wt.exe start could take the window down with the last tab in it.

$r = Invoke-Tab $false
Ok ($r.Output -match 'did not report back') 'A warning explains why the tab was left open'
Ok ($r.Elapsed -ge $timeout) 'The launcher waits the full timeout before giving up'
Ok ($r.Elapsed -lt ($timeout + 25)) 'The launcher does not wait forever'

# ------------------------------------------------- -KeepTab

# Nothing is going to be closed, so there is nothing to wait for: -KeepTab must not
# stall for the timeout even when the new tab never reports back.
$r = Invoke-Tab $false @('-KeepTab')
Ok ($r.Output -notmatch 'did not report back') '-KeepTab does not warn about a tab it was never going to close'
Ok ($r.Elapsed -lt $timeout) '-KeepTab skips the handshake instead of waiting for it'

# ------------------------------------------------- the default: this tab, no wt
# The whole handshake exists only for -NewTab. By default nothing is opened and
# nothing is closed, so there is no window to lose in the first place.

$dir = Join-Path ([System.IO.Path]::GetTempPath()) ('TabSignalTab-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $dir | Out-Null
$wtLog = Join-Path $dir 'wt.log'
$env:TABSIGNAL_FAKE_WT_SIGNAL = '1'
$env:TABSIGNAL_FAKE_WT_LOG = $wtLog
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tab `
    -Name 'session' -Color 'none' -Dir $dir -Command (Join-Path $here 'fake-claude.cmd') `
    -WtCommand $fakeWt 2>&1 | Out-String
$env:TABSIGNAL_FAKE_WT_LOG = ''
Ok (-not (Test-Path -LiteralPath $wtLog)) 'The default opens no new tab'
Ok ($out -match 'fake-claude --name session') 'The default starts claude with the session name in this tab'
Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue

# ------------------------------------------------- no marker files left behind

$readyDir = Join-Path ([System.IO.Path]::GetTempPath()) 'TabSignal\ready'
$left = @(Get-ChildItem -LiteralPath $readyDir -File -ErrorAction SilentlyContinue)
Ok ($left.Count -eq 0) 'The handshake leaves no marker files behind'

Write-Host ''
if ($script:failed -eq 0) { Write-Host "All $script:passed tab assertions passed." }
else { Write-Host "$script:failed of $($script:passed + $script:failed) tab assertions FAILED." }
exit ([int]($script:failed -gt 0))
