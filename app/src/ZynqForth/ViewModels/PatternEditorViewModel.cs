using System.Collections.ObjectModel;
using System.IO;
using System.Text;
using ZynqForth.Patterns;

namespace ZynqForth.ViewModels;

/// <summary>One channel row beside the timing diagram: enabled, name, idle level.</summary>
public sealed class ChannelItem(PatternEditorViewModel owner, int index) : ObservableObject
{
    public int Index { get; } = index;

    public string Name
    {
        get => owner.Pattern.ChannelNames[Index];
        set
        {
            if (owner.Pattern.ChannelNames[Index] != value)
            {
                owner.Change(p => p.ChannelNames[Index] = value);
            }
        }
    }

    public bool Enabled
    {
        get => (owner.Pattern.Enabled & (1 << Index)) != 0;
        set => owner.Change(p => p.Enabled = (ushort)(value ? p.Enabled | (1 << Index) : p.Enabled & ~(1 << Index)));
    }

    public bool Idle
    {
        get => (owner.Pattern.Idle & (1 << Index)) != 0;
        set => owner.Change(p => p.Idle = (ushort)(value ? p.Idle | (1 << Index) : p.Idle & ~(1 << Index)));
    }

    internal void Refresh()
    {
        OnPropertyChanged(nameof(Name));
        OnPropertyChanged(nameof(Enabled));
        OnPropertyChanged(nameof(Idle));
    }
}

/// <summary>
/// The pattern editor: the pattern, its file, the selected steps and the editing commands.
/// The timing diagram (Controls/PatternView) draws it and calls back for clicks; the main view
/// model loads it into the board.
/// </summary>
public sealed class PatternEditorViewModel : ObservableObject
{
    public const string Filter = "ZYNQ-FORTH pattern (*.pattern)|*.pattern|All files (*.*)|*.*";

    private const int UndoDepth = 100;

    private readonly List<string> undo = [];
    private string? filePath;
    private bool isModified;
    private int selFirst = -1;
    private int selLast = -1;
    private string durationText = "";
    private string repeatText = "2";
    private string restartText = "0";
    private int? playingStep;
    private CompiledPattern compiled;

    public PatternEditorViewModel()
    {
        Pattern = Pattern.CreateDefault();
        compiled = PatternCompiler.Compile(Pattern);
        Channels = [.. Enumerable.Range(0, Pattern.ChannelCount).Select(c => new ChannelItem(this, c))];

        NewCommand = new RelayCommand(() => { if (ConfirmDiscard()) { Replace(Pattern.CreateDefault(), null); } });
        OpenCommand = new RelayCommand(Open);
        SaveCommand = new RelayCommand(() => Save());
        SaveAsCommand = new RelayCommand(() => SaveAs());
        InsertCommand = new RelayCommand(Insert);
        DuplicateCommand = new RelayCommand(Duplicate, () => HasSelection);
        DeleteCommand = new RelayCommand(Delete, () => HasSelection && SelectionCount < Pattern.Steps.Count);
        ApplyDurationCommand = new RelayCommand(ApplyDuration, () => HasSelection);
        WaitCommand = new RelayCommand(ToggleWait, () => HasSelection);
        RepeatCommand = new RelayCommand(AddRepeat, () => HasSelection);
        UnrepeatCommand = new RelayCommand(RemoveRepeats, () => HasSelection);
        UndoCommand = new RelayCommand(Undo, () => undo.Count > 0);
        Select(0, false);
    }

    /// <summary>The pattern or the selection changed: redraw.</summary>
    public event Action? Changed;

    public event Action<string, bool>? Message;

    public IUserDialogs? Dialogs { get; set; }

    public Pattern Pattern { get; private set; }

    public ObservableCollection<ChannelItem> Channels { get; }

    public IReadOnlyList<(int Source, string Name)> TriggerSources => Pattern.TriggerSources;

    public IReadOnlyList<string> TriggerSourceNames { get; } = [.. Pattern.TriggerSources.Select(t => t.Name)];

    public IReadOnlyList<string> EdgeNames { get; } = ["rising edge", "falling edge", "both edges"];

    public IReadOnlyList<string> EndNames { get; } = ["stop (idle levels)", "restart forever"];

    public RelayCommand NewCommand { get; }

    public RelayCommand OpenCommand { get; }

    public RelayCommand SaveCommand { get; }

    public RelayCommand SaveAsCommand { get; }

    public RelayCommand InsertCommand { get; }

    public RelayCommand DuplicateCommand { get; }

    public RelayCommand DeleteCommand { get; }

    public RelayCommand ApplyDurationCommand { get; }

