# Bygger TabSignal.exe och registrerar hooks i ~/.claude/settings.json.
# Befintliga hooks rors inte; en backup av settings.json tas forst.
#   .\install.ps1            installera (ingen klocka)
#   .\install.ps1 -Bell      installera med BEL (klocksymbol i fliken, blink/ljud enligt bellStyle)
#   .\install.ps1 -Uninstall ta bort TabSignal-hooks
param([switch]$Bell, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $here 'TabSignal.exe'
$settingsPath = Join-Path $env:USERPROFILE '.claude\settings.json'

if (-not $Uninstall) { & (Join-Path $here 'build.ps1') }

if (Test-Path $settingsPath) {
    $raw = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
    $settings = $raw | ConvertFrom-Json
    Copy-Item -LiteralPath $settingsPath -Destination ($settingsPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
} else {
    $settings = [pscustomobject]@{}
}
if (-not ($settings.PSObject.Properties.Name -contains 'hooks')) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
$hooks = $settings.hooks

# Ta alltid bort gamla TabSignal-poster forst (gor om-installation idempotent).
foreach ($ev in @($hooks.PSObject.Properties.Name)) {
    $kept = @($hooks.$ev | Where-Object {
        -not (@($_.hooks) | Where-Object { $_.command -like '*TabSignal.exe*' })
    })
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

# Claude Codes titelglyf av: fliktiteln ar bara sessionsnamnet.
if (-not ($settings.PSObject.Properties.Name -contains 'env')) {
    $settings | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
}
$settings.env.PSObject.Properties.Remove('CLAUDE_CODE_DISABLE_TERMINAL_TITLE')
if (-not $Uninstall) { $settings.env | Add-Member -NotePropertyName CLAUDE_CODE_DISABLE_TERMINAL_TITLE -NotePropertyValue '1' }
if (@($settings.env.PSObject.Properties).Count -eq 0) { $settings.PSObject.Properties.Remove('env') }

# PowerShell 5.1 skriver icke-ASCII som \uXXXX; det ar giltig JSON och lamnas som det ar.
$json = $settings | ConvertTo-Json -Depth 32
$null = $json | ConvertFrom-Json   # sakerhetskontroll: skriv aldrig ogiltig JSON
[System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))

# PowerShell-funktionen tab: dot-sourcar tab.ps1 sa att fliken kan stangas nar
# sessionen oppnats i en ny flik. Funktioner gar fore tab.cmd pa PATH.
$profilePath = $PROFILE.CurrentUserCurrentHost
$marker = '# TabSignal tab'
$fn = "$marker`r`nfunction tab { . '$here\tab.ps1' @args }`r`n" +
      "# Talar om mappen for Windows Terminal (OSC 9;9) sa att Duplicera flik oppnar i samma mapp.`r`n" +
      "function prompt { `$loc = `$executionContext.SessionState.Path.CurrentLocation; `$out = ''; if (`$loc.Provider.Name -eq 'FileSystem') { `$out += `"`$([char]27)]9;9;```"`$(`$loc.ProviderPath)```"`$([char]27)\`" }; `$out + `"PS `$loc`$('>' * (`$nestedPromptLevel + 1)) `" }"
$existing = if (Test-Path $profilePath) { Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 } else { '' }
$existing = [regex]::Replace($existing, '# TabSignal (cs|tab)\r?\nfunction (cs|tab) \{[^\n]*\}\r?\n?', '')   # tar aven bort aldre cs-funktion
if (-not $Uninstall) { $existing = $existing.TrimEnd() + "`r`n`r`n" + $fn + "`r`n" }
New-Item -ItemType Directory -Force (Split-Path -Parent $profilePath) | Out-Null
[System.IO.File]::WriteAllText($profilePath, $existing, (New-Object System.Text.UTF8Encoding($true)))

# Claude Codes egen progressring av (i ~/.claude.json), sa att den inte stor TabSignals.
# Textersattning i stallet for omformatering: filen ar stor och skrivs av Claude Code.
$claudeJson = Join-Path $env:USERPROFILE '.claude.json'
if (Test-Path $claudeJson) {
    $want = if ($Uninstall) { 'true' } else { 'false' }
    $cj = [System.IO.File]::ReadAllText($claudeJson)
    if ($cj -match '"terminalProgressBarEnabled"\s*:\s*(true|false)') {
        $cj2 = [regex]::Replace($cj, '("terminalProgressBarEnabled"\s*:\s*)(true|false)', '${1}' + $want)
    } else {
        $cj2 = [regex]::Replace($cj, '^\s*\{', "{`n  `"terminalProgressBarEnabled`": $want,", 1)
    }
    if ($cj2 -ne $cj) {
        $null = $cj2 | ConvertFrom-Json
        Copy-Item -LiteralPath $claudeJson -Destination ($claudeJson + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        [System.IO.File]::WriteAllText($claudeJson, $cj2, (New-Object System.Text.UTF8Encoding($false)))
    }
} elseif (-not $Uninstall) {
    [System.IO.File]::WriteAllText($claudeJson, "{`n  `"terminalProgressBarEnabled`": false`n}`n", (New-Object System.Text.UTF8Encoding($false)))
}

if (-not $Uninstall) {
    # C:\TabSignal pa anvandarens PATH (for tab.cmd och TabSignal.exe fran Claude-prompten).
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (($userPath -split ';') -contains $here)) {
        [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $here).TrimStart(';'), 'User')
    }

    # Windows Terminal: ingen ljudklocka, nya flikar i C:\, genomskinlig profilikon.
    $wtFiles = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    ) | Where-Object { Test-Path $_ }
    foreach ($wtFile in $wtFiles) {
        try { $wt = Get-Content -LiteralPath $wtFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Warning "Hoppar over $wtFile (kommentarer eller ogiltig JSON). Satt bellStyle, startingDirectory och icon for hand, se README."; continue }
        $icon = Join-Path $here 'blank.png'
        $defaults = $wt.profiles.defaults
        if ($null -eq $defaults) { $defaults = [pscustomobject]@{}; $wt.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue $defaults }
        foreach ($kv in @(@('bellStyle', @('window', 'taskbar')), @('startingDirectory', 'C:\'), @('icon', $icon))) {
            $defaults.PSObject.Properties.Remove($kv[0])
            $defaults | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1]
        }
        # Windows PowerShell-profilen har en egen ikon som gar fore defaults.
        foreach ($p in @($wt.profiles.list | Where-Object { $_.guid -eq '{61c54bbd-c2c6-5271-96e7-009a87ff44bf}' })) {
            $p.PSObject.Properties.Remove('icon'); $p | Add-Member -NotePropertyName icon -NotePropertyValue $icon
        }
        # Morkt tema med fast flikrad: Windows Terminal valjer textfarg utifran flikfargen lagd
        # over flikraden. Med en ljus rad (Windows i ljust lage) blir texten svart pa inaktiva
        # flikar och vit pa aktiva/hover; med en mork rad blir den vit i alla lagen.
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
        Copy-Item -LiteralPath $wtFile -Destination ($wtFile + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $wtJson = $wt | ConvertTo-Json -Depth 32
        $null = $wtJson | ConvertFrom-Json
        [System.IO.File]::WriteAllText($wtFile, $wtJson, (New-Object System.Text.UTF8Encoding($false)))
    }
}

if ($Uninstall) { Write-Host "TabSignal-hooks borttagna fran $settingsPath och tab-funktionen fran $profilePath" }
else { Write-Host "TabSignal installerat. Hooks i $settingsPath, tab-funktion i $profilePath (galler nya flikar)." }
