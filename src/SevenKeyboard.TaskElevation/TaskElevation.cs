using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;

namespace SevenKeyboard;

//==============================================================
// TaskElevation — Registers and runs elevated Scheduled Tasks.
// GitHub: https://github.com/SevenKeyboard/task-elevation
// Author: SevenKeyboard Ltd. (2026)
// License: MIT License
//
// Documentation / References:
//   ITaskFolder interface (taskschd.h)
//   https://learn.microsoft.com/windows/win32/api/taskschd/nn-taskschd-itaskfolder
//==============================================================
public static partial class TaskElevation
{
    private const string ScheduledArguments = "--byscheduler --task-elevation-v1 $(Arg0)";
    private static string _mainFolderName = "SevenKeyboard.Tasks";

    // Values match TaskElevationExecute in TaskScheduler.cpp.
    private enum TaskOperation
    {
        Register = 0,
        Query = 1,
        Run = 2,
        Delete = 3
    }

    //--------------------------------------------------
    public static string MainFolderName
    {
        get => _mainFolderName;
        set => _mainFolderName = SanitizeTaskComponent(value);
    }

    // Configure once during application startup, before making scheduler calls.
    public static string? TaskCommand { get; set; }
    public static string? TaskWorkingDir { get; set; }

    //--------------------------------------------------
    /// <summary>Restores scheduler arguments before application/profile parsing.</summary>
    /// <remarks>The marker and payload are transport data, not proof of elevation or trusted input.</remarks>
    public static string[] RestoreArguments(string[] args)
    {
        ArgumentNullException.ThrowIfNull(args);
        if (args.Length == 0 || args[0] != "--byscheduler")
            return args;
        if (args.Length != 3 || args[1] != "--task-elevation-v1")
            throw new FormatException("The scheduled task uses an unsupported argument format. Register it again as administrator.");
        return TaskArguments.Decode(args[2]);
    }

    /// <summary>Requests an elevated run; false means already elevated, outside Program Files, or no compatible task.</summary>
    /// <remarks>True means request acceptance, not child readiness. The caller decides whether to exit.</remarks>
    public static bool RelaunchAsAdmin(string subFolderName, string[] args, string? taskPath = null)
    {
        ArgumentNullException.ThrowIfNull(args);
        if (IsAdministrator())
            return false;
        string command = GetTaskCommand();
        if (!IsPathUnderProgramFiles(command))
            return false;
        string payload = TaskArguments.Encode(args);
        string arguments = ScheduledArguments.Replace("$(Arg0)", payload, StringComparison.Ordinal);
        string commandLine = $"\"{command}\" {arguments}";
        // The Windows limit includes the terminating NUL character.
        if (commandLine.Length + 1 > 32767)
            throw new ArgumentException("Encoded arguments exceed the Windows command-line limit.", nameof(args));
        return ExecuteTaskOperation(TaskOperation.Run, subFolderName, taskPath, command, payload);
    }

    //--------------------------------------------------
    /// <summary>Creates or updates this user's task; requires administrator and an executable under Program Files.</summary>
    public static bool Register(string subFolderName, string? taskPath = null)
    {
        if (!IsAdministrator())
            return false;
        string command = GetTaskCommand();
        if (!IsPathUnderProgramFiles(command))
            return false;
        if (!File.Exists(command))
            throw new FileNotFoundException("Task executable does not exist.", command);
        return ExecuteTaskOperation(TaskOperation.Register, subFolderName, taskPath, command);
    }

    /// <summary>Checks target, user, argument protocol and required task settings.</summary>
    public static bool IsRegistered(string subFolderName, string? taskPath = null)
        => ExecuteTaskOperation(TaskOperation.Query, subFolderName, taskPath, GetTaskCommand());

    /// <summary>Deletes this user's task, then tries to remove its empty folders. False means absent or not administrator.</summary>
    public static bool Unregister(string subFolderName, string? taskPath = null)
    {
        if (!IsAdministrator())
            return false;
        return ExecuteTaskOperation(TaskOperation.Delete, subFolderName, taskPath, GetTaskCommand());
    }

