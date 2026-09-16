# Kompilerar TabSignal.exe med C#-kompilatorn som foljer med .NET Framework (finns pa alla Windows).
# Bygger till en tempfil och byter namn, sa att det fungerar aven nar en blinkprocess kor den gamla exe:n.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw "Hittar inte csc.exe (.NET Framework 4.x)" }
$exe = Join-Path $here 'TabSignal.exe'
$tmp = Join-Path $here 'TabSignal.new.exe'
$old = Join-Path $here 'TabSignal.old.exe'
Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue   # fran forra bygget, om den var last da
& $csc /nologo /target:exe /optimize+ /platform:anycpu "/out:$tmp" "$here\TabSignal.cs"
if ($LASTEXITCODE -ne 0) { throw "Kompilering misslyckades ($LASTEXITCODE)" }
if (Test-Path $exe) { Move-Item -LiteralPath $exe -Destination $old -Force }   # en korande exe kan bytas namn pa, inte skrivas over
Move-Item -LiteralPath $tmp -Destination $exe -Force
Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
Write-Host "Byggde $exe"
