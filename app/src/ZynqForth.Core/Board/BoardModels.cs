using System.Globalization;

namespace ZynqForth.Board;

/// <summary>
/// The <c>version</c> answer. <see cref="Cores"/> is 1 for the single-core firmware (no
/// <c>cores</c> line, protocol 2) and 2 for the dual-core firmware (protocol 3).
/// </summary>
public sealed record BoardVersion(string Product, string Firmware, int Protocol, int KernelWords, ushort KernelChecksum, int Cores = 1)
{
    /// <summary>The protocol that addresses cores and multiplexes their terminals.</summary>
    public const int DualCoreProtocol = 3;

    public bool IsDualCore => Protocol >= DualCoreProtocol && Cores >= 2;

    public static BoardVersion Parse(string text)
    {
        Dictionary<string, string[]> lines = Lines(text);
        string[] firmware = lines.GetValueOrDefault("firmware", ["?", "?"]);
        string[] kernel = lines.GetValueOrDefault("kernel", ["0", "0"]);
        int protocol = int.TryParse(lines.GetValueOrDefault("protocol", ["0"])[0], out int p) ? p : 0;
        int cores = lines.TryGetValue("cores", out string[]? c) && c.Length > 0 && int.TryParse(c[0], out int n) && n > 0 ? n : 1;
        return new BoardVersion(
            firmware.Length > 0 ? firmware[0] : "?",
            firmware.Length > 1 ? firmware[1] : "?",
            protocol,
            int.TryParse(kernel[0], out int words) ? words : 0,
            kernel.Length > 1 && ushort.TryParse(kernel[1], NumberStyles.HexNumber, null, out ushort sum) ? sum : (ushort)0,
            protocol >= DualCoreProtocol ? cores : 1);
    }

    internal static Dictionary<string, string[]> Lines(string text)
    {
        var lines = new Dictionary<string, string[]>(StringComparer.Ordinal);
        foreach (string line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            string[] words = line.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length > 0)
            {
                lines[words[0]] = words[1..];
            }
        }

        return lines;
    }
}

public enum SourceState { None, Stored, Damaged }

/// <summary>
/// The <c>status</c> answer of one core. <see cref="Mailbox"/> (protocol 3) counts the words
/// waiting in the core's mailbox from the other core; null when the firmware has none.
/// </summary>
public sealed record BoardStatus(
    bool Running, int ProgramCounter, int InputPending, int Starts,
    SourceState Source, int SourceLength, uint SourceCrc, bool Autostart, string LastStart,
    int Core = 0, int? Mailbox = null)
{
    public static BoardStatus Parse(string text)
    {
        Dictionary<string, string[]> lines = BoardVersion.Lines(text);
        string Value(string key) => lines.TryGetValue(key, out string[]? v) && v.Length > 0 ? v[0] : "";
        int Number(string key) => int.TryParse(Value(key), out int n) ? n : 0;

        return new BoardStatus(
            Value("state") == "running",
            int.TryParse(Value("pc"), NumberStyles.HexNumber, null, out int pc) ? pc : 0,
            Number("input"),
            Number("starts"),
            Value("source") switch { "stored" => SourceState.Stored, "damaged" => SourceState.Damaged, _ => SourceState.None },
            Number("length"),
            uint.TryParse(Value("crc"), NumberStyles.HexNumber, null, out uint crc) ? crc : 0,
            Value("autostart") == "on",
            Value("last"),
            Number("core"),
            lines.ContainsKey("mailbox") ? Number("mailbox") : null);
    }
}

/// <summary>One dictionary entry: code address, flags and name.</summary>
public sealed record ForthWord(int CodeAddress, bool Immediate, bool Hidden, bool Inline, string Name)
{
    public string Flags => (Immediate ? "immediate " : "") + (Inline ? "inline " : "") + (Hidden ? "hidden" : "");
}

/// <summary>The <c>words</c> answer: HERE and the entries, newest first.</summary>
public sealed record WordList(int Here, IReadOnlyList<ForthWord> Words)
{
    public static WordList Parse(string text)
    {
        int here = 0;
        var words = new List<ForthWord>();
        foreach (string line in text.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            string[] parts = line.Split(' ', 3);
            if (parts is ["here", var value])
            {
                here = int.Parse(value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            }
            else if (parts.Length == 3 && int.TryParse(parts[0], NumberStyles.HexNumber, null, out int address))
            {
                string flags = parts[1];
                words.Add(new ForthWord(address, flags.Contains('i'), flags.Contains('h'), flags.Contains('n'), parts[2]));
            }
        }

        return new WordList(here, words);
    }
}

/// <summary>
/// The <c>stack</c> answer: the data stack at the last prompt, bottom first, as 32-bit cells,
/// and on its second line (<c>f depth items</c>) the float stack as IEEE single bits.
/// </summary>
public sealed record DataStack(IReadOnlyList<uint> Items, IReadOnlyList<uint> Floats)
{
    public static DataStack Parse(string text)
    {
        string[] lines = text.Replace("\r", "").Split('\n', StringSplitOptions.RemoveEmptyEntries);
        IReadOnlyList<uint> items = lines.Length > 0 ? Cells(lines[0].Split(' ', StringSplitOptions.RemoveEmptyEntries)) : [];
        string[] floats = lines.Skip(1).Select(l => l.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            .FirstOrDefault(w => w.Length > 0 && w[0] == "f") ?? [];
        return new DataStack(items, floats.Length > 1 ? Cells(floats[1..]) : []);
    }

    private static List<uint> Cells(string[] words)
    {
        int depth = words.Length > 0 && int.TryParse(words[0], out int d) ? d : 0;
        var items = new List<uint>(depth);
        for (int i = 1; i <= depth && i < words.Length; i++)
        {
            items.Add(uint.Parse(words[i], NumberStyles.HexNumber, CultureInfo.InvariantCulture));
        }

        return items;
    }
}

/// <summary>Floats shown like the kernel's F.: up to 7 significant digits.</summary>
public static class FloatText
{
    public static string Format(float value) =>
        float.IsNaN(value) ? "NaN" :
        float.IsPositiveInfinity(value) ? "Inf" :
        float.IsNegativeInfinity(value) ? "-Inf" :
        value.ToString("G7", CultureInfo.InvariantCulture);
}
