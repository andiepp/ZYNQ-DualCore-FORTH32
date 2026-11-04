using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Text;
using System.Windows.Data;
using ZynqForth.Board;

namespace ZynqForth.ViewModels;

/// <summary>One data stack item, top of stack first in the list.</summary>
public sealed record StackItem(int Position, int Signed, uint Raw)
{
    public string Hex => "$" + Raw.ToString("X8");
}

/// <summary>One float stack item (IEEE single), top of stack first in the list.</summary>
public sealed record FloatItem(int Position, uint Raw)
{
    public string Value => FloatText.Format(BitConverter.UInt32BitsToSingle(Raw));

    public string Hex => "$" + Raw.ToString("X8");
}

/// <summary>
/// Everything that belongs to one HF32 core: its terminal, its source editor, its stacks,
/// its dictionary and its saved source. The board view and the pattern editor are shared and
/// live in <see cref="MainViewModel"/>.
/// </summary>
public sealed class CoreViewModel : ObservableObject
{
    private readonly Lock terminalLock = new();
    private readonly StringBuilder terminalPending = new();
    private readonly List<string> history = [];
    private readonly List<ForthWord> allWords = [];

    private bool isPresent;
    private bool isSelected;
    private bool hasUnread;
    private int historyIndex;
    private string inputLine = "";
    private string forthState = "";
    private string sourceSummary = "";
    private bool sourceStored;
    private bool sourceAutostart;
    private string wordFilter = "";
    private string wordsSummary = "";
    private string stackSummary = "";
    private string floatStackSummary = "";
    private string absentReason = "Not connected.";

