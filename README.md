# TaskElevation

Run an application with elevated privileges through Windows Task Scheduler,
without repeated UAC prompts after initial registration.

C# / NativeAOT · .NET 10 · Windows x64 · 3.0.0

## Features

- Register, query, run and remove tasks for the current interactive user.
- Preserve command-line arguments, including empty strings, quotes and Unicode.
- Generate stable task names from the executable path and user SID.
- Support apphost and NativeAOT executables through a small native DLL.
- Remove empty task folders when unregistering.

## Requirements

- Windows x64 and a .NET 10 application.
- An executable installed under Program Files or Program Files (x86).
- Administrator privileges for registration and removal, under the same Windows
  account that will run the application. The account must be able to obtain an
  administrator token; registering under a different administrator account is
  not a way to elevate a standard user's application.

Use the application's `.exe`, either an apphost or a NativeAOT executable.
Launching through `dotnet MyApp.dll` is unsupported.

## Build and Reference

The repository includes an **unsigned, prebuilt Release DLL** at
`src/SevenKeyboard.TaskElevation/native/win-x64/TaskElevation.Native.dll`.
It is tracked by Git alongside its C++ source. Normal C# builds use this DLL and
require only the .NET 10 SDK:

```powershell
dotnet build src/SevenKeyboard.TaskElevation -c Release
```

Reference the project from your application, adjusting the relative path:

```xml
<ItemGroup>
  <ProjectReference Include="../task-elevation/src/SevenKeyboard.TaskElevation/SevenKeyboard.TaskElevation.csproj" />
</ItemGroup>
```

Build and publish copy `TaskElevation.Native.dll` to the application's output
directory. Deploy it beside the EXE. NativeAOT publishing still requires the
native build tools required by .NET; the prebuilt DLL only removes the need to
compile this library's C++ source during ordinary builds.

## Basic Usage

Register the installed application once from an elevated process (see below),
then request elevation during normal startup:

```csharp
using System;
using SevenKeyboard;

internal static class Program
{
    private static void Main(string[] args)
    {
        TaskElevation.MainFolderName = "MyCompany.Tasks";
        TaskElevation.TaskWorkingDir = AppContext.BaseDirectory;
        args = TaskElevation.RestoreArguments(args);

        if (TaskElevation.RelaunchAsAdmin("MyApp", args))
            return;

        // Continue application startup using the restored args.
    }
}
```

Call `RestoreArguments` before parsing application or profile arguments. It
returns ordinary arguments unchanged and decodes arguments passed by the
scheduled task. The transport marker is not proof of elevation or trusted input.

`RelaunchAsAdmin` returns `true` when Task Scheduler accepts the request. It does
not wait for the child to initialize or exit the current process for you.
It returns `false` when already elevated, outside Program Files, or when no
compatible task exists. Decide how your application should continue in those cases.

## Task Management

Use the same configuration and subfolder name for all operations:

```csharp
bool registered = TaskElevation.Register("MyApp");       // Requires administrator.
bool available = TaskElevation.IsRegistered("MyApp");
bool removed = TaskElevation.Unregister("MyApp");        // Requires administrator.
```

`Register` creates or updates the task belonging to this executable and user.
A conflicting definition belonging to another target is not overwritten.
`IsRegistered` checks the target, user, argument protocol and required settings.
`Unregister` deletes the matching task and tries to remove its empty folders.

Missing or incompatible tasks normally return `false`; invalid arguments and
native failures throw exceptions. Registration and removal also return `false`
without administrator privileges. Task Scheduler entries are persistent:
remove them during uninstall. Users who manually change task conditions are
responsible for those conditions.

## Configuration and Task Paths

Set configuration once at startup, before calling the scheduler:

| Property | Default | Purpose |
| --- | --- | --- |
| `MainFolderName` | `"SevenKeyboard.Tasks"` | Root folder in Task Scheduler. |
| `TaskCommand` | `Environment.ProcessPath` | Executable to register and run. |
| `TaskWorkingDir` | `Environment.CurrentDirectory` | Child process working directory. |

Paths must be fully qualified and must not contain `%`, because Task Scheduler
expands environment variables. Literal `$` characters in the working directory
are handled by the library. Keep the installation protected from ordinary-user
writes; the Program Files path check does not inspect directory permissions.

Generated task paths have this structure:

```text
\SevenKeyboard.Tasks\<SubFolder>\<FileName>@<PathHash>;user=<UserHash>
```

Each identifier is the first 128 bits of SHA-256, shown as 32 uppercase hex
digits. The path identifier uses the exact executable path; the user identifier
uses the current user SID. Invalid name characters and reserved device names
are escaped. Task paths are limited to 238 characters.

`GetFileTaskPath(subFolderName, filePath, fileName)` returns a generated path.
The scheduler methods also accept an optional `taskPath` for separate entries,
such as application profiles. It must remain in the configured main/subfolder
and retain the current user's suffix. Use the same path for registration,
query, relaunch and removal.

Tasks use `HighestAvailable` and `InteractiveToken`, with parallel instances
allowed. Registration and use must refer to the same interactively logged-on
user; this library does not manage single-instance handoff.

## Rebuilding the Native DLL

To build from C++ source instead of using the included DLL, install Visual
Studio 2026 C++ tools (MSVC v145, ATL and Windows SDK), then run:

```powershell
dotnet build src/SevenKeyboard.TaskElevation -c Release -p:TaskElevationBuildNative=true
```

This builds incrementally into `native/bin/Release` and uses that output for
this build. It does not replace the DLL tracked by Git.

After changing C++ source, refresh the included binary explicitly from the
repository root:

```powershell
$native = 'src/SevenKeyboard.TaskElevation/native'
& "$native/build.cmd" Release Rebuild
if ($LASTEXITCODE -ne 0) { throw 'Native build failed.' }
Copy-Item "$native/bin/Release/TaskElevation.Native.dll" "$native/win-x64/TaskElevation.Native.dll"
```

Commit the matching C++ source and prebuilt DLL together. Builds do not sign
binaries automatically. Keep the repository's included DLL unsigned; sign the
EXE and DLL in your application's release output if required by your deployment.

[Tests](tests/TaskElevation.Tests/README.md) · [MIT License](LICENSE)
