# Compiles TabSignal.exe with the C# compiler that ships with .NET Framework
# (present on every Windows install, no SDK needed).
# Builds to a temp file and renames, so that it also works while a running
# process still holds the old exe.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw "csc.exe (.NET Framework 4.x) not found" }
$exe = Join-Path $here 'TabSignal.exe'
$tmp = Join-Path $here 'TabSignal.new.exe'
$old = Join-Path $here 'TabSignal.old.exe'
Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue   # left over from the previous build, if it was locked then
& $csc /nologo /target:exe /optimize+ /platform:anycpu "/out:$tmp" "$here\TabSignal.cs"
if ($LASTEXITCODE -ne 0) { throw "Compilation failed ($LASTEXITCODE)" }
if (Test-Path $exe) { Move-Item -LiteralPath $exe -Destination $old -Force }   # a running exe can be renamed, but not overwritten
Move-Item -LiteralPath $tmp -Destination $exe -Force
Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
Write-Host "Built $exe"