    public CoreViewModel(int index)
    {
        Index = index;
        Words = CollectionViewSource.GetDefaultView(allWords);
        Words.Filter = item => item is ForthWord word &&
                               (WordFilter.Length == 0 || word.Name.Contains(WordFilter, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Forth's output, cleaned for display, on the UI thread.</summary>
    public event Action<string>? TerminalText;

    /// <summary>The user switched the autostart check box; the main view model writes the flash.</summary>
    public event Action<CoreViewModel, bool>? AutostartChanged;

    public int Index { get; }

    public string Name => $"Core {Index}";

    public EditorViewModel Editor { get; } = new();

    public ICollectionView Words { get; }

    public ObservableCollection<StackItem> Stack { get; } = [];

    public ObservableCollection<FloatItem> FloatStack { get; } = [];

    /// <summary>The connected board has this core (always false while not connected).</summary>
    public bool IsPresent
    {
        get => isPresent;
        set
        {
            if (Set(ref isPresent, value))
            {
                OnPropertyChanged(nameof(TabLabel));
            }
        }
    }

    /// <summary>Why the core cannot be talked to, shown in its terminal header.</summary>
    public string AbsentReason
    {
        get => absentReason;
        set => Set(ref absentReason, value);
    }

    public bool IsSelected
    {
        get => isSelected;
        set
        {
            if (Set(ref isSelected, value) && value)
            {
                HasUnread = false;
            }
        }
    }

    /// <summary>The core printed something while another core was shown.</summary>
    public bool HasUnread
    {
        get => hasUnread;
        private set
        {
            if (Set(ref hasUnread, value))
            {
                OnPropertyChanged(nameof(TabLabel));
            }
        }
    }

    /// <summary>"Core 1", with a dot for unread output, a dash when the board has no such core.</summary>
    public string TabLabel => Name + (HasUnread ? " •" : "");

    public string InputLine
    {
        get => inputLine;
        set => Set(ref inputLine, value);
    }

    public string ForthState
    {
        get => forthState;
        set => Set(ref forthState, value);
    }

    public string SourceSummary
    {
        get => sourceSummary;
        private set => Set(ref sourceSummary, value);
    }

    public bool SourceStored
    {
        get => sourceStored;
        private set => Set(ref sourceStored, value);
    }

    /// <summary>The saved source's autostart flag; setting it writes the flash.</summary>
    public bool SourceAutostart
    {
        get => sourceAutostart;
        set
        {
            if (sourceAutostart == value)
            {
                return;
            }

            sourceAutostart = value;
            OnPropertyChanged();
            AutostartChanged?.Invoke(this, value);
        }
    }

    /// <summary>Autostart for the next Store (when no source is stored yet).</summary>
    public bool StoreWithAutostart { get; set; } = true;

    public string WordFilter
    {
        get => wordFilter;
        set
        {
            if (Set(ref wordFilter, value ?? ""))
            {
                Words.Refresh();
            }
        }
    }

    public string WordsSummary
    {
        get => wordsSummary;
        private set => Set(ref wordsSummary, value);
    }

    public string StackSummary
    {
        get => stackSummary;
        private set => Set(ref stackSummary, value);
    }

    public string FloatStackSummary
    {
        get => floatStackSummary;
        private set => Set(ref floatStackSummary, value);
    }

    /// <summary>A line defined something: the dictionary is read again after it.</summary>
    public bool RefreshWordsAfterLine { get; set; }

    // ---------------------------------------------------------------------------------
    // Terminal
    // ---------------------------------------------------------------------------------

    /// <summary>Output bytes of this core, on the transport's reader thread.</summary>
    public void AppendOutput(ReadOnlySpan<byte> bytes)
    {
        lock (terminalLock)
        {
            foreach (byte b in bytes)
            {
                switch (b)
                {
                    case (byte)'\n':
                    case (byte)'\t':
                        terminalPending.Append((char)b);
                        break;
                    case 8 or 127:
                        if (terminalPending.Length > 0)
                        {
                            terminalPending.Length--;
                        }

                        break;
                    case >= 32 and < 127:
                        terminalPending.Append((char)b);
                        break;
                    default:
                        break;      // CR and other control characters
                }
            }
        }
    }

    /// <summary>Hands the collected output to the window (UI thread).</summary>
    public void FlushTerminal()
    {
        string text;
        lock (terminalLock)
        {
            if (terminalPending.Length == 0)
            {
                return;
            }

            text = terminalPending.ToString();
            terminalPending.Clear();
        }

        if (!IsSelected && text.Trim().Length > 0)
        {
            HasUnread = true;
        }

        TerminalText?.Invoke(text);
    }

    /// <summary>Takes the typed line for sending and keeps it in the history.</summary>
    public string TakeInputLine()
    {
        string line = InputLine;
        if (line.Length > 0 && (history.Count == 0 || history[^1] != line))
        {
            history.Add(line);
        }

        historyIndex = history.Count;
        InputLine = "";
        return line;
    }

    /// <summary>Steps through the typed lines (Up = -1, Down = +1).</summary>
    public void History(int step)
    {
        if (history.Count == 0)
        {
            return;
        }

        historyIndex = Math.Clamp(historyIndex + step, 0, history.Count);
        InputLine = historyIndex < history.Count ? history[historyIndex] : "";
    }

    // ---------------------------------------------------------------------------------
    // Answers
    // ---------------------------------------------------------------------------------

    public void ShowStatus(BoardStatus status)
    {
        ForthState = (status.Running ? "running" : "held") +
                     (status.InputPending > 0 ? $" · {status.InputPending} bytes queued" : "") +
                     (status.Mailbox is > 0 ? $" · {status.Mailbox} in mailbox" : "") +
                     $" · starts {status.Starts}";
        SourceStored = status.Source == SourceState.Stored;
        sourceAutostart = status.Autostart;
        OnPropertyChanged(nameof(SourceAutostart));
        SourceSummary = status.Source switch
        {
            SourceState.Stored => $"{status.SourceLength} bytes, CRC {status.SourceCrc:X8}",
            SourceState.Damaged => "damaged (CRC mismatch)",
            _ => "none",
        };
    }

    public void ShowWords(WordList list)
    {
        allWords.Clear();
        allWords.AddRange(list.Words.Where(w => !w.Hidden));
        Words.Refresh();
        WordsSummary = $"{allWords.Count} words · HERE ${list.Here:X5}";
    }

    public void ShowStack(DataStack stack)
    {
        Stack.Clear();
        for (int i = stack.Items.Count - 1; i >= 0; i--)
        {
            uint raw = stack.Items[i];
            Stack.Add(new StackItem(stack.Items.Count - 1 - i, unchecked((int)raw), raw));
        }

        StackSummary = stack.Items.Count == 0 ? "empty" : $"depth {stack.Items.Count}, top first";

        FloatStack.Clear();
        for (int i = stack.Floats.Count - 1; i >= 0; i--)
        {
            FloatStack.Add(new FloatItem(stack.Floats.Count - 1 - i, stack.Floats[i]));
        }

        FloatStackSummary = stack.Floats.Count == 0 ? "empty" : $"depth {stack.Floats.Count}";
    }

    /// <summary>Forgets the board's state (disconnect); the editor and the terminal text stay.</summary>
    public void Forget(string reason)
    {
        IsPresent = false;
        AbsentReason = reason;
        ForthState = "";
        RefreshWordsAfterLine = false;
        SourceStored = false;
        sourceAutostart = false;
        OnPropertyChanged(nameof(SourceAutostart));
        SourceSummary = "";
    }
}