    public RelayCommand WaitCommand { get; }

    public RelayCommand RepeatCommand { get; }

    public RelayCommand UnrepeatCommand { get; }

    public RelayCommand UndoCommand { get; }

    public string Title => (filePath is null ? "untitled.pattern" : Path.GetFileName(filePath)) + (isModified ? " *" : "");

    public string Name => Path.GetFileNameWithoutExtension(filePath ?? "untitled");

    public int SelectionFirst => selFirst;

    public int SelectionLast => selLast;

    public bool HasSelection => selFirst >= 0;

    private int SelectionCount => HasSelection ? selLast - selFirst + 1 : 0;

    public CompiledPattern Compiled => compiled;

    public string Messages => string.Join(Environment.NewLine,
        compiled.Errors.Select(e => "✖ " + e).Concat(compiled.Warnings.Select(w => "⚠ " + w)));

    public bool HasErrors => !compiled.Ok;

    public string Summary
    {
        get
        {
            long ticks = Pattern.Steps.Sum(s => s.Ticks);
            return $"{Pattern.Steps.Count} steps · one pass {Durations.Format(ticks)}" +
                   (HasSelection ? $" · selected {(SelectionCount == 1 ? "step " + selFirst : $"steps {selFirst}–{selLast}")}" : "");
        }
    }

    /// <summary>The duration box: the selected steps' duration (blank when they differ).</summary>
    public string DurationText
    {
        get => durationText;
        set => Set(ref durationText, value);
    }

    /// <summary>The repeat count box: a number, or "forever" / 0.</summary>
    public string RepeatText
    {
        get => repeatText;
        set => Set(ref repeatText, value);
    }

    public int TriggerIndex
    {
        get => Math.Max(0, Pattern.TriggerSources.ToList().FindIndex(t => t.Source == Pattern.TriggerSource));
        set
        {
            if (value >= 0 && value < Pattern.TriggerSources.Count && Pattern.TriggerSources[value].Source != Pattern.TriggerSource)
            {
                Change(p => p.TriggerSource = Pattern.TriggerSources[value].Source);
            }
        }
    }

    public int EdgeIndex
    {
        get => (int)Pattern.TriggerEdge - 1;
        set
        {
            if (value is >= 0 and < 3 && value != (int)Pattern.TriggerEdge - 1)
            {
                Change(p => p.TriggerEdge = (TriggerEdge)(value + 1));
            }
        }
    }

    public int EndIndex
    {
        get => (int)Pattern.End;
        set
        {
            if (value is 0 or 1 && value != (int)Pattern.End)
            {
                Change(p => p.End = (PatternEnd)value);
            }
        }
    }

    public bool Restarts => Pattern.End == PatternEnd.Restart;

    /// <summary>Where the diagram's first channel row starts, for the channel list beside it.</summary>
    public double ChannelsTop => Controls.PatternView.TopOf(Pattern);

    /// <summary>The restart step box.</summary>
    public string RestartText
    {
        get => restartText;
        set
        {
            if (Set(ref restartText, value) && int.TryParse(value, out int at) && at != Pattern.RestartAt)
            {
                Change(p => p.RestartAt = at);
            }
        }
    }

    /// <summary>The step the generator plays, from the board's live view; null when it is not running.</summary>
    public int? PlayingStep
    {
        get => playingStep;
        set
        {
            if (Set(ref playingStep, value))
            {
                Changed?.Invoke();
            }
        }
    }

    // ---------------------------------------------------------------------------------
    // Editing
    // ---------------------------------------------------------------------------------

    /// <summary>Records an undo point, applies the change and refreshes everything.</summary>
    internal void Change(Action<Pattern> change)
    {
        Snapshot();
        change(Pattern);
        Modified();
    }

    /// <summary>An undo point before a gesture of several changes (a drag).</summary>
    public void Snapshot()
    {
        undo.Add(Pattern.ToJson());
        if (undo.Count > UndoDepth)
        {
            undo.RemoveAt(0);
        }
    }

    public bool Level(int step, int channel) => (Pattern.Steps[step].Levels & (1 << channel)) != 0;

    /// <summary>Switches a channel's idle level (the diagram's idle column).</summary>
    public void ToggleIdle(int channel)
    {
        Change(p => p.Idle ^= (ushort)(1 << channel));
        Channels[channel].Refresh();
    }

    /// <summary>Sets one level without an undo point (the view takes one per gesture).</summary>
    public void SetLevel(int step, int channel, bool high)
    {
        PatternStep s = Pattern.Steps[step];
        ushort levels = (ushort)(high ? s.Levels | (1 << channel) : s.Levels & ~(1 << channel));
        if (levels != s.Levels)
        {
            s.Levels = levels;
            Modified();
        }
    }

