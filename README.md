# TaskElevation

TaskElevation is a small AutoHotkey utility library for running scripts
with elevated privileges using Windows Scheduled Tasks instead of repeated UAC prompts.

Both AutoHotkey v1 and v2 are supported, with separate implementations
following the same behavior and API design.

---

## Features

* Run scripts as administrator without repeated UAC prompts
* Uses Windows Scheduled Tasks (no temporary helper executables)
* Safe task path generation (invalid characters and reserved names handled)
* Prevents duplicate task registration
* Supports compiled and non-compiled scripts
* Optional restriction to scripts located under Program Files
* Optional WM_COMMNOTIFY handoff (useful for `#SingleInstance Force`-style behavior)
* Automatic cleanup of tasks and empty folders
* **Binds scheduled tasks to the current interactive user to avoid Credential Manager (`CredWrite`) failures in scheduled-task elevation scenarios**

---

## Supported Versions

* AutoHotkey v1.1+
* AutoHotkey v2.0+

Each version has its own source file.
The public API and behavior are intentionally kept consistent.

---

## Requirements

* Windows
* Administrator privileges for task registration and removal

---

## Basic Usage

Relaunch the current script as administrator:

```ahk
TaskElevation.relaunchAsAdmin("MyApp")
```

If a scheduled task already exists, the current instance exits and the
script is relaunched with elevated privileges via the Task Scheduler.

---

## Task Management

Check whether a task exists:

```ahk
TaskElevation.isRegistered("MyApp")
```

Register a task (requires admin rights):

```ahk
TaskElevation.register("MyApp")
```

Unregister a task:

```ahk
TaskElevation.unregister("MyApp")
```

Remove all registered tasks and folders:

```ahk
TaskElevation.unregisterAll()
```

---

## Task Path Format

Tasks are created using the following structure:

```
\AutoHotkey.Tasks\<SubFolder>\<ScriptName>@<CRC>;user=<UserCRC>
```

* `<CRC>` is derived from the command line (or file path) to ensure uniqueness.
* `<UserCRC>` is derived from the current process user SID to ensure tasks are
  isolated per user and launched in the correct interactive user context.

This avoids ambiguous execution contexts when elevating via Task Scheduler,
which can break APIs that rely on an interactive logon session (e.g. Windows
Credential Manager calls like `CredWrite`).

---

## Customization

Change the root folder used in the Task Scheduler:

```ahk
TaskElevation.MainFolderName := "MyCompany.Tasks"
```

---

## Design Notes

### Why the defaults are conservative

Task Scheduler entries are persistent. If elevation can be triggered from
arbitrary locations, the “elevation surface” becomes wider and easier to
misuse. For that reason, the default behavior assumes a **distribution-style
installation** (e.g. under Program Files) and tries to keep elevation
behavior narrow, predictable, and repeatable.

### What the options affect

* `requireProgramFiles` (default: `true`)

  * Affects: `relaunchAsAdmin()`, `register()`
  * When enabled, these methods refuse to proceed unless `A_ScriptFullPath`
    is under Program Files (x86/x64).

* `allowCommNotifyMsgFlt` (default: `true`)

  * Affects: `relaunchAsAdmin()` (admin-side only)
  * When enabled, the elevated instance relaxes the message filter to allow
    WM_COMMNOTIFY from a non-elevated instance. This is useful for patterns
    like `#SingleInstance Force` / instance handoff.

* These two are **mutually exclusive by design** in this library.

### When to change defaults (and how)

Recommended default (distribution install + narrow surface):

```ahk
TaskElevation.relaunchAsAdmin("MyApp")  ; default behavior
```

If you use your own single-instance mechanism (mutex/lockfile/pipe/etc.),
disable WM_COMMNOTIFY filtering:

```ahk
TaskElevation.relaunchAsAdmin("MyApp", , false)  ; allowCommNotifyMsgFlt=false (recommended in this case)
```

Disabling the Program Files restriction is generally discouraged, but can be
done for controlled environments:

```ahk
TaskElevation.relaunchAsAdmin("MyApp", , , false)  ; requireProgramFiles=false (not recommended)
; and for registration:
; TaskElevation.register("MyApp", , false)    ; requireProgramFiles=false (not recommended)
```

---

## Notes

* Tasks run with the "HighestAvailable" run level.
* Tasks are registered for the **current interactive user** (UserId/SID + InteractiveToken).
* Command-line arguments are preserved when relaunching.
* Designed for long-term installation and reuse rather than one-shot elevation.

---

## Compatibility

### 2.0.0 breaking change

Version 2.0.0 changes the task name format (adds `;user=<UserCRC>`).
**Previously registered tasks must be re-registered** after upgrading.

---

## Credits

This library is inspired by and builds upon ideas from community work,
notably SKAN's **RunAsTask** example on the AutoHotkey forums:

* [https://www.autohotkey.com/boards/viewtopic.php?t=119710](https://www.autohotkey.com/boards/viewtopic.php?t=119710)

Thanks to SKAN and the AutoHotkey community for sharing knowledge and prior art.