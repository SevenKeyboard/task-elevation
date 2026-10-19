using System;
using System.IO;
using System.Text;

namespace SevenKeyboard;

// Bounded, versioned payload: no environment expansion or command-line quoting loss.
internal static class TaskArguments
{
    private const byte PayloadVersion = 1;
    private const int MaxPayloadLength = 24000;
    private const int MaxBinaryLength = MaxPayloadLength * 3 / 4;
    private const int MaxArgumentCount = 4096;
    private static readonly Encoding Utf8 = new UTF8Encoding(false, true);

    //--------------------------------------------------
    // Layout: [version][argument count][arg1 byte length][arg1][arg2 byte length][arg2]... -> Base64.
    internal static string Encode(string[] args)
    {
        if (args.Length > MaxArgumentCount)
            throw new ArgumentException("Too many arguments.", nameof(args));
        using MemoryStream stream = new MemoryStream();
        using (BinaryWriter writer = new BinaryWriter(stream, Utf8, leaveOpen: true))
        {
            writer.Write(PayloadVersion);
            writer.Write(args.Length);
            foreach (string arg in args)
            {
                ArgumentNullException.ThrowIfNull(arg);
                if (arg.Contains('\0'))
                    throw new ArgumentException("Argument must not contain NUL.", nameof(args));
                if (Utf8.GetByteCount(arg) > MaxBinaryLength)
                    throw new ArgumentException("Argument exceeds the payload limit.", nameof(args));
                writer.Write(arg);
                if (stream.Length > MaxBinaryLength)
                    throw new ArgumentException("Encoded arguments exceed the 24000-character payload limit.", nameof(args));
            }
        }
        return Convert.ToBase64String(stream.ToArray());
    }

    //--------------------------------------------------
    internal static string[] Decode(string payload)
    {
        ArgumentNullException.ThrowIfNull(payload);
        if (payload.Length > MaxPayloadLength)
            throw new FormatException("Task argument payload is too large.");
        try
        {
            using MemoryStream stream = new MemoryStream(Convert.FromBase64String(payload));
            using BinaryReader reader = new BinaryReader(stream, Utf8);
            if (reader.ReadByte() != PayloadVersion)
                throw new FormatException("Unsupported task argument payload version.");
            int count = reader.ReadInt32();
            if (count < 0 || count > MaxArgumentCount)
                throw new FormatException("Invalid task argument count.");
            string[] args = new string[count];
            for (int i = 0; i < count; i++)
            {
                args[i] = reader.ReadString();
                if (args[i].Contains('\0'))
                    throw new FormatException("Task argument contains NUL.");
            }
            if (stream.Position != stream.Length)
                throw new FormatException("Trailing task argument data.");
            return args;
        }
        catch (Exception e) when (e is IOException or DecoderFallbackException)
        {
            throw new FormatException("Malformed task argument payload.", e);
        }
    }
}
