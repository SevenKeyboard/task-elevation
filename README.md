# TaskScheduler

TaskScheduler is a small AutoHotkey utility library for running scripts
with elevated privileges using Windows Scheduled Tasks instead of UAC prompts.

Both AutoHotkey v1 and v2 are supported, with separate implementations
following the same behavior and API design.

---

## Features

- Run scripts as administrator without repeated UAC prompts
- Uses Windows Scheduled Tasks (no temporary helper executables)
- Safe task path generation (invalid characters and reserved names handled)
- Prevents duplicate task registration
- Supports compiled and non-compiled scripts
- Optional restriction to scripts located under Program Files
- Automatic cleanup of tasks and empty folders

---

## Supported Versions

- AutoHotkey v1.1+
- AutoHotkey v2.0+

Each version has its own source file.
The public API and behavior are intentionally kept consistent.

---

## Requirements

- Windows
- Administrator privileges for task registration and removal

---

## Basic Usage

Run the current script as administrator:

    TaskScheduler.runAsAdmin("Your App Name")

If a scheduled task already exists, the current instance exits and the
script is relaunched with elevated privileges via the Task Scheduler.

---

## Task Management

Check whether a task exists:

    TaskScheduler.isRegistered("Your App Name")

Register a task (requires admin rights):

    TaskScheduler.register("Your App Name")

Unregister a task:

    TaskScheduler.unregister("Your App Name")

Remove all registered tasks and folders:

    TaskScheduler.unregisterAll()

---

## Task Path Format

Tasks are created using the following structure:

    \AutoHotkey.Tasks\<SubFolder>\<ScriptName>@<CRC>

The CRC is derived from the command line to ensure uniqueness when the
same script is launched with different parameters.

---

## Customization

Change the root folder used in the Task Scheduler:

    TaskScheduler.MainFolderName := "MyCompany.Tasks"

---

## Notes

- Tasks run with the "HighestAvailable" run level.
- Command-line arguments are preserved when relaunching.
- By default, scripts must be located under Program Files
  (this restriction can be disabled via parameters).
- Designed for long-term installation and reuse rather than one-shot elevation.

---

## License

MIT License  
© 2026 SevenKeyboard Ltd.
