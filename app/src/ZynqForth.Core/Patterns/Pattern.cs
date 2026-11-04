using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ZynqForth.Patterns;

/// <summary>Which edge of the trigger source a wait step waits for.</summary>
public enum TriggerEdge
{
    Rising = 1,
    Falling = 2,
    Both = 3,
}

/// <summary>What the generator does after the last step.</summary>
public enum PatternEnd
{
    /// <summary>Stop with the idle levels on the pins.</summary>
    Stop,

    /// <summary>Continue at <see cref="Pattern.RestartAt"/>, forever.</summary>
    Restart,
}

/// <summary>One step: the 16 channel levels for a number of 5 ns ticks.</summary>
public sealed class PatternStep
{
    /// <summary>Channel n = bit n.</summary>
    public ushort Levels { get; set; }

    /// <summary>1 to 2^32 - 1 ticks of 5 ns. A wait step holds its levels this long after the trigger.</summary>
    public long Ticks { get; set; } = 200;

    /// <summary>The step shows its levels and waits for the trigger before its ticks run.</summary>
    public bool Wait { get; set; }

    public PatternStep Clone() => new() { Levels = Levels, Ticks = Ticks, Wait = Wait };
}

/// <summary>Steps <c>First</c>..<c>Last</c> play <c>Count</c> times in all; 0 = forever.</summary>
public sealed record PatternRepeat(int First, int Last, int Count);

/// <summary>
/// A pattern as the editor holds it and a <c>.pattern</c> file stores it (JSON). The compiler
/// turns it into the generator's steps (docs/PatternGenerator.md).
/// </summary>
public sealed class Pattern
{
    public const int ChannelCount = 16;
    public const int MaxSteps = 4096;
    public const int MaxNesting = 4;
    public const int MaxCount = 65535;
    public const long MaxTicks = uint.MaxValue;
    public const double TickNs = 5;

    /// <summary>Trigger source numbers: 0..41 shield pins, 48..51 BTN0..BTN3, this one = software only.</summary>
    public const int SoftwareTrigger = 63;

    private const string FormatName = "zynq-forth pattern 1";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public string Format { get; set; } = FormatName;

    public string[] ChannelNames { get; set; } = DefaultNames();

    public List<PatternStep> Steps { get; set; } = [];

    public List<PatternRepeat> Repeats { get; set; } = [];

    /// <summary>Channels driven by the generator; the others stay high-impedance.</summary>
    public ushort Enabled { get; set; } = 0xFFFF;

    /// <summary>The levels while stopped and after the end.</summary>
    public ushort Idle { get; set; }

    public int TriggerSource { get; set; } = SoftwareTrigger;

    public TriggerEdge TriggerEdge { get; set; } = TriggerEdge.Rising;

    public PatternEnd End { get; set; } = PatternEnd.Stop;

    /// <summary>The step a <see cref="PatternEnd.Restart"/> continues at.</summary>
    public int RestartAt { get; set; }

    /// <summary>A small start: a 4-bit counter on channels 0..3 in steps of 1 µs, repeated.</summary>
    public static Pattern CreateDefault()
    {
        var pattern = new Pattern { Enabled = 0x000F, End = PatternEnd.Restart };
        for (int i = 0; i < 16; i++)
        {
            pattern.Steps.Add(new PatternStep { Levels = (ushort)i, Ticks = 200 });
        }

        return pattern;
    }

    public static string[] DefaultNames() => [.. Enumerable.Range(0, ChannelCount).Select(c => "CH" + c)];

    /// <summary>The trigger sources the editor offers, with their names.</summary>
    public static IReadOnlyList<(int Source, string Name)> TriggerSources { get; } =
    [
        (SoftwareTrigger, "software (pg-trig)"),
        .. Enumerable.Range(48, 4).Select(n => (n, "BTN" + (n - 48))),
        .. Enumerable.Range(0, 14).Select(n => (n, "IO" + n)),
        .. Enumerable.Range(14, 6).Select(n => (n, "A" + (n - 14))),
        .. Enumerable.Range(26, 16).Select(n => (n, "IO" + n)),
    ];

    public string ToJson() => JsonSerializer.Serialize(this, JsonOptions);

    public static Pattern FromJson(string json)
    {
        Pattern pattern = JsonSerializer.Deserialize<Pattern>(json, JsonOptions)
                          ?? throw new FormatException("The file holds no pattern.");
        if (pattern.Format != FormatName)
        {
            throw new FormatException($"Not a ZYNQ-FORTH pattern (format '{pattern.Format}').");
        }

        string[] names = DefaultNames();
        for (int c = 0; c < ChannelCount && c < pattern.ChannelNames.Length; c++)
        {
            names[c] = pattern.ChannelNames[c];
        }

        pattern.ChannelNames = names;
        foreach (PatternStep step in pattern.Steps)
        {
            step.Ticks = Math.Clamp(step.Ticks, 1, MaxTicks);
        }

        return pattern;
    }
}

/// <summary>Durations as people write them, in 5 ns ticks.</summary>
public static class Durations
{
    /// <summary>"5 ns", "1.25 µs", "3 ms", "1.5 s": the largest unit with a value of at least 1.</summary>
    public static string Format(long ticks)
    {
        double ns = ticks * Pattern.TickNs;
        (double value, string unit) = ns switch
        {
            >= 1e9 => (ns / 1e9, "s"),
            >= 1e6 => (ns / 1e6, "ms"),
            >= 1e3 => (ns / 1e3, "µs"),
            _ => (ns, "ns"),
        };
        return value.ToString("0.####", CultureInfo.InvariantCulture) + " " + unit;
    }

    /// <summary>
    /// "100 ns", "2.5us", "2.5 µs", "1 ms", "0.5 s"; a bare number means ns. Rounds to the
    /// nearest tick; null when the text is no duration or outside 5 ns .. 2^32 - 1 ticks.
    /// </summary>
    public static long? Parse(string text)
    {
        string s = text.Trim().ToLowerInvariant().Replace(',', '.');
        double scale = 1;
        foreach ((string unit, double factor) in new[] { ("ns", 1.0), ("us", 1e3), ("µs", 1e3), ("ms", 1e6), ("s", 1e9) })
        {
            if (s.EndsWith(unit, StringComparison.Ordinal))
            {
                s = s[..^unit.Length].TrimEnd();
                scale = factor;
                break;
            }
        }

        if (!double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out double value) || value <= 0)
        {
            return null;
        }

        double ticks = Math.Round(value * scale / Pattern.TickNs);
        return ticks is >= 1 and <= Pattern.MaxTicks ? (long)ticks : null;
    }
}
