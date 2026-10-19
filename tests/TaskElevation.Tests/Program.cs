using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using SevenKeyboard;

internal static class Program
{
    private const string Subfolder = "My:App";
    private static string WorkingDirectory
        => Path.Combine(AppContext.BaseDirectory, "literal $(Arg0) $$ dollar$");
    private static string Sid
    {
        get { using WindowsIdentity user = WindowsIdentity.GetCurrent(); return user.User!.Value; }
    }
    private static bool IsAdministrator()
    {
        using WindowsIdentity user = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(user).IsInRole(WindowsBuiltInRole.Administrator);
    }

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            // Namespace belongs exclusively to this installation; no product tasks are touched.
            string installName = Directory.GetParent(AppContext.BaseDirectory.TrimEnd('\\'))!.Name;
            TaskElevation.MainFolderName = installName;
            TaskElevation.TaskWorkingDir = WorkingDirectory;
            if (args.Length > 0 && args[0] == "--byscheduler")
            {
                Report(TaskElevation.RestoreArguments(args));
                return 0;
            }
            switch (args.Single())
            {
                case "--local": LocalTests(); break;
                case "--path":
                    Console.WriteLine(TaskElevation.GetFileTaskPath(Subfolder, Environment.ProcessPath!, "TaskElevation.Tests.exe"));
                    break;
                case "--register":
                    Check(TaskElevation.Register(Subfolder), "register");
                    Check(TaskElevation.Register(Subfolder), "repeat register");
                    Check(TaskElevation.IsRegistered(Subfolder), "query");
                    Check(!TaskElevation.RelaunchAsAdmin(Subfolder, Array.Empty<string>()), "already admin");
                    Console.WriteLine("PASS register/update/query/already-elevated");
                    break;
                case "--delete":
                    Check(TaskElevation.Unregister(Subfolder), "delete");
                    Check(!TaskElevation.Unregister(Subfolder), "repeat delete");
                    Check(!TaskElevation.IsRegistered(Subfolder), "absent");
                    Console.WriteLine("PASS unregister/absent");
                    break;
                case "--incompatible":
                    Check(!TaskElevation.IsRegistered(Subfolder), "incompatible");
                    Console.WriteLine("PASS incompatible task rejected");
                    break;
                case "--conflict":
                    Throws<COMException>(() => TaskElevation.Register(Subfolder));
                    Console.WriteLine("PASS unrelated definition not overwritten");
                    break;
                case "--test": LiveTests(); break;
                default: throw new ArgumentException("Unknown mode.");
            }
            return 0;
        }
        catch (Exception e) { Console.Error.WriteLine(e); return 1; }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static void Throws<T>(Action action) where T : Exception
    {
        try { action(); }
        catch (T) { return; }
        throw new Exception("Expected " + typeof(T).Name);
    }

    // Independent wire-format fixture, not the library's encoder.
    private static string Payload(params string[] args)
    {
        using MemoryStream stream = new MemoryStream();
        using (BinaryWriter writer = new BinaryWriter(stream, new UTF8Encoding(false, true), true))
        {
            writer.Write((byte)1);
            writer.Write(args.Length);
            foreach (string arg in args) writer.Write(arg);
        }
        return Convert.ToBase64String(stream.ToArray());
    }

    private static string[] Restore(string payload)
        => TaskElevation.RestoreArguments(new[] { "--byscheduler", "--task-elevation-v1", payload });

    private static void LocalTests()
    {
        string[] ordinary = { "--profile-id=7" };
        Check(ReferenceEquals(ordinary, TaskElevation.RestoreArguments(ordinary)), "ordinary args");
        string[] values = { "", "한글 日本語 😀", "a\"b", @"C:\x\", "%PATH%", "$(Arg0)", "a\nb" };
        Check(values.SequenceEqual(Restore(Payload(values))), "decode");
        Check(Restore(Payload()).Length == 0, "empty");
        Throws<FormatException>(() => TaskElevation.RestoreArguments(new[] { "--byscheduler" }));
        Throws<FormatException>(() => Restore("%%%"));
        Throws<FormatException>(() => Restore(""));
        Throws<FormatException>(() => Restore(new string('A', 24004)));
        foreach (byte[] bytes in new[] {
            new byte[] { 2, 0, 0, 0, 0 },             // Unknown version.
            new byte[] { 1, 255, 255, 255, 255 },     // Negative count.
            new byte[] { 1, 1, 0, 0, 0 },             // Missing string.
            new byte[] { 1, 0, 0, 0, 0, 9 },          // Trailing data.
            new byte[] { 1, 1, 0, 0, 0, 1, 0 },       // NUL.
            new byte[] { 1, 1, 0, 0, 0, 1, 255 },     // Invalid UTF-8.
            new byte[] { 1, 1, 0, 0, 0, 255, 255, 255, 255, 7 } // Huge declared string.
        })
            Throws<FormatException>(() => Restore(Convert.ToBase64String(bytes)));
        TaskElevation.MainFolderName = "Test";
        // Fixed SHA-256/UTF-8 vectors; do not derive the expected path hash with the library.
        (string Value, string Hash)[] vectors = {
            ("abc", "BA7816BF8F01CFEA414140DE5DAE2223"),
            (@"C:\a.exe", "B2002C4CEEAD451EDA890718A9C2D471"),
            (@"C:\한글 日本語\a.exe", "507454D6641B0468EBBF931B6398700C"),
            ("😀", "F0443A342C5EF54783A111B51BA56C93")
        };
        using SHA256 hash = SHA256.Create();
        string sidHash = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(Sid)), 0, 16).Replace("-", "");
        foreach (var vector in vectors)
        {
            string expected = $"Test\\My%3AApp\\_CON.txt@{vector.Hash};user={sidHash}";
            Check(TaskElevation.GetFileTaskPath("My:App", vector.Value, "CON.txt") == expected, "SHA-256/name vector");
            Check(TaskElevation.GetFileTaskPath("My:App", vector.Value, "CON.txt") == expected, "stable name");
        }
        Check(TaskElevation.GetFileTaskPath("My:App", "abc", "CON.txt") != TaskElevation.GetFileTaskPath("My:App", "ABC", "CON.txt"), "exact input policy");
        // Main/sub/name separators + two 32-digit hashes + '@' + ';user='.
        int fixedLength = "Test".Length + 1 + "My%3AApp".Length + 1 + 1 + 32 + 6 + 32;
        string maxName = new string('x', 238 - fixedLength);
        Check(TaskElevation.GetFileTaskPath("My:App", "abc", maxName).Length == 238, "238-character task path");
        Throws<ArgumentException>(() => TaskElevation.GetFileTaskPath("My:App", "abc", maxName + "x"));
        TaskElevation.MainFolderName = "A. ";
        Check(TaskElevation.MainFolderName == "A%2E%20", "trailing escaping");
        TaskElevation.MainFolderName = "";
        Check(TaskElevation.MainFolderName == "Unnamed", "empty escaping");
        foreach ((string name, string escaped) in new[] {
            ("COM1.txt", "_COM1.txt"), ("LPT¹", "_LPT¹"),
            ("COM0", "COM0"), ("COM10", "COM10"),
            ("con.tar.gz", "_con.tar.gz"), ("XCON.txt", "XCON.txt"), ("CONSOLE", "CONSOLE"),
            ("COM¹.log", "_COM¹.log"), ("lpt³.txt", "_lpt³.txt"), ("COM9a", "COM9a"),
            ("CON.", "CON%2E"), ("a. b", "a. b"), (" .", "%20%2E"),
            (" Leading", "%20Leading"), ("  Leading", "%20%20Leading"),
            (" Leading. ", "%20Leading%2E%20"), ("  ", "%20%20"),
            (" CON.txt", "%20CON.txt"), ("A B", "A B"),
            ("a%b", "a%25b"), ("a\0b", "a%00b"), ("a. ", "a%2E%20"),
            ("😀. ", "😀%2E%20"), ("a\n", "a%0A")
        })
        {
            TaskElevation.MainFolderName = name;
            Check(TaskElevation.MainFolderName == escaped, "device/escaped name: " + name);
        }
        TaskElevation.MainFolderName = "Test";
        TaskElevation.TaskCommand = @"C:\dotnet.exe";
        Throws<NotSupportedException>(() => TaskElevation.IsRegistered("unused"));
        TaskElevation.TaskCommand = "relative.exe";
        Throws<ArgumentException>(() => TaskElevation.IsRegistered("unused"));
        TaskElevation.TaskCommand = "C:\\a\0b.exe";
        Throws<ArgumentException>(() => TaskElevation.IsRegistered("unused"));
        TaskElevation.TaskCommand = @"C:\%PATH%\a.exe";
        Throws<ArgumentException>(() => TaskElevation.IsRegistered("unused"));
        TaskElevation.TaskCommand = @"C:\test.exe";
        Throws<ArgumentException>(() => TaskElevation.IsRegistered("unused", new string('x', 239)));
        Throws<ArgumentException>(() => TaskElevation.IsRegistered("unused", "Other\\unused\\task"));
        Throws<ArgumentException>(() => TaskElevation.IsRegistered("unused", "Test\\unused\\bad:name"));
        Throws<ArgumentException>(() => TaskElevation.IsRegistered("unused", "Test\\unused\\wrong-user"));
        string generatedTaskPath = TaskElevation.GetFileTaskPath("unused", @"C:\test.exe", " Leading.exe");
        Check(generatedTaskPath.StartsWith("Test\\unused\\%20Leading.exe@", StringComparison.Ordinal), "leading space in generated task name");
        string leadingSpaceTaskPath = generatedTaskPath.Replace("%20Leading.exe@", " Leading.exe@", StringComparison.Ordinal);
        Throws<ArgumentException>(() => TaskElevation.IsRegistered("unused", leadingSpaceTaskPath));
        TaskElevation.TaskCommand = Path.GetFullPath("outside.exe");
        Check(!TaskElevation.RelaunchAsAdmin("unused", Array.Empty<string>()), "outside Program Files");
        Console.WriteLine("PASS payload validation, SHA-256 fixed vectors and task-name length, sanitizing, host/path guards");
    }

    private static string ReportPath(string id)
        => Path.Combine(AppContext.BaseDirectory, "report-" + id + ".txt");

    private static void Report(string[] args)
    {
        if (args.Length == 0 || !Guid.TryParseExact(args[0], "N", out _))
            throw new ArgumentException("Report ID missing.");
        string[] lines = new[] { IsAdministrator().ToString(), Sid, Environment.CurrentDirectory }
            .Concat(args.Skip(1).Select(s => Convert.ToBase64String(Encoding.Unicode.GetBytes(s)))).ToArray();
        string path = ReportPath(args[0]);
        File.WriteAllLines(path + ".tmp", lines);
        File.Move(path + ".tmp", path, true);
    }

    private static void CheckReport(string id, string[] expected)
    {
        for (int i = 0; i < 300 && !File.Exists(ReportPath(id)); i++) Thread.Sleep(100);
        string[] report = File.ReadAllLines(ReportPath(id));
        string[] actual = report.Skip(3).Select(s => Encoding.Unicode.GetString(Convert.FromBase64String(s))).ToArray();
        Check(report[0] == "True" && report[1] == Sid &&
            string.Equals(Path.TrimEndingDirectorySeparator(report[2]), Path.TrimEndingDirectorySeparator(WorkingDirectory), StringComparison.OrdinalIgnoreCase) &&
            expected.SequenceEqual(actual), "privilege/SID/cwd/argv mismatch");
    }

    private static void LiveTests()
    {
        Check(!IsAdministrator(), "Run unelevated");
        Check(!TaskElevation.Register(Subfolder) && !TaskElevation.Unregister(Subfolder), "admin guard");
        Check(TaskElevation.IsRegistered(Subfolder), "registered");
        string taskPath = TaskElevation.GetFileTaskPath(Subfolder, Environment.ProcessPath!, "TaskElevation.Tests.exe");
        Check(TaskElevation.IsRegistered(Subfolder, taskPath), "explicit SHA-256 task path");
        Throws<ArgumentException>(() => TaskElevation.IsRegistered(Subfolder, taskPath[..^32] + "12345678"));
        Check(Task.Run(() => TaskElevation.IsRegistered(Subfolder)).GetAwaiter().GetResult(), "MTA query");
        Throws<ArgumentException>(() => TaskElevation.RelaunchAsAdmin(Subfolder, new[] { "a\0b" }));
        Throws<EncoderFallbackException>(() => TaskElevation.RelaunchAsAdmin(Subfolder, new[] { "\uD800" }));
        Throws<ArgumentException>(() => TaskElevation.RelaunchAsAdmin(Subfolder, new[] { new string('x', 18000) }));
        Throws<ArgumentException>(() => TaskElevation.RelaunchAsAdmin(Subfolder, new string[4097]));
        Check(!TaskElevation.RelaunchAsAdmin("Missing", Array.Empty<string>()), "missing task");
        foreach (string[] values in new[] {
            Array.Empty<string>(),
            new[] { "--profile-id=7", "--show-settings" },
            new[] { "", "한글 日本語 😀", "a\"b", @"C:\folder with space\", @"\\", "line1\nline2", "&|<>^%PATH%", "$(Arg0)", "$(Arg1)" },
            Enumerable.Range(0, 40).Select(i => "argument " + i).ToArray(),
            new[] { new string('x', 17000) }
        })
        {
            string id = Guid.NewGuid().ToString("N");
            Check(TaskElevation.RelaunchAsAdmin(Subfolder, new[] { id }.Concat(values).ToArray()), "run");
            CheckReport(id, values);
            Console.WriteLine($"PASS library round-trip: {values.Length} args; elevated, same SID/cwd");
        }
        string a = Guid.NewGuid().ToString("N"), b = Guid.NewGuid().ToString("N");
        Check(TaskElevation.RelaunchAsAdmin(Subfolder, new[] { a, "first" }), "first");
        Check(Task.Run(() => TaskElevation.RelaunchAsAdmin(Subfolder, new[] { b, "second" })).GetAwaiter().GetResult(), "MTA run");
        CheckReport(a, new[] { "first" });
        CheckReport(b, new[] { "second" });
        Console.WriteLine("PASS concurrent requests, MTA, permission/payload guards");
    }
}
