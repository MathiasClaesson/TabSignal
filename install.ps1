# Builds TabSignal.exe and registers the hooks in ~/.claude/settings.json.
# Hooks you added yourself are left alone, and every file that actually changes is
# backed up to <file>.bak-<timestamp> first.
#
#   .\install.ps1                          install (no bell)
#   .\install.ps1 -Bell                    install with BEL (bell glyph in the tab,
#                                          flash/sound according to bellStyle)
#   .\install.ps1 -StartingDirectory C:\   also point new Windows Terminal tabs there
#   .\install.ps1 -SkipTerminalSettings    leave the Windows Terminal settings alone
#   .\install.ps1 -Uninstall               remove the TabSignal hooks again
#
# Idempotent: run it again after every change. Files that would come out byte for
# byte identical are not rewritten, so re-running does not pile up backups.
param(
    [switch]$Bell,
    [switch]$Uninstall,
    [string]$StartingDirectory,
    [switch]$SkipTerminalSettings,
    [switch]$SkipPath,
    [switch]$SkipBuild,
    # Overridable so that tests/Install.Tests.ps1 can drive a full install against a
    # scratch directory instead of your real configuration. Defaults are the real files.
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$ClaudeJsonPath = (Join-Path $env:USERPROFILE '.claude.json'),
    [string]$ProfilePath = $PROFILE.CurrentUserCurrentHost
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $here 'TabSignal.exe'

# Writes $content to $path, but only if that would change the file, and takes a
# timestamped backup of whatever was there first. Returns $true if it wrote.
function Save-File([string]$path, [string]$content, [bool]$bom = $false) {
    $old = if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllText($path) } else { $null }
    if ($old -eq $content) { return $false }
    if ($null -ne $old) { Copy-Item -LiteralPath $path -Destination ($path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($bom)))
    return $true
}

if (-not $Uninstall -and -not $SkipBuild) { & (Join-Path $here 'build.ps1') }

if (Test-Path -LiteralPath $SettingsPath) {
    $settings = [System.IO.File]::ReadAllText($SettingsPath) | ConvertFrom-Json
} else {
    $settings = [pscustomobject]@{}
}
if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
$hooks = $settings.hooks

# Always drop the old TabSignal entries first (this is what makes reinstalling
# idempotent). One entry can hold several commands, so filter the inner array
# rather than the entry: dropping the whole entry would take any hook of yours
# that happens to sit next to ours with it.
# Where-Object { $_ }: an object with no properties yields a single $null name here,
# not an empty list, and Remove($null) throws.
foreach ($ev in @($hooks.PSObject.Properties.Name | Where-Object { $_ })) {
    $kept = @()
    foreach ($entry in @($hooks.$ev)) {
        if ($null -eq $entry) { continue }
        $all = @($entry.hooks)
        $mine = @($all | Where-Object { $_ -and $_.command -like '*TabSignal.exe*' })
        if ($mine.Count -eq 0) { $kept += $entry; continue }          # nothing of ours in here
        $theirs = @($all | Where-Object { $_ -and $_.command -notlike '*TabSignal.exe*' })
        if ($theirs.Count -gt 0) { $entry.hooks = $theirs; $kept += $entry }
    }
    if ($kept.Count -gt 0) { $hooks.$ev = $kept } else { $hooks.PSObject.Properties.Remove($ev) }
}

if (-not $Uninstall) {
    $bellArg = if ($Bell) { ' --bell' } else { '' }
    function New-Entry([string]$matcher, [string]$extra) {
        $h = [pscustomobject]@{ type = 'command'; command = ('"' + $exe + '" hook' + $extra + $bellArg); timeout = 5; async = $true }
        if ($matcher) { [pscustomobject]@{ matcher = $matcher; hooks = @($h) } } else { [pscustomobject]@{ hooks = @($h) } }
    }
    $wanted = @{
        SessionStart      = @(New-Entry $null '')
        SessionEnd        = @(New-Entry $null '')
        UserPromptSubmit  = @(New-Entry $null '')
        Stop              = @(New-Entry $null '')
        PermissionRequest = @(New-Entry $null '')
        PreToolUse        = @(New-Entry 'AskUserQuestion' '')
        PostToolUse       = @(New-Entry 'AskUserQuestion' '')
        Notification      = @(
            (New-Entry 'permission_prompt'     ' --matcher permission_prompt'),
            (New-Entry 'idle_prompt'           ' --matcher idle_prompt'),
            (New-Entry 'elicitation_dialog'    ' --matcher elicitation_dialog'),
            (New-Entry 'elicitation_complete'  ' --matcher elicitation_complete')
        )
    }
    foreach ($ev in $wanted.Keys) {
        if ($hooks.PSObject.Properties.Name -contains $ev) { $hooks.$ev = @($hooks.$ev) + $wanted[$ev] }
        else { $hooks | Add-Member -NotePropertyName $ev -NotePropertyValue $wanted[$ev] }
    }
}

