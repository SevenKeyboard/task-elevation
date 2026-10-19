# Tests

Console tests using the actual library through ProjectReference; no test-framework dependency.
Run from the repository root:

```powershell
dotnet publish tests/TaskElevation.Tests -c Release -p:PublishAot=false -o tests/TaskElevation.Tests/bin/jit
dotnet publish tests/TaskElevation.Tests -c Release -r win-x64 -p:PublishAot=true -o tests/TaskElevation.Tests/bin/aot
tests/TaskElevation.Tests/bin/jit/TaskElevation.Tests.exe --local
tests/TaskElevation.Tests/bin/aot/TaskElevation.Tests.exe --local
```

These commands test the included native DLL. To test C++ source changes, add
`-p:TaskElevationBuildNative=true` to both publish commands.

Local checks cover payload decoding, SHA-256 fixed vectors, task names and path/host guards.

For integration tests, sign the output first if required by local App Control.
Prepare an isolated installation path and record the current user:

```powershell
$root = (Resolve-Path tests/TaskElevation.Tests).Path
Join-Path ([Environment]::GetFolderPath('ProgramFiles')) ('SevenKeyboard.TaskElevation.Tests.' + [Guid]::NewGuid().ToString('N')) | Set-Content "$root/obj/install-path.txt"
[Security.Principal.WindowsIdentity]::GetCurrent().User.Value | Set-Content "$root/obj/owner-sid.txt"
```

1. Run `Stage-Tests.ps1 -Mode Install` as administrator under that same user.
2. As the ordinary user, run `<installation>/jit/TaskElevation.Tests.exe --test`, then the `aot` equivalent.
3. Run `Stage-Tests.ps1 -Mode Cleanup` as administrator.

The script only manages its uniquely named installation and scheduler folder.
Tests cover registration/update/deletion, conflicting definitions, elevated child identity,
working directory, argument round-trips, overlapping requests and STA/MTA calls.
The working directory contains literal `$(Arg0)`, `$$` and `$` to verify scheduler escaping.
Do not reuse a partially completed installation without checking its state.

Verified on Windows 11 build 26200, .NET SDK 10.0.401 and MSVC v145.
Other Windows versions/accounts/domains and child failure after request acceptance are not covered.