    /// <summary>Selects a step; with <paramref name="extend"/> from the current first step to it.</summary>
    public void Select(int step, bool extend)
    {
        step = Math.Clamp(step, 0, Pattern.Steps.Count - 1);
        if (extend && HasSelection)
        {
            int anchor = selFirst;
            selFirst = Math.Min(anchor, step);
            selLast = Math.Max(anchor, step);
        }
        else
        {
            selFirst = selLast = step;
        }

        IEnumerable<long> ticks = Pattern.Steps.Skip(selFirst).Take(SelectionCount).Select(s => s.Ticks).Distinct();
        DurationText = ticks.Count() == 1 ? Durations.Format(ticks.First()) : "";
        SelectionChanged();
    }

    private void Insert()
    {
        int at = HasSelection ? selLast + 1 : Pattern.Steps.Count;
        if (Pattern.Steps.Count >= Pattern.MaxSteps)
        {
            Message?.Invoke($"The generator holds at most {Pattern.MaxSteps} steps.", true);
            return;
        }

        PatternStep model = Pattern.Steps.Count == 0 ? new PatternStep() : Pattern.Steps[Math.Max(0, at - 1)];
        Change(p =>
        {
            ShiftRepeats(at, 1);
            p.Steps.Insert(at, new PatternStep { Levels = model.Levels, Ticks = model.Ticks });
        });
        Select(at, false);
    }

    private void Duplicate()
    {
        int at = selLast + 1, count = SelectionCount;
        if (Pattern.Steps.Count + count > Pattern.MaxSteps)
        {
            Message?.Invoke($"The generator holds at most {Pattern.MaxSteps} steps.", true);
            return;
        }

        Change(p =>
        {
            List<PatternStep> copies = [.. p.Steps.Skip(selFirst).Take(count).Select(s => s.Clone())];
            ShiftRepeats(at, count);
            p.Steps.InsertRange(at, copies);
        });
        selFirst = at;
        selLast = at + count - 1;
        SelectionChanged();
    }

    private void Delete()
    {
        int first = selFirst, count = SelectionCount;
        Change(p =>
        {
            p.Steps.RemoveRange(first, count);
            p.Repeats = [.. p.Repeats
                .Where(r => !(r.First >= first && r.Last < first + count))
                .Select(r => new PatternRepeat(Remap(r.First, first, count, true), Remap(r.Last, first, count, false), r.Count))
                .Where(r => r.First <= r.Last)];
            if (p.RestartAt >= p.Steps.Count)
            {
                p.RestartAt = 0;
            }
        });
        restartText = Pattern.RestartAt.ToString();
        OnPropertyChanged(nameof(RestartText));
        Select(Math.Min(first, Pattern.Steps.Count - 1), false);
    }

    /// <summary>A step number after removing <paramref name="count"/> steps at <paramref name="first"/>.</summary>
    private static int Remap(int step, int first, int count, bool isStart) =>
        step < first ? step
        : step >= first + count ? step - count
        : isStart ? first : first - 1;

    private void ShiftRepeats(int at, int count)
    {
        Pattern.Repeats = [.. Pattern.Repeats.Select(r => new PatternRepeat(
            r.First >= at ? r.First + count : r.First, r.Last >= at ? r.Last + count : r.Last, r.Count))];
        if (Pattern.RestartAt >= at && Pattern.RestartAt > 0)
        {
            Pattern.RestartAt += count;
            restartText = Pattern.RestartAt.ToString();
            OnPropertyChanged(nameof(RestartText));
        }
    }

    private void ApplyDuration()
    {
        if (Durations.Parse(DurationText) is not long ticks)
        {
            Message?.Invoke($"'{DurationText}' is no duration: write e.g. 100 ns, 2.5 us, 1 ms (5 ns up to 21.47 s).", true);
            return;
        }

        Change(p =>
        {
            for (int i = selFirst; i <= selLast; i++)
            {
                p.Steps[i].Ticks = ticks;
            }
        });
        DurationText = Durations.Format(ticks);
    }

    private void ToggleWait()
    {
        bool wait = !Pattern.Steps[selFirst].Wait;
        Change(p =>
        {
            for (int i = selFirst; i <= selLast; i++)
            {
                p.Steps[i].Wait = wait;
            }
        });
    }

