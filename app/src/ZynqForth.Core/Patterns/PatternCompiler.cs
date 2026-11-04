using System.Globalization;
using System.Text;

namespace ZynqForth.Patterns;

/// <summary>The generator's step operations (rtl/patgen.v).</summary>
public enum StepOp
{
    Step = 0,
    Loop = 1,
    Jump = 2,
    Wait = 3,
    End = 4,
}

/// <summary>One step as the generator stores it.</summary>
public sealed record HardwareStep(ushort Levels, long Ticks, StepOp Op, int Target, int Count);

/// <summary>A pattern checked and translated: the generator's steps, or why it cannot be played.</summary>
public sealed class CompiledPattern
{
    internal CompiledPattern(IReadOnlyList<HardwareStep> steps, IReadOnlyList<string> errors, IReadOnlyList<string> warnings)
    {
        Steps = steps;
        Errors = errors;
        Warnings = warnings;
    }

    public IReadOnlyList<HardwareStep> Steps { get; }

    public IReadOnlyList<string> Errors { get; }

    /// <summary>The pattern plays, but maybe not as meant (timing, trigger, channels).</summary>
    public IReadOnlyList<string> Warnings { get; }

    public bool Ok => Errors.Count == 0;
}

/// <summary>
/// Turns an editor pattern into generator steps and those into Forth. Each editor step is one
/// generator step; a repeat becomes a <c>loop</c> on its last step, a restart a <c>jump</c>
/// on the last step, a stop an extra <c>end</c> step with the idle levels.
/// </summary>
public static class PatternCompiler
{
    /// <summary>Forth's input line holds 80 characters; generated lines stay well below.</summary>
    public const int MaxLine = 72;

    public static CompiledPattern Compile(Pattern pattern)
    {
        ArgumentNullException.ThrowIfNull(pattern);
        var errors = new List<string>();
        var warnings = new List<string>();
        List<PatternStep> steps = pattern.Steps;
        int n = steps.Count;

        if (n == 0)
        {
            errors.Add("The pattern has no steps.");
            return new CompiledPattern([], errors, warnings);
        }

        int total = n + (pattern.End == PatternEnd.Stop ? 1 : 0);
        if (total > Pattern.MaxSteps)
        {
            errors.Add($"The pattern needs {total} steps; the generator holds {Pattern.MaxSteps}.");
        }

        var ops = new StepOp[n];
        var targets = new int[n];
        var counts = new int[n];
        for (int i = 0; i < n; i++)
        {
            ops[i] = steps[i].Wait ? StepOp.Wait : StepOp.Step;
            if (steps[i].Ticks is < 1 or > Pattern.MaxTicks)
            {
                errors.Add($"Step {i}: the duration is outside 5 ns .. 21.47 s.");
            }
        }

        CheckRepeats(pattern, errors, warnings);
        foreach (PatternRepeat r in pattern.Repeats)
        {
            if (r.First < 0 || r.Last >= n || r.First > r.Last)
            {
                continue;                       // reported by CheckRepeats
            }

            if (ops[r.Last] == StepOp.Wait)
            {
                errors.Add($"Step {r.Last} waits for the trigger and ends a repeat; a step can do only one of the two.");
            }
            else if (ops[r.Last] == StepOp.Loop)
            {
                continue;                       // two repeats ending there: reported by CheckRepeats
            }

            ops[r.Last] = StepOp.Loop;
            targets[r.Last] = r.First;
            counts[r.Last] = r.Count;
        }

        if (pattern.End == PatternEnd.Restart)
        {
            int at = pattern.RestartAt;
            if (at < 0 || at >= n)
            {
                errors.Add($"The restart step {at} does not exist.");
            }
            else if (pattern.Repeats.Any(r => r.First < at && at <= r.Last))
            {
                errors.Add($"The restart step {at} lies inside a repeat; restart at the repeat's first step or outside it.");
            }

            if (ops[n - 1] != StepOp.Step)
            {
                errors.Add($"The last step (step {n - 1}) {(ops[n - 1] == StepOp.Wait ? "waits for the trigger" : "ends a repeat")}; " +
                           "add a step after it for the restart.");
            }
            else
            {
                ops[n - 1] = StepOp.Jump;
                targets[n - 1] = at;
            }

            CheckSlack(steps, at, n - 1, 0, "The restart loop", warnings);
        }

        if (steps.Any(s => s.Wait) && pattern.TriggerSource == Pattern.SoftwareTrigger)
        {
            warnings.Add("Wait steps wait for the software trigger only (pg-trig); choose a trigger source for a pin or button.");
        }

        int unused = steps.Aggregate(0, (acc, s) => acc | s.Levels) & ~pattern.Enabled & 0xFFFF;
        if (unused != 0)
        {
            var channels = Enumerable.Range(0, Pattern.ChannelCount).Where(c => (unused & (1 << c)) != 0);
            warnings.Add($"Channel(s) {string.Join(", ", channels)} have high levels but are not enabled.");
        }

        var result = new List<HardwareStep>(total);
        for (int i = 0; i < n; i++)
        {
            result.Add(new HardwareStep(steps[i].Levels, steps[i].Ticks, ops[i], targets[i], counts[i]));
        }

        if (pattern.End == PatternEnd.Stop)
        {
            result.Add(new HardwareStep(pattern.Idle, 1, StepOp.End, 0, 0));
        }

        return new CompiledPattern(result, errors, warnings);
    }

