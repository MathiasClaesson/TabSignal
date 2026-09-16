# TabSignal

Visar Claude Code-sessionens status direkt i Windows Terminal-fliken, och startar
sessioner med projektmapp, namn och flikfärg. Fristående, ingen server.

## Vad du ser i fliken

Statusen är Windows Terminals progressring i flikens ikonplats:

| Läge                                                        | Fliken            |
|-------------------------------------------------------------|-------------------|
| Claude arbetar (även under långa kommandon)                 | ringen snurrar    |
| Claude behöver dig: klar, vill ha tillstånd, ställer fråga  | stilla ring       |
| Ny eller avslutad session                                   | ingen ring        |

Ringens form och färg är Windows Terminals egna (systemets accentfärg) och går
inte att ändra. Ikonplatsen kan bara visa profilikonen eller den här ringen, så
ringen är det enda i ikonplatsen som kan följa sessionen. Claude Codes inbyggda
progressring är avstängd i `~/.claude.json` (`terminalProgressBarEnabled: false`)
så att den inte stör.

Fliktiteln är bara sessionsnamnet. `tab` öppnar sessionen i en flik med fast titel
(`wt --title --suppressApplicationTitle`), så Claude Codes egen glyf (◐/◑ när den
jobbar, ✳ när den är klar) syns inte. Priset är att `/rename` inte slår igenom i
fliken. `tab -Here` startar i stället i den flik du står i. Claude Codes titelglyf är
dessutom avstängd överallt med `"env": { "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1" }`
i `~/.claude/settings.json`, så även `tab -Here` och vanliga `claude` visar bara namnet.

Ingen klocka (BEL) skickas som standard. `.\install.ps1 -Bell` lägger till en
klocka när Claude behöver dig (klocksymbol i fliken, blink enligt `bellStyle`).

Flikens *färg* är en egen RGB-färg per flik, se nedan. Terminalens färgschema och
Claude Codes tema påverkas inte.

## Hur det fungerar

Claude Code kör hooks som underprocesser utan egen synlig konsol. `TabSignal.exe`
går uppåt i processträdet till skalet som äger fliken, kopplar sig på dess konsol
(`AttachConsole`) och skriver sekvenserna direkt till `CONOUT$`:

- `ESC ] 9 ; 4 ; state ; progress BEL` (OSC 9;4, progressringen: 3 = snurrar, 1;100 = stilla, 0 = dold)
- `ESC ] 4 ; 17 ; rgb:rr/gg/bb BEL` + `ESC [ 2 ; 15 ; 17 , |` (flikfärg: OSC 4 definierar om
  index 17 i just den flikens färgtabell, DECAC pekar fliken på det. Index 17 används
  varken av färgschemat (0–15) eller av Claude Code, som ritar i truecolor)
- `ESC ] 2 ; titel BEL` (OSC 2, fliktitel, bara manuellt via `title`)

Hooks: UserPromptSubmit ger snurr; Stop, PermissionRequest, AskUserQuestion och
Notification (tillstånd, fråga, idle) ger stilla ring; SessionStart och
SessionEnd döljer ringen. Fungerar oavsett skal i fliken (PowerShell, cmd,
Git Bash testade), eftersom hooken alltid går upp till processen direkt under
WindowsTerminal.exe.

## Installation

```powershell
cd C:\TabSignal
.\install.ps1            # bygger exe + registrerar hooks i ~/.claude/settings.json
.\install.ps1 -Bell      # samma, men med klocka (BEL)
.\install.ps1 -Uninstall # tar bort hooks igen
```

`install.ps1` gör allt som behövs på en ny dator (kör det igen efter varje ändring,
det är idempotent):

- bygger `TabSignal.exe` och registrerar hooks i `~/.claude/settings.json`
- sätter `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` där (ingen ✳/◐ i fliken)
- stänger av Claude Codes egen progressring i `~/.claude.json`
- lägger till `tab` och prompt-funktionen i PowerShell-profilen
- lägger mappen på användarens PATH
- sätter Windows Terminal-inställningarna nedan (hoppas över med en varning om
  filen innehåller kommentarer, sätt dem då för hand)

`-Uninstall` tar bort hooks, titelinställningen och `tab`, och slår på
progressringen igen. PATH och Windows Terminal-inställningarna lämnas kvar.
Backup (`.bak-datum`) tas av varje fil som ändras.

Kräver bara Windows (kompilatorn `csc.exe` följer med .NET Framework) och
Windows Terminal 1.6 eller senare. Kör installationen när ingen Claude-session är
igång, eftersom Claude Code själv skriver till `~/.claude.json`.

### Flytta till en annan dator

Lägg mappen på samma plats (`C:\TabSignal`) och kör:

```powershell
powershell -ExecutionPolicy Bypass -File C:\TabSignal\install.ps1
```

Öppna sedan en ny flik. `projects.txt` följer inte med (den är per dator) och
skapas vid första `tab`.

## Starta en session: `tab`

