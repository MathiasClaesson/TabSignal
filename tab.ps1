# tab - starta en Claude Code-session med projektmapp, sessionsnamn och flikfarg.
#
#   tab                              projektlista -> namn -> farg
#   tab "Namn"                       hoppar over namnfragan (farg harledd ur namnet)
#   tab "Namn" -Color teal           vald farg    (se TabSignal.exe color)
#   tab "Namn" -Color none           ingen flikfarg
#   tab -Dir C:\proj                 hoppar over projektlistan
#   tab -Here                        starta i den har fliken
#   tab -Args "--resume"             extra argument till claude
#
# Standard: sessionen oppnas i en NY flik med fast titel (bara namnet, ingen
# ◐/✳-glyf fran Claude Code), och fliken du star i stangs om tab kors som
# PowerShell-funktion (se install.ps1). Fast titel betyder att /rename inte
# syns i fliken. Fargen satts med escape-sekvens, inte wt --tabColor, sa att
# den kan andras senare med:  TabSignal.exe color lila
#
# Projektlistan ligger i C:\TabSignal\projects.txt, en mapp per rad (valfritt
# "| Visningsnamn" efter sokvagen). Saknas filen skapas den fran mappar direkt
# under C:\ som innehaller .git, .claude eller CLAUDE.md.
param(
    [Parameter(Position = 0)] [string]$Name,
    [string]$Color,
    [string]$Dir,
    [string]$Args = '',
    [string]$Command = 'claude',
    [switch]$Here,
    [switch]$InTab
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $root 'TabSignal.exe'
$projectsFile = Join-Path $root 'projects.txt'
if (-not (Test-Path $exe)) { & (Join-Path $root 'build.ps1') }

function Get-Projects {
    if (-not (Test-Path $projectsFile)) {
        $found = Get-ChildItem 'C:\' -Directory -ErrorAction SilentlyContinue | Where-Object {
            (Test-Path (Join-Path $_.FullName '.git')) -or (Test-Path (Join-Path $_.FullName '.claude')) -or (Test-Path (Join-Path $_.FullName 'CLAUDE.md'))
        } | ForEach-Object { $_.FullName }
        [System.IO.File]::WriteAllLines($projectsFile, [string[]]$found, (New-Object System.Text.UTF8Encoding($false)))
    }
    Get-Content -LiteralPath $projectsFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
        $parts = $_ -split '\|', 2
        [pscustomobject]@{ Path = $parts[0].Trim(); Label = $(if ($parts.Count -gt 1 -and $parts[1].Trim()) { $parts[1].Trim() } else { Split-Path -Leaf $parts[0].Trim() }) }
    }
}

function Select-Project {
    $list = @(Get-Projects)
    if ($list.Count -eq 0) { return (Get-Location).Path }
    Write-Host ''
    Write-Host '  0. (aktuell mapp)  ' -NoNewline; Write-Host (Get-Location).Path -ForegroundColor DarkGray
    for ($i = 0; $i -lt $list.Count; $i++) {
        Write-Host ('  {0,2}. {1,-34}' -f ($i + 1), $list[$i].Label) -NoNewline; Write-Host $list[$i].Path -ForegroundColor DarkGray
    }
    Write-Host ''
    while ($true) {
        $ans = (Read-Host 'Projekt (nummer, Enter = 0)').Trim()
        if (-not $ans) { return (Get-Location).Path }
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 0 -and $n -le $list.Count) {
            if ($n -eq 0) { return (Get-Location).Path }
            return $list[$n - 1].Path
        }
        if (Test-Path $ans) { return (Resolve-Path $ans).Path }
    }
}

if ($InTab) {
    # --- Kors inne i den nya fliken: farg + claude ---
    Set-Location $Dir
    & $exe cwd $Dir   # sa att Duplicera flik oppnar i samma mapp
    if (-not $Color -or $Color -eq 'auto') { & $exe color --for $Name } else { & $exe color $Color }
    $cmd = $Command + ' --name "' + $Name.Replace('"', '\"') + '"'
    if ($Args) { $cmd += ' ' + $Args }
    Invoke-Expression $cmd
    return
}

# --- Fragorna, i fliken dar tab kors ---
if (-not $Dir) { $Dir = Select-Project }
$Dir = (Resolve-Path $Dir).Path
$default = Split-Path -Leaf $Dir
while (-not $Name) {
    $Name = (Read-Host "Sessionsnamn [Enter = $default]").Trim()
    if (-not $Name) { $Name = $default }
}
if (-not $Color) {
    $Color = (Read-Host 'Flikfarg  [Enter = automatisk | none | gron teal bla lila rod orange brun rosa gra | #rrggbb]').Trim()
}
if (-not $Color) { $Color = 'auto' }

if ($Here) {
    # Samma flik: titeln ar namnet (Claude Codes titel ar avstangd i settings.json).
    Set-Location $Dir
    & $exe cwd $Dir
    if ($Color -eq 'auto') { & $exe color --for $Name } else { & $exe color $Color }
    $host.UI.RawUI.WindowTitle = $Name
    $cmd = $Command + ' --name "' + $Name.Replace('"', '\"') + '"'
    if ($Args) { $cmd += ' ' + $Args }
    Invoke-Expression $cmd
    return
}

# Ny flik med fast titel, i det senast anvanda WT-fonstret.
$inner = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $MyInvocation.MyCommand.Path + '"'),
           '-InTab', '-Name', ('"' + $Name + '"'), '-Color', $Color, '-Dir', ('"' + $Dir + '"'), '-Command', ('"' + $Command + '"'))
if ($Args) { $inner += @('-Args', ('"' + $Args + '"')) }
$wt = @('-w', '0', 'new-tab', '-d', ('"' + $Dir + '"'), '--title', ('"' + $Name + '"'), '--suppressApplicationTitle', 'powershell.exe') + $inner
Start-Process -FilePath 'wt.exe' -ArgumentList $wt

# Stang fliken tab kordes i, om tab ar dot-sourcad som funktion i skalet.
if ($MyInvocation.InvocationName -eq '.') { Start-Sleep -Milliseconds 800; exit }
