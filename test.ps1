# Builds and runs the test suites.
#
#   tests/TabSignalTests.cs   the pure logic in TabSignal.cs. Compiled together with
#                             TabSignal.cs into one assembly so the tests can reach
#                             the internal helpers; /main: picks the test entry point,
#                             so the shipped TabSignal.exe is not affected.
#   tests/Install.Tests.ps1   a full install/reinstall/uninstall round trip against a
#                             temp directory, never your real configuration.
#   tests/Tab.Tests.ps1       the handshake that decides whether tab closes the tab it
#                             was run in, driven with a fake wt.exe so no window opens.
#
# Exits non-zero if any assertion fails.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw "csc.exe (.NET Framework 4.x) not found" }
$exe = Join-Path $here 'TabSignal.Tests.exe'
& $csc /nologo /target:exe /platform:anycpu /main:TabSignalTests "/out:$exe" "$here\TabSignal.cs" "$here\tests\TabSignalTests.cs"
if ($LASTEXITCODE -ne 0) { throw "Compilation failed ($LASTEXITCODE)" }

& $exe
$csharp = $LASTEXITCODE

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'tests\Install.Tests.ps1')
$install = $LASTEXITCODE

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'tests\Tab.Tests.ps1')
$tab = $LASTEXITCODE

exit ([int](($csharp -ne 0) -or ($install -ne 0) -or ($tab -ne 0)))