    //--------------------------------------------------
    /// <summary>Builds a task path from escaped names and separate SHA-256 identifiers for the exact file path and current user SID.</summary>
    /// <remarks>Each identifier uses 16 hash bytes as uppercase hex. The resulting task path is limited to 238 characters.</remarks>
    public static string GetFileTaskPath(string subFolderName, string filePath, string fileName)
    {
        ArgumentException.ThrowIfNullOrEmpty(filePath);
        string subfolder = SanitizeTaskComponent(subFolderName);
        string name = SanitizeTaskComponent(fileName);
        return BuildTaskPath(subfolder, filePath, name, GetUserSid());
    }

    //--------------------------------------------------
    private static bool ExecuteTaskOperation(TaskOperation operation, string subFolderName, string? taskPath,
        string command, string argumentPayload = "")
    {
        string subfolder = SanitizeTaskComponent(subFolderName);
        string sid = GetUserSid();
        taskPath ??= BuildTaskPath(subfolder, command, SanitizeTaskComponent(Path.GetFileName(command)), sid);
        string taskName = GetTaskName(taskPath, subfolder, sid);
        string workingDir = GetTaskWorkingDir();
        // Task Scheduler represents a literal '$' as '$$' in parameterizable fields.
        string scheduledWorkingDir = workingDir.Replace("$", "$$", StringComparison.Ordinal);
        string operationData = operation switch
        {
            TaskOperation.Register => BuildTaskXml(command, scheduledWorkingDir, sid),
            TaskOperation.Run => argumentPayload,
            TaskOperation.Query => "",
            TaskOperation.Delete => "",
            _ => throw new ArgumentOutOfRangeException(nameof(operation), operation, "Unknown task operation.")
        };

        int result = Execute((int)operation, MainFolderName, subfolder, taskName,
            command, ScheduledArguments, scheduledWorkingDir, sid, operationData);
        Marshal.ThrowExceptionForHR(result, new IntPtr(-1));
        return result == 0; // S_FALSE: missing or incompatible.
    }

    private static string BuildTaskPath(string subfolder, string filePath, string fileName, string sid)
    {
        string taskPath = $"{MainFolderName}\\{subfolder}\\{fileName}@{GetIdentifier(filePath)};user={GetIdentifier(sid)}";
        if (taskPath.Length > 238)
            throw new ArgumentException("Task path must not exceed 238 characters.");
        return taskPath;
    }

