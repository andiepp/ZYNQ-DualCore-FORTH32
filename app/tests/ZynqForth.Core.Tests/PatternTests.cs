using ZynqForth.Board;
using ZynqForth.Patterns;

namespace ZynqForth.Tests;

public class PatternTests
{
    private static Pattern Steps(params long[] ticks)
    {
        var pattern = new Pattern();
        for (int i = 0; i < ticks.Length; i++)
        {
            pattern.Steps.Add(new PatternStep { Levels = (ushort)(i + 1), Ticks = ticks[i] });
        }

        return pattern;
    }

    [Theory]
    [InlineData("100 ns", 20L)]
    [InlineData("2.5us", 500L)]
    [InlineData("2,5 µs", 500L)]
    [InlineData("1 ms", 200_000L)]
    [InlineData("1.5 s", 300_000_000L)]
    [InlineData("7", 1L)]
    [InlineData("21 s", 4_200_000_000L)]
    public void DurationsParse(string text, long ticks) => Assert.Equal(ticks, Durations.Parse(text));

    [Theory]
    [InlineData("2 ns")]
    [InlineData("abc")]
    [InlineData("-1 us")]
    [InlineData("30 s")]
    public void DurationsRefuse(string text) => Assert.Null(Durations.Parse(text));

    [Theory]
    [InlineData(1L, "5 ns")]
    [InlineData(200L, "1 µs")]
    [InlineData(250L, "1.25 µs")]
    [InlineData(200_000L, "1 ms")]
    [InlineData(300_000_000L, "1.5 s")]
    public void DurationsFormat(long ticks, string text) => Assert.Equal(text, Durations.Format(ticks));

    [Theory]
    [InlineData(20L, "100 ns")]
    [InlineData(13107L, "65535 ns")]
    [InlineData(13108L, "13108 0")]
    [InlineData(200L, "1 us")]
    [InlineData(200_000L, "1 msec")]
    [InlineData(300_000_000L, "1500 msec")]
    [InlineData(4_294_967_295L, "65535 65535")]
    public void ForthDurations(long ticks, string text) => Assert.Equal(text, PatternCompiler.Duration(ticks));

    [Fact]
    public void DefaultPatternRestartsWithAJump()
    {
        CompiledPattern compiled = PatternCompiler.Compile(Pattern.CreateDefault());
        Assert.True(compiled.Ok);
        Assert.Empty(compiled.Warnings);
        Assert.Equal(16, compiled.Steps.Count);
        Assert.Equal(new HardwareStep(15, 200, StepOp.Jump, 0, 0), compiled.Steps[^1]);
    }

    [Fact]
    public void RepeatsBecomeLoopsAndStopAddsAnEndStep()
    {
        Pattern pattern = Steps(3, 3, 3, 3, 3, 3);
        pattern.Idle = 0x8000;
        pattern.Repeats.Add(new PatternRepeat(1, 2, 3));
        pattern.Repeats.Add(new PatternRepeat(0, 3, 2));
        CompiledPattern compiled = PatternCompiler.Compile(pattern);

        Assert.True(compiled.Ok, string.Join(" ", compiled.Errors));
        Assert.Equal(7, compiled.Steps.Count);
        Assert.Equal(new HardwareStep(3, 3, StepOp.Loop, 1, 3), compiled.Steps[2]);
        Assert.Equal(new HardwareStep(4, 3, StepOp.Loop, 0, 2), compiled.Steps[3]);
        Assert.Equal(StepOp.Step, compiled.Steps[4].Op);
        Assert.Equal(new HardwareStep(0x8000, 1, StepOp.End, 0, 0), compiled.Steps[6]);
    }

    [Fact]
    public void BadRepeatsAreErrors()
    {
        Pattern overlap = Steps(9, 9, 9, 9);
        overlap.Repeats.AddRange([new PatternRepeat(0, 2, 2), new PatternRepeat(1, 3, 2)]);
        Assert.Contains(PatternCompiler.Compile(overlap).Errors, e => e.Contains("overlap"));

        Pattern sameEnd = Steps(9, 9, 9, 9);
        sameEnd.Repeats.AddRange([new PatternRepeat(0, 3, 2), new PatternRepeat(2, 3, 2)]);
        Assert.Contains(PatternCompiler.Compile(sameEnd).Errors, e => e.Contains("end on step 3"));

        Pattern deep = Steps(9, 9, 9, 9, 9, 9, 9, 9, 9, 9);
        for (int i = 0; i < 5; i++)
        {
            deep.Repeats.Add(new PatternRepeat(4 - i, 5 + i, 2));
        }

        Assert.Contains(PatternCompiler.Compile(deep).Errors, e => e.Contains("nested 5 deep"));

        Pattern waitEnd = Steps(9, 9);
        waitEnd.Steps[1].Wait = true;
        waitEnd.Repeats.Add(new PatternRepeat(0, 1, 2));
        Assert.Contains(PatternCompiler.Compile(waitEnd).Errors, e => e.Contains("waits for the trigger and ends a repeat"));
    }

    [Fact]
    public void RestartNeedsAPlainLastStepOutsideRepeats()
    {
        Pattern pattern = Steps(9, 9, 9, 9);
        pattern.End = PatternEnd.Restart;
        pattern.Repeats.Add(new PatternRepeat(1, 3, 2));
        Assert.Contains(PatternCompiler.Compile(pattern).Errors, e => e.Contains("add a step after it"));

        pattern.Repeats[0] = new PatternRepeat(0, 2, 2);
        pattern.RestartAt = 1;
        Assert.Contains(PatternCompiler.Compile(pattern).Errors, e => e.Contains("inside a repeat"));

        pattern.RestartAt = 0;
        Assert.True(PatternCompiler.Compile(pattern).Ok);
    }