# Turn off Claude Code's title glyph: the tab title is then just the session name.
if (-not ($settings.PSObject.Properties.Name -contains 'env')) {
    $settings | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
}
$settings.env.PSObject.Properties.Remove('CLAUDE_CODE_DISABLE_TERMINAL_TITLE')
if (-not $Uninstall) { $settings.env | Add-Member -NotePropertyName CLAUDE_CODE_DISABLE_TERMINAL_TITLE -NotePropertyValue '1' }
if (@($settings.env.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('env') }

# PowerShell 5.1 writes non-ASCII as \uXXXX; that is valid JSON and is left as is.
$json = $settings | ConvertTo-Json -Depth 32
$null = $json | ConvertFrom-Json   # safety check: never write invalid JSON
$null = Save-File $SettingsPath $json

# The PowerShell function tab: dot-sources tab.ps1, so that the session takes over
# this very shell - and so that tab -NewTab can close the tab it was run in.
# Functions take precedence over tab.cmd on PATH.
$marker = '# TabSignal tab'
$tabFn = "$marker`r`nfunction tab { . '$here\tab.ps1' @args }`r`n"
$promptFn = "# Reports the directory to Windows Terminal (OSC 9;9) so that Duplicate tab opens in the same place.`r`n" +
            "function prompt { `$loc = `$executionContext.SessionState.Path.CurrentLocation; `$out = ''; if (`$loc.Provider.Name -eq 'FileSystem') { `$out += `"`$([char]27)]9;9;```"`$(`$loc.ProviderPath)```"`$([char]27)\`" }; `$out + `"PS `$loc`$('>' * (`$nestedPromptLevel + 1)) `" }`r`n"
$existing = if (Test-Path -LiteralPath $ProfilePath) { [System.IO.File]::ReadAllText($ProfilePath) } else { '' }
# Also removes the block written by the pre-release `cs` version, which pointed at a
# script that no longer exists.
$existing = [regex]::Replace($existing, '# TabSignal (cs|tab)\r?\nfunction (cs|tab) \{[^\n]*\}\r?\n?(#[^\n]*\r?\nfunction prompt \{[^\n]*\}\r?\n?)?', '')
if (-not $Uninstall) {
    $block = $tabFn
    # Do not clobber a prompt of the user's own (oh-my-posh, posh-git, a handwritten
    # one). Without ours, Duplicate tab still works inside a Claude session, since the
    # hook sends OSC 9;9 too - just not in a plain shell.
    if ($existing -match '(?m)^\s*function\s+prompt\b') {
        Write-Warning "Your profile already defines a prompt function, so TabSignal's was not added. Duplicate tab will open in the session's directory inside Claude, but not in a plain shell."
    } else {
        $block += $promptFn
    }
    $existing = $existing.TrimEnd() + "`r`n`r`n" + $block
}
$null = Save-File $ProfilePath $existing $true

# Turn off Claude Code's own progress ring (in ~/.claude.json) so it does not fight TabSignal's.
# Text replacement rather than reformatting: the file is large and is owned by Claude Code.
$want = if ($Uninstall) { 'true' } else { 'false' }
if (Test-Path -LiteralPath $ClaudeJsonPath) {
    $cj = [System.IO.File]::ReadAllText($ClaudeJsonPath)
    if ($cj -match '"terminalProgressBarEnabled"\s*:\s*(true|false)') {
        $cj2 = [regex]::Replace($cj, '("terminalProgressBarEnabled"\s*:\s*)(true|false)', '${1}' + $want)
    } elseif ($cj -match '\A\s*\{\s*\}\s*\z') {
        $cj2 = "{`n  `"terminalProgressBarEnabled`": $want`n}`n"   # an empty object has no member to put a comma before
    } else {
        # Replace(input, replacement, count) is the INSTANCE method; the fourth argument
        # of the static [regex]::Replace is RegexOptions, not a count.
        $cj2 = ([regex]'\A\s*\{').Replace($cj, "{`n  `"terminalProgressBarEnabled`": $want,", 1)
    }
    $valid = $true
    try { $null = $cj2 | ConvertFrom-Json } catch { $valid = $false }
    if ($valid) { $null = Save-File $ClaudeJsonPath $cj2 }
    else { Write-Warning "Left $ClaudeJsonPath alone: the edit would not have been valid JSON. Set `"terminalProgressBarEnabled`": $want by hand." }
} elseif (-not $Uninstall) {
    $null = Save-File $ClaudeJsonPath "{`n  `"terminalProgressBarEnabled`": false`n}`n"
}

if (-not $Uninstall) {
    # This folder on the user's PATH (for tab.cmd and for TabSignal.exe from the Claude prompt).
    if (-not $SkipPath) {
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($null -eq $userPath) { $userPath = '' }   # no user-scoped Path at all
        if (-not (($userPath -split ';') -contains $here)) {
            [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $here).TrimStart(';'), 'User')
        }
    }

    # Windows Terminal: no audible bell, transparent profile icon, dark tab row.
    if (-not $SkipTerminalSettings) {
        $wtFiles = @(
            (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
            (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
        ) | Where-Object { Test-Path -LiteralPath $_ }
        foreach ($wtFile in $wtFiles) {
            try { $wt = [System.IO.File]::ReadAllText($wtFile) | ConvertFrom-Json }
            catch { Write-Warning "Skipping $wtFile (comments or invalid JSON). Set bellStyle, icon and theme by hand, see README."; continue }
            $icon = Join-Path $here 'blank.png'
            $defaults = $wt.profiles.defaults
            if ($null -eq $defaults) { $defaults = [pscustomobject]@{}; $wt.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue $defaults }
            # Earlier versions wrote startingDirectory unconditionally, so clear it
            # whether or not -StartingDirectory was passed this time.
            $defaults.PSObject.Properties.Remove('startingDirectory')
            $wtDefaults = @(@('bellStyle', @('window', 'taskbar')), @('icon', $icon))
            if ($StartingDirectory) { $wtDefaults += ,@('startingDirectory', $StartingDirectory) }
            foreach ($kv in $wtDefaults) {
                $defaults.PSObject.Properties.Remove($kv[0])
                $defaults | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1]
            }
            # The Windows PowerShell profile has an icon of its own that wins over defaults.
            foreach ($p in @($wt.profiles.list | Where-Object { $_.guid -eq '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}' })) {
                $p.PSObject.Properties.Remove('icon'); $p | Add-Member -NotePropertyName icon -NotePropertyValue $icon
            }
            # A dark theme with a fixed tab row: Windows Terminal picks the tab text color from
            # the tab color composited over the tab row. With a light row (Windows in light mode)
            # the text is black on inactive tabs and white on active/hovered ones; with a dark
            # row it is white everywhere, which is what the palette is tuned for.
            $theme = [pscustomobject]@{
                name   = 'TabSignal'
                window = [pscustomobject]@{ applicationTheme = 'dark' }
                tabRow = [pscustomobject]@{ background = '#1c1c1c'; unfocusedBackground = '#1c1c1c' }
            }
            $themes = @($wt.themes | Where-Object { $_ -and $_.name -ne 'TabSignal' }) + $theme
            foreach ($kv in @(@('themes', $themes), @('theme', 'TabSignal'))) {
                $wt.PSObject.Properties.Remove($kv[0])
                $wt | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1]
            }
            $wtJson = $wt | ConvertTo-Json -Depth 32
            $null = $wtJson | ConvertFrom-Json
            $null = Save-File $wtFile $wtJson
        }
    }
}

if ($Uninstall) { Write-Host "TabSignal hooks removed from $SettingsPath, and the tab function from $ProfilePath" }
else { Write-Host "TabSignal installed. Hooks in $SettingsPath, tab function in $ProfilePath (applies to new tabs)." }