    /// <summary>Repeats must nest or stay apart, end on different steps and nest at most four deep.</summary>
    private static void CheckRepeats(Pattern pattern, List<string> errors, List<string> warnings)
    {
        List<PatternRepeat> repeats = pattern.Repeats;
        int n = pattern.Steps.Count;
        foreach (PatternRepeat r in repeats)
        {
            if (r.First < 0 || r.Last >= n || r.First > r.Last)
            {
                errors.Add($"A repeat over steps {r.First}–{r.Last} lies outside the pattern.");
            }
            else if (r.Count is < 0 or > Pattern.MaxCount)
            {
                errors.Add($"Repeat over steps {r.First}–{r.Last}: the count must be 1..{Pattern.MaxCount}, or 0 for forever.");
            }
        }

        for (int i = 0; i < repeats.Count; i++)
        {
            for (int j = i + 1; j < repeats.Count; j++)
            {
                PatternRepeat a = repeats[i], b = repeats[j];
                bool apart = a.Last < b.First || b.Last < a.First;
                bool nested = (a.First <= b.First && b.Last <= a.Last) || (b.First <= a.First && a.Last <= b.Last);
                if (!apart && !nested)
                {
                    errors.Add($"The repeats over steps {a.First}–{a.Last} and {b.First}–{b.Last} overlap; one must contain the other.");
                }
                else if (a.Last == b.Last)
                {
                    errors.Add($"Two repeats end on step {a.Last}; let the outer one end on a later step.");
                }
            }
        }

        foreach (PatternRepeat r in repeats)
        {
            int depth = repeats.Count(o => o.First <= r.First && r.Last <= o.Last);
            if (depth > Pattern.MaxNesting)
            {
                errors.Add($"The repeat over steps {r.First}–{r.Last} is nested {depth} deep; the generator allows {Pattern.MaxNesting}.");
            }

            if (r.Count != 1 && r.First >= 0 && r.Last < n && r.First <= r.Last)
            {
                CheckSlack(pattern.Steps, r.First, r.Last, r.Count, $"The repeat over steps {r.First}–{r.Last}", warnings);
            }
        }
    }

    /// <summary>
    /// The generator loses a clock at every jump back and makes it up during steps longer than
    /// one tick: one pass must last at least one tick more than it has steps.
    /// </summary>
    private static void CheckSlack(List<PatternStep> steps, int first, int last, int count, string what, List<string> warnings)
    {
        if (first < 0 || last >= steps.Count || first > last)
        {
            return;
        }

        long ticks = 0;
        for (int i = first; i <= last; i++)
        {
            ticks += steps[i].Ticks;
        }

        if (ticks < last - first + 2)
        {
            warnings.Add($"{what}: one pass lasts only {ticks} ticks for {last - first + 1} step(s); " +
                         "the generator needs one tick more and may run late (status: late).");
        }
    }

    /// <summary>The Forth that loads the pattern (and starts it): short lines, decimal base.</summary>
    public static string ToForth(Pattern pattern, CompiledPattern compiled, string? title = null, bool start = true)
    {
        if (!compiled.Ok)
        {
            throw new InvalidOperationException("The pattern has errors: " + string.Join(" ", compiled.Errors));
        }

        var text = new StringBuilder();
        text.Append(@"\ ZYNQ-FORTH pattern").Append(title is null ? "" : ": " + title)
            .Append(", ").Append(compiled.Steps.Count).Append(" steps").AppendLine();
        text.AppendLine("decimal pg-stop");
        text.AppendLine($"{Hex(pattern.Enabled)} pg-enable {Hex(pattern.Idle)} pg-idle");
        text.AppendLine($"{pattern.TriggerSource} {(int)pattern.TriggerEdge} pg-trigger 0 pg-at");
        foreach (HardwareStep s in compiled.Steps)
        {
            string line = s.Op switch
            {
                StepOp.Step => $"{Hex(s.Levels)} {Duration(s.Ticks)} pg-step",
                StepOp.Wait => $"{Hex(s.Levels)} {Duration(s.Ticks)} pg-wait",
                StepOp.Loop => $"{Hex(s.Levels)} {Duration(s.Ticks)} {s.Target} {s.Count} pg-loop",
                StepOp.Jump => $"{Hex(s.Levels)} {Duration(s.Ticks)} {s.Target} pg-jump",
                _ => $"{Hex(s.Levels)} pg-end",
            };
            text.AppendLine(line);
        }

        if (start)
        {
            text.AppendLine("pg-start");
        }

        return text.ToString();
    }

    private static string Hex(ushort value) => "$" + value.ToString("X4", CultureInfo.InvariantCulture);

    /// <summary>A duration in the kernel's words where they are exact, else the double cell.</summary>
    internal static string Duration(long ticks)
    {
        if (ticks % 200_000 == 0 && ticks / 200_000 <= 21474)
        {
            return $"{ticks / 200_000} msec";
        }

        if (ticks % 200 == 0 && ticks / 200 <= 65535)
        {
            return $"{ticks / 200} us";
        }

        if (ticks * 5 <= 65535)
        {
            return $"{ticks * 5} ns";
        }

        return $"{ticks & 0xFFFF} {ticks >> 16}";
    }
}