```powershell
tab                          # projektlista -> sessionsnamn -> färg
tab "Namn"                   # hoppar över namnfrågan
tab "Namn" -Color teal       # vald färg
tab "Namn" -Color none       # ingen flikfärg
tab -Dir C:\proj             # hoppar över projektlistan
tab -Here                    # starta i fliken du står i
tab -Args "--resume"         # extra argument till claude
```

Flödet: välj projekt med en siffra (0 = aktuell mapp), ange sessionsnamn (Enter
ger mappnamnet), välj färg (Enter ger automatisk färg härledd ur namnet, samma
namn ger alltid samma färg, `none` ger ingen färg). Sessionen öppnas sedan i en
ny flik med fast titel, och fliken du körde `tab` i stängs. Sessionen körs som
`claude --name "Namn"`, så namnet syns även i `--resume`-listan.

`tab` är en PowerShell-funktion i din profil (`install.ps1` lägger dit den) som
dot-sourcar `tab.ps1`; det är därför fliken kan stängas. Från cmd fungerar
`tab.cmd` också, men då stängs inte den gamla fliken.

Projektlistan är `C:\TabSignal\projects.txt`, en mapp per rad, valfritt
`| Visningsnamn` efter sökvägen, `#` för kommentar. Saknas filen skapas den från
mappar direkt under `C:\` som innehåller `.git`, `.claude` eller `CLAUDE.md`.

Färger: `green/grön` #1f5c3a, `teal` #175a5f, `blue/blå` #1f4a80,
`purple/lila` #4a3582, `red/röd` #7a2530, `orange` #8a3e14, `brown/brun` #5e4520,
`magenta/rosa` #7a2a5c, `gray/grå` #3a4250, en egen färg `#rrggbb`, eller ett
xterm-256-index 0–255. Paletten är lugn och mörk (minst 7,5:1 kontrast mot vit fliktext). Den aktiva
fliken visar färgen fullt ut och ser därför ljusare ut än de inaktiva, men ringen syns ändå.
Ändra färgerna i `Palette` i `TabSignal.cs` och kör `.uild.ps1`.

Textfärgen på fliken väljer Windows Terminal själv: svart om flikfärgen lagd över
flikraden är ljus, annars vit. Med Windows i ljust läge är flikraden ljus, och då
får inaktiva flikar svart text medan aktiva och hovrade får vit. Därför sätter
`install.ps1` ett eget mörkt tema (`"theme": "TabSignal"`, mörk flikrad `#1c1c1c`
med och utan fokus). Med paletten ovan blir texten då vit i alla lägen. Temat
gäller bara ramen, inte terminalens färgschema eller Claude.

`TabSignal.exe recolor` skickar färgen igen till alla öppna Claude-flikar (senast
satta färg, annars färgen ur sessionsnamnet), till exempel efter byte av palett. Använd inte `wt --tabColor`:
en flik som startats så kan inte färgas om med escape-sekvenser.

### Duplicera flik

Högerklick på fliken, "Duplicera flik" (eller Ctrl+Shift+D) öppnar en ny flik i
**samma mapp**: TabSignal talar om sessionens mapp för Windows Terminal med
sekvensen OSC 9;9 vid varje hook-händelse, `tab` gör det vid start, och
prompt-funktionen i PowerShell-profilen gör det i vanliga skal. Färg och fast
titel följer däremot inte med, Windows Terminal kopierar bara profil och mapp.
Kör `tab` i den nya fliken: Enter på projektfrågan tar den aktuella mappen, Enter
på namnet ger mappnamnet, och samma namn ger samma färg.

Byt färg mitt i en session (från Claude-prompten med `!` framför):

```powershell
TabSignal.exe color lila
TabSignal.exe color "#3a7ca5"
TabSignal.exe color none
```

## Windows Terminal-inställningar som satts

Temat `TabSignal` (se ovan) och i `profiles.defaults`: `"bellStyle": ["window", "taskbar"]` (ingen ljudklocka),
`"startingDirectory": "C:\\"` (nya flikar börjar i projektroten) och
`"icon": "C:\\TabSignal\\blank.png"` (genomskinlig profilikon, även satt på
profilen Windows PowerShell som annars har en egen ikon). Ikonen syns bara när
ringen är dold, dvs i nya flikar utan session. Ta bort de två `icon`-raderna om
du vill ha PowerShell-ikonen tillbaka. `"icon": "none"` fungerar inte, det ger
Windows Terminals reservikon. Ikonen är fast per profil och kan inte växla per
flik. Ändringar slår igenom några sekunder efter att filen sparats.

## Manuell test

```powershell
TabSignal.exe set 3            # ringen snurrar
TabSignal.exe set 1 100        # stilla ring
TabSignal.exe clear            # ingen ring
TabSignal.exe color orange
TabSignal.exe title "Test"     # fliktitel (ignoreras i flikar med fast titel)
```

Felsökning: sätt `TABSIGNAL_LOG=C:\TabSignal\tabsignal.log` (eller `--log FIL`)
så loggas processkedja och skickade sekvenser.