    [Fact]
    public void TooManyStepsWithTheEndStep()
    {
        var pattern = new Pattern();
        pattern.Steps.AddRange(Enumerable.Range(0, Pattern.MaxSteps).Select(_ => new PatternStep { Ticks = 2 }));
        Assert.Contains(PatternCompiler.Compile(pattern).Errors, e => e.Contains("4097 steps"));
        pattern.End = PatternEnd.Restart;
        Assert.True(PatternCompiler.Compile(pattern).Ok);
    }

    [Fact]
    public void WarningsForTimingTriggerAndChannels()
    {
        Pattern pattern = Steps(1, 1, 5);
        pattern.Repeats.Add(new PatternRepeat(0, 1, 10));
        pattern.Steps[2].Wait = true;
        pattern.Steps[2].Levels = 0x0004;
        pattern.Enabled = 0x0003;
        CompiledPattern compiled = PatternCompiler.Compile(pattern);

        Assert.True(compiled.Ok);
        Assert.Contains(compiled.Warnings, w => w.Contains("may run late"));
        Assert.Contains(compiled.Warnings, w => w.Contains("software trigger"));
        Assert.Contains(compiled.Warnings, w => w.Contains("Channel(s) 2"));
    }

    [Fact]
    public void ForthLoadsAndStarts()
    {
        Pattern pattern = Steps(20, 200);
        pattern.Steps[0].Wait = true;
        pattern.Enabled = 0x0003;
        pattern.TriggerSource = 48;
        pattern.Repeats.Add(new PatternRepeat(1, 1, 0));
        string forth = PatternCompiler.ToForth(pattern, PatternCompiler.Compile(pattern), "demo");

        string[] lines = forth.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(
            [
                @"\ ZYNQ-FORTH pattern: demo, 3 steps",
                "decimal pg-stop",
                "$0003 pg-enable $0000 pg-idle",
                "48 1 pg-trigger 0 pg-at",
                "$0001 100 ns pg-wait",
                "$0002 1 us 1 0 pg-loop",
                "$0000 pg-end",
                "pg-start",
            ], lines);
        Assert.All(lines, l => Assert.True(l.Length <= PatternCompiler.MaxLine));
    }

    [Fact]
    public void ForthRefusesAPatternWithErrors() =>
        Assert.Throws<InvalidOperationException>(() =>
            PatternCompiler.ToForth(new Pattern(), PatternCompiler.Compile(new Pattern())));

    [Fact]
    public void FileRoundTrip()
    {
        Pattern pattern = Steps(5, 7);
        pattern.ChannelNames[3] = "CLK";
        pattern.Repeats.Add(new PatternRepeat(0, 1, 4));
        pattern.TriggerEdge = TriggerEdge.Falling;
        pattern.End = PatternEnd.Restart;

        Pattern back = Pattern.FromJson(pattern.ToJson());
        Assert.Equal("CLK", back.ChannelNames[3]);
        Assert.Equal(16, back.ChannelNames.Length);
        Assert.Equal([5L, 7L], back.Steps.Select(s => s.Ticks));
        Assert.Equal(new PatternRepeat(0, 1, 4), Assert.Single(back.Repeats));
        Assert.Equal(TriggerEdge.Falling, back.TriggerEdge);
        Assert.Equal(PatternEnd.Restart, back.End);
        Assert.Contains("\"triggerEdge\": \"falling\"", pattern.ToJson());
        Assert.Throws<FormatException>(() => Pattern.FromJson("{\"format\": \"other\"}"));
    }

    [Fact]
    public void ExamplePatternsCompile()
    {
        string? dir = AppContext.BaseDirectory;
        while (dir is not null && !Directory.Exists(Path.Combine(dir, "examples", "patterns")))
        {
            dir = Path.GetDirectoryName(dir);
        }

        Assert.NotNull(dir);
        string[] files = Directory.GetFiles(Path.Combine(dir, "examples", "patterns"), "*.pattern");
        Assert.NotEmpty(files);
        foreach (string file in files)
        {
            CompiledPattern compiled = PatternCompiler.Compile(Pattern.FromJson(File.ReadAllText(file)));
            Assert.True(compiled.Ok, $"{Path.GetFileName(file)}: {string.Join(" ", compiled.Errors)}");
            Assert.Empty(compiled.Warnings);
        }
    }

    [Fact]
    public void BoardAnswerCarriesThePatternGenerator()
    {
        string xadc = string.Join(' ', Enumerable.Repeat("0000", 32));
        string text = $"board 00000000\nports 00000000 00000000 00000000\npwm 00000000\nxadc {xadc}\n";
        Assert.Null(BoardState.Parse(text).Pattern);

        PatternStatus? pg = BoardState.Parse(text + "pg 00050013 FFFF0005\n").Pattern;
        Assert.NotNull(pg);
        Assert.Equal(5, pg.Step);
        Assert.True(pg.Running);
        Assert.True(pg.Waiting);
        Assert.True(pg.Late);
        Assert.Equal(0xFFFF, pg.Enabled);
        Assert.Equal(5, pg.Levels);
        Assert.Equal("waiting for the trigger · step 5 · late", pg.Summary);
    }
}
