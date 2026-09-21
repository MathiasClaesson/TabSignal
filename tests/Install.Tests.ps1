# Drives install.ps1 against a scratch directory instead of your real configuration,
# using its -SettingsPath / -ClaudeJsonPath / -ProfilePath parameters together with
# -SkipBuild, -SkipPath and -SkipTerminalSettings. Nothing outside the temp folder
# is touched: no PATH change, no Windows Terminal settings, no real profile.
#
# Run via .\test.ps1, or on its own. Exits non-zero if an assertion fails.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$install = Join-Path (Split-Path -Parent $here) 'install.ps1'

$script:passed = 0
$script:failed = 0

function Ok([bool]$cond, [string]$what) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL  $what" }
}

function Eq($actual, $expected, [string]$what) {
    if ($actual -eq $expected) { $script:passed++ }
    else {
        $script:failed++
        Write-Host "FAIL  $what"
        Write-Host "        expected: $expected"
        Write-Host "        actual:   $actual"
    }
}

# A fresh scratch install. Returns the paths it uses.
function New-Sandbox {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('TabSignalTest-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $dir | Out-Null
    [pscustomobject]@{
        Dir      = $dir
        Settings = Join-Path $dir 'settings.json'
        ClaudeJs = Join-Path $dir 'claude.json'
        Profile  = Join-Path $dir 'profile.ps1'
    }
}

function Invoke-Install($box, [switch]$Uninstall) {
    $p = @{
        SettingsPath         = $box.Settings
        ClaudeJsonPath       = $box.ClaudeJs
        ProfilePath          = $box.Profile
        SkipBuild            = $true
        SkipPath             = $true
        SkipTerminalSettings = $true
    }
    if ($Uninstall) { $p.Uninstall = $true }
    & $install @p *>$null
}

function Get-Settings($box) { [System.IO.File]::ReadAllText($box.Settings) | ConvertFrom-Json }

function Count-TabSignalHooks($settings) {
    $n = 0
    foreach ($ev in $settings.hooks.PSObject.Properties.Name) {
        foreach ($entry in @($settings.hooks.$ev)) {
            foreach ($h in @($entry.hooks)) { if ($h -and $h.command -like '*TabSignal.exe*') { $n++ } }
        }
    }
    return $n
}

# ---------------------------------------------------------------- fresh install

$box = New-Sandbox
Invoke-Install $box
$s = Get-Settings $box
Ok (Test-Path -LiteralPath $box.Settings) 'A fresh install creates settings.json'
Ok ((Count-TabSignalHooks $s) -gt 0) 'A fresh install registers TabSignal hooks'
Eq $s.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE '1' 'A fresh install disables the Claude Code terminal title'
Ok ([System.IO.File]::ReadAllText($box.Profile) -match 'function tab \{') 'A fresh install adds the tab function to the profile'
Ok ([System.IO.File]::ReadAllText($box.Profile) -match 'function prompt \{') 'A fresh install adds the prompt function to an empty profile'
$firstCount = Count-TabSignalHooks $s

# ---------------------------------------------------------------- idempotency

Invoke-Install $box
Invoke-Install $box
$s = Get-Settings $box
Eq (Count-TabSignalHooks $s) $firstCount 'Re-running the installer does not duplicate the hooks'
$profileText = [System.IO.File]::ReadAllText($box.Profile)
Eq ([regex]::Matches($profileText, 'function tab \{').Count) 1 'Re-running the installer does not duplicate the tab function'
Eq (@(Get-ChildItem -LiteralPath $box.Dir -Filter 'settings.json.bak-*').Count) 0 'An unchanged file is not rewritten, so no backups pile up'

# ---------------------------------------------------------------- hooks of your own survive
# The regression this guards: the cleanup used to drop the whole entry when any
# command inside it mentioned TabSignal.exe, taking a co-located hook with it.

$box = New-Sandbox
$mine = @{
    hooks = @{
        Stop = @(
            @{ hooks = @(
                @{ type = 'command'; command = 'my-own-tool.exe --notify' },
                @{ type = 'command'; command = '"C:\Old\TabSignal.exe" hook' }
            ) }
        )
        PreToolUse = @(
            @{ matcher = 'Bash'; hooks = @(@{ type = 'command'; command = 'audit.exe' }) }
        )
    }
}
[System.IO.File]::WriteAllText($box.Settings, ($mine | ConvertTo-Json -Depth 32))
Invoke-Install $box
$s = Get-Settings $box
$commands = @()
foreach ($ev in $s.hooks.PSObject.Properties.Name) {
    foreach ($entry in @($s.hooks.$ev)) { foreach ($h in @($entry.hooks)) { if ($h) { $commands += $h.command } } }
}
Ok ($commands -contains 'my-own-tool.exe --notify') 'A hook of your own next to a TabSignal hook survives the install'
Ok ($commands -contains 'audit.exe') 'A hook of your own in another event survives the install'
Ok (-not ($commands | Where-Object { $_ -like '*C:\Old\TabSignal.exe*' })) 'The stale TabSignal hook from an old install path is removed'

Invoke-Install $box -Uninstall
$s = Get-Settings $box
$commands = @()
foreach ($ev in $s.hooks.PSObject.Properties.Name) {
    foreach ($entry in @($s.hooks.$ev)) { foreach ($h in @($entry.hooks)) { if ($h) { $commands += $h.command } } }
}
Ok ($commands -contains 'my-own-tool.exe --notify') 'Uninstalling leaves a co-located hook of your own in place'
Eq (Count-TabSignalHooks $s) 0 'Uninstalling removes every TabSignal hook'

# ---------------------------------------------------------------- .claude.json shapes
# The regression this guards: inserting into a {}-shaped file produced a trailing
# comma, ConvertFrom-Json threw, and the installer died half-installed.

foreach ($shape in @('{}', "{`n}", '{ "existing": 1 }', "{`n  `"a`": { `"b`": 2 }`n}")) {
    $box = New-Sandbox
    [System.IO.File]::WriteAllText($box.ClaudeJs, $shape)
    Invoke-Install $box
    $text = [System.IO.File]::ReadAllText($box.ClaudeJs)
    $parsed = $null
    try { $parsed = $text | ConvertFrom-Json } catch { }
    Ok ($null -ne $parsed) "An install against a $shape-shaped .claude.json leaves valid JSON"
    if ($parsed) { Eq $parsed.terminalProgressBarEnabled $false "terminalProgressBarEnabled is set to false in $shape" }
}

# An existing value is flipped rather than duplicated, and uninstall flips it back.
$box = New-Sandbox
[System.IO.File]::WriteAllText($box.ClaudeJs, '{ "terminalProgressBarEnabled": true, "other": 1 }')
Invoke-Install $box
$parsed = [System.IO.File]::ReadAllText($box.ClaudeJs) | ConvertFrom-Json
Eq $parsed.terminalProgressBarEnabled $false 'An existing terminalProgressBarEnabled is set to false'
Eq $parsed.other 1 'The rest of .claude.json is left alone'
Invoke-Install $box -Uninstall
$parsed = [System.IO.File]::ReadAllText($box.ClaudeJs) | ConvertFrom-Json
Eq $parsed.terminalProgressBarEnabled $true 'Uninstalling turns the Claude Code progress ring back on'

# A fresh install with no .claude.json at all creates a valid one.
$box = New-Sandbox
Invoke-Install $box
$parsed = [System.IO.File]::ReadAllText($box.ClaudeJs) | ConvertFrom-Json
Eq $parsed.terminalProgressBarEnabled $false 'A missing .claude.json is created with the ring disabled'

# ---------------------------------------------------------------- the profile

# It is backed up before being rewritten (the README promises a backup of every
# file the installer edits).
$box = New-Sandbox
[System.IO.File]::WriteAllText($box.Profile, "Set-Alias ll Get-ChildItem`r`n")
Invoke-Install $box
Ok ((@(Get-ChildItem -LiteralPath $box.Dir -Filter 'profile.ps1.bak-*')).Count -ge 1) 'The profile is backed up before it is rewritten'
Ok ([System.IO.File]::ReadAllText($box.Profile) -match 'Set-Alias ll') 'The rest of the profile is left alone'

# A prompt of the user's own is not clobbered.
$box = New-Sandbox
[System.IO.File]::WriteAllText($box.Profile, "function prompt { 'mine> ' }`r`n")
Invoke-Install $box
$profileText = [System.IO.File]::ReadAllText($box.Profile)
Ok ($profileText -match "function prompt \{ 'mine> ' \}") 'An existing prompt function is kept'
Eq ([regex]::Matches($profileText, 'function prompt').Count) 1 'TabSignal does not add a second prompt function'
Ok ($profileText -match 'function tab \{') 'The tab function is still added alongside your prompt'

# The block written by the pre-release cs version is cleaned up.
$box = New-Sandbox
[System.IO.File]::WriteAllText($box.Profile, "# TabSignal cs`r`nfunction cs { . 'C:\Old\cs.ps1' @args }`r`n")
Invoke-Install $box
$profileText = [System.IO.File]::ReadAllText($box.Profile)
Ok ($profileText -notmatch 'function cs \{') 'The legacy cs function is removed on install'

# Uninstalling takes the whole block back out.
$box = New-Sandbox
[System.IO.File]::WriteAllText($box.Profile, "Set-Alias ll Get-ChildItem`r`n")
Invoke-Install $box
Invoke-Install $box -Uninstall
$profileText = [System.IO.File]::ReadAllText($box.Profile)
Ok ($profileText -notmatch 'function tab \{') 'Uninstalling removes the tab function'
Ok ($profileText -notmatch 'function prompt \{') 'Uninstalling removes the prompt function'
Ok ($profileText -match 'Set-Alias ll') 'Uninstalling leaves the rest of the profile alone'

# ---------------------------------------------------------------- cleanup

Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'TabSignalTest-*' -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:failed -eq 0) { Write-Host "All $script:passed install assertions passed." }
else { Write-Host "$script:failed of $($script:passed + $script:failed) install assertions FAILED." }
exit ([int]($script:failed -gt 0))