    private void AddRepeat()
    {
        string text = RepeatText.Trim().ToLowerInvariant();
        int count = text is "forever" or "∞" ? 0 : int.TryParse(text, out int n) ? n : -1;
        if (count is < 0 or > Pattern.MaxCount || count == 1)
        {
            Message?.Invoke($"Repeat count: 2 to {Pattern.MaxCount}, or 0 / forever.", true);
            return;
        }

        int first = selFirst, last = selLast;
        Change(p =>
        {
            p.Repeats.RemoveAll(r => r.First == first && r.Last == last);
            p.Repeats.Add(new PatternRepeat(first, last, count));
        });
    }

    private void RemoveRepeats()
    {
        int first = selFirst, last = selLast;
        if (!Pattern.Repeats.Any(r => r.First >= first && r.Last <= last))
        {
            Message?.Invoke("No repeat lies within the selected steps.", true);
            return;
        }

        Change(p => p.Repeats.RemoveAll(r => r.First >= first && r.Last <= last));
    }

    private void Undo()
    {
        if (undo.Count == 0)
        {
            return;
        }

        string json = undo[^1];
        undo.RemoveAt(undo.Count - 1);
        Pattern = Pattern.FromJson(json);
        isModified = true;
        AfterReplace();
    }

    private void Modified()
    {
        isModified = true;
        compiled = PatternCompiler.Compile(Pattern);
        OnPropertyChanged(nameof(Title));
        OnPropertyChanged(nameof(Messages));
        OnPropertyChanged(nameof(HasErrors));
        OnPropertyChanged(nameof(Summary));
        OnPropertyChanged(nameof(Restarts));
        OnPropertyChanged(nameof(ChannelsTop));
        Changed?.Invoke();
    }

    private void SelectionChanged()
    {
        OnPropertyChanged(nameof(Summary));
        Changed?.Invoke();
        System.Windows.Input.CommandManager.InvalidateRequerySuggested();
    }

    private void Replace(Pattern pattern, string? path)
    {
        Pattern = pattern;
        filePath = path;
        isModified = false;
        undo.Clear();
        AfterReplace();
    }

    private void AfterReplace()
    {
        compiled = PatternCompiler.Compile(Pattern);
        restartText = Pattern.RestartAt.ToString();
        foreach (ChannelItem channel in Channels)
        {
            channel.Refresh();
        }

        foreach (string name in new[] { nameof(Title), nameof(Messages), nameof(HasErrors), nameof(Summary), nameof(Restarts),
                                        nameof(ChannelsTop), nameof(TriggerIndex), nameof(EdgeIndex), nameof(EndIndex), nameof(RestartText) })
        {
            OnPropertyChanged(name);
        }

        Select(0, false);
    }

    // ---------------------------------------------------------------------------------
    // Forth and files
    // ---------------------------------------------------------------------------------

    /// <summary>The Forth that loads the pattern, or null (with a message) when it has errors.</summary>
    public string? ToForth(bool start)
    {
        if (!compiled.Ok)
        {
            Message?.Invoke("The pattern has errors: " + compiled.Errors[0], true);
            return null;
        }

        return PatternCompiler.ToForth(Pattern, compiled, Name, start);
    }

    /// <summary>Asks to save unsaved changes; false when the user cancels.</summary>
    public bool ConfirmDiscard()
    {
        if (!isModified || Dialogs is null)
        {
            return true;
        }

        return Dialogs.YesNoCancel("ZYNQ-DualCore-FORTH32", $"Save the changes to {Title.TrimEnd(' ', '*')}?") switch
        {
            true => Save(),
            false => true,
            null => false,
        };
    }

    public bool Save() => filePath is null ? SaveAs() : WriteTo(filePath);

    public bool SaveAs()
    {
        string? path = Dialogs?.SaveFile("Save pattern", Filter, filePath is null ? "untitled.pattern" : Path.GetFileName(filePath));
        return path is not null && WriteTo(path);
    }

    private void Open()
    {
        if (!ConfirmDiscard())
        {
            return;
        }

        if (Dialogs?.OpenFile("Open pattern", Filter) is { } path)
        {
            OpenFile(path);
        }
    }

    public void OpenFile(string path)
    {
        try
        {
            Replace(Pattern.FromJson(File.ReadAllText(path)), path);
            Message?.Invoke($"Opened {path}", false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or FormatException
                                                      or System.Text.Json.JsonException)
        {
            Message?.Invoke($"Cannot open {path}: {exception.Message}", true);
        }
    }

    private bool WriteTo(string path)
    {
        try
        {
            File.WriteAllText(path, Pattern.ToJson(), new UTF8Encoding(false));
            filePath = path;
            isModified = false;
            OnPropertyChanged(nameof(Title));
            Message?.Invoke($"Saved {path}", false);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            Message?.Invoke($"Cannot save {path}: {exception.Message}", true);
            return false;
        }
    }
}
