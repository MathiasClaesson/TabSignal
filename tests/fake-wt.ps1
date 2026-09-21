# Stands in for wt.exe in tests/Tab.Tests.ps1. It never opens a tab; it only
# decides whether to report back the way a real new tab would, and from which
# Windows Terminal window.
#
#   TABSIGNAL_FAKE_WT_SIGNAL=1   write the -Ready file (a tab that came up)
#   anything else                do nothing (a tab that never started)
#   TABSIGNAL_FAKE_WT_WINDOW     the window id to report (default 1234)
#   TABSIGNAL_FAKE_WT_LOG        a file to record that wt was called at all
#
# The -Ready path is picked out of the argument list, which is the same list
# tab.ps1 would have handed to wt.exe.
$ErrorActionPreference = 'Continue'
if ($env:TABSIGNAL_FAKE_WT_LOG) { Add-Content -LiteralPath $env:TABSIGNAL_FAKE_WT_LOG -Value ($args -join ' ') }
if ($env:TABSIGNAL_FAKE_WT_SIGNAL -ne '1') { exit 0 }
$window = if ($env:TABSIGNAL_FAKE_WT_WINDOW) { $env:TABSIGNAL_FAKE_WT_WINDOW } else { '1234' }
for ($i = 0; $i -lt $args.Count - 1; $i++) {
    if ($args[$i] -eq '-Ready') {
        $path = $args[$i + 1].Trim('"')
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
        [System.IO.File]::WriteAllText($path, $window, (New-Object System.Text.UTF8Encoding($false)))
        exit 0
    }
}
exit 0