    private static string GetTaskName(string taskPath, string subfolder, string sid)
    {
        if (taskPath.Length > 238)
            throw new ArgumentException("Task path must not exceed 238 characters.", nameof(taskPath));
        string folderPrefix = MainFolderName + "\\" + subfolder + "\\";
        if (!taskPath.StartsWith(folderPrefix, StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Task path must belong to the configured main folder and subfolder.", nameof(taskPath));
        string taskName = taskPath[folderPrefix.Length..];
        if (!IsTaskName(taskName))
            throw new ArgumentException("Task name contains invalid characters, leading spaces or trailing spaces/dots.", nameof(taskPath));
        if (!taskName.EndsWith($";user={GetIdentifier(sid)}", StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("Task name must have the current user's suffix.", nameof(taskPath));
        return taskName;
    }

    private static string BuildTaskXml(string command, string workingDir, string sid)
    {
        static string Escape(string value) => SecurityElement.Escape(value)!;
        return $"""
            <Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
              <Principals><Principal id="Author">
                <UserId>{Escape(sid)}</UserId><LogonType>InteractiveToken</LogonType>
                <RunLevel>HighestAvailable</RunLevel>
              </Principal></Principals>
              <Settings>
                <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
                <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
                <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
                <AllowHardTerminate>true</AllowHardTerminate>
                <AllowStartOnDemand>true</AllowStartOnDemand><Enabled>true</Enabled>
                <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
              </Settings>
              <Actions Context="Author"><Exec>
                <Command>{Escape(command)}</Command>
                <Arguments>{Escape(ScheduledArguments)}</Arguments>
                <WorkingDirectory>{Escape(workingDir)}</WorkingDirectory>
              </Exec></Actions>
            </Task>
            """;
    }

    //--------------------------------------------------
    private static string GetTaskCommand()
    {
        string command = ValidatePath(TaskCommand ?? Environment.ProcessPath ?? throw new InvalidOperationException("Executable path is unavailable."));
        if (!string.Equals(Path.GetExtension(command), ".exe", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(Path.GetFileName(command), "dotnet.exe", StringComparison.OrdinalIgnoreCase))
            throw new NotSupportedException("Use an apphost or NativeAOT executable, not dotnet.exe.");
        return command;
    }

    private static string GetTaskWorkingDir()
        => ValidatePath(TaskWorkingDir ?? Environment.CurrentDirectory);

    private static string ValidatePath(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        if (!Path.IsPathFullyQualified(path))
            throw new ArgumentException("Use a fully qualified path.", nameof(path));
        if (path.Contains('\0'))
            throw new ArgumentException("Path must not contain NUL.", nameof(path));
        if (path.Contains('%'))
            throw new ArgumentException("Path must not contain '%' (Task Scheduler expands environment variables).", nameof(path));
        return Path.GetFullPath(path);
    }

    private static bool IsPathUnderProgramFiles(string path)
    {
        foreach (Environment.SpecialFolder folder in new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86 })
        {
            string root = Environment.GetFolderPath(folder);
            if (root == "")
                continue;
            string directoryPrefix = Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar;
            if (path.StartsWith(directoryPrefix, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    //--------------------------------------------------
    private static bool IsAdministrator()
    {
        using WindowsIdentity user = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(user).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static string GetUserSid()
    {
        using WindowsIdentity user = WindowsIdentity.GetCurrent();
        return user.User?.Value ?? throw new InvalidOperationException("Current user SID is unavailable.");
    }

    //--------------------------------------------------
    // Reserved device names, including names followed by an extension.
    // https://learn.microsoft.com/windows/win32/fileio/naming-a-file
    private static readonly string[] ReservedDeviceNames =
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³"
    };

    private static string SanitizeTaskComponent(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        if (name == "")
            return "Unnamed";
        StringBuilder result = new StringBuilder();
        foreach (char character in name)
        {
            if (character < 32 || "%<>:\"/\\|?*".Contains(character))
                result.Append('%').Append(((int)character).ToString("X2"));
            else
                result.Append(character);
        }
        string component = result.ToString();
        component = Regex.Replace(component, @"[ .]+\z",
            static match => match.Value.Replace(" ", "%20").Replace(".", "%2E"));
        component = Regex.Replace(component, @"\A +",
            static match => match.Value.Replace(" ", "%20"));
        foreach (string deviceName in ReservedDeviceNames)
        {
            if (Regex.IsMatch(component, $@"\A{Regex.Escape(deviceName)}(?:\.|\z)",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                return "_" + component;
        }
        return component;
    }

    private static bool IsTaskName(string name)
    {
        if (name == "" || name.StartsWith(' ') || name != name.TrimEnd(' ', '.'))
            return false;
        foreach (char character in name)
            if (character < 32 || "<>:\"/\\|?*".Contains(character))
                return false;
        return true;
    }

    //--------------------------------------------------
    // Stable task identity: exact input -> UTF-8 -> first 128 bits of SHA-256.
    private static string GetIdentifier(string value)
        => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)).AsSpan(0, 16));

    //--------------------------------------------------
    [LibraryImport("TaskElevation.Native.dll", EntryPoint = "TaskElevationExecute", StringMarshalling = StringMarshalling.Utf16)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.AssemblyDirectory | DllImportSearchPath.System32)]
    private static partial int Execute(int operation, string mainFolder, string subfolder, string name,
        string command, string arguments, string directory, string sid, string operationData);
}
