using System.IO;
using System.Windows;
using System.Windows.Threading;
using ZynqForth.Board;
using ZynqForth.Protocol;
using ZynqForth.Simulation;
using ZynqForth.Themes;

namespace ZynqForth.ViewModels;

/// <summary>
/// The window's state: the connection, the two cores (one shown at a time, chosen with
/// <see cref="SelectedCore"/>), and what the cores share: the board view and the pattern
/// generator.
/// </summary>
public sealed class MainViewModel : ObservableObject
{
    public const string ProductName = "ZYNQ-DualCore-FORTH32";

    /// <summary>The cores the app shows; single-core firmware has core 0 only.</summary>
    public const int CoreCount = 2;

    private static readonly string[] DefiningWords =
        [":", "create", "variable", "constant", "fvariable", "fconstant", "forget", "immediate", "marker"];

    private readonly Preferences preferences;
    private readonly DispatcherTimer flushTimer;
    private readonly DispatcherTimer statusTimer;
    private readonly DispatcherTimer boardTimer;
    private readonly DispatcherTimer afterLineTimer;

    private ForthLink? link;
    private BoardClient? client;
    private string? selectedPort;
    private string selectedSkin;
    private CoreViewModel selectedCore;
    private bool showBoard;
    private bool showPattern;
    private bool isConnected;
    private int busyCount;
    private bool polling;
    private bool boardPolling;
    private int lastLineCore;
    private string connectionText = "Not connected";
    private string connectionDetails = "";
    private string statusText = "Choose the board's port (or SIM, the simulated board) and connect.";
    private bool statusIsError;
    private BoardState? board;
    private double progress;

    public MainViewModel(Preferences preferences)
    {
        this.preferences = preferences;
        selectedSkin = Skins.Normalize(preferences["skin"]);
        showBoard = preferences["board"] is { } b ? b == "on" : Skins.ShowsBoard(selectedSkin);
        showPattern = preferences["editor"] == "pattern";

        Cores = [.. Enumerable.Range(0, CoreCount).Select(i => new CoreViewModel(i))];
        foreach (CoreViewModel core in Cores)
        {
            core.Editor.Message += SetStatus;
            core.AutostartChanged += (c, on) => _ = SetAutostartAsync(c, on);
        }

        int remembered = int.TryParse(preferences["core"], out int n) && n >= 0 && n < CoreCount ? n : 0;
        selectedCore = Cores[remembered];
        selectedCore.IsSelected = true;
        Patterns.Message += SetStatus;

        RefreshPortsCommand = new RelayCommand(RefreshPorts);
        ConnectCommand = new RelayCommand(() => _ = ToggleConnectionAsync(), () => IsConnected || SelectedPort is not null);
        SelectCoreCommand = new RelayCommand(p => SelectCore(p is int i ? i : int.TryParse(p as string, out int k) ? k : 0));
        RestartCommand = new RelayCommand(p => _ = RestartAsync(SelectedCore, p as string == "skip"), _ => CanTalk);
        SendInputCommand = new RelayCommand(() => _ = SendInputAsync(SelectedCore), () => CoreReachable);
        RunEditorCommand = new RelayCommand(p => _ = RunTextAsync(SelectedCore, p as string ?? SelectedCore.Editor.Text), _ => CanTalk);
        RefreshWordsCommand = new RelayCommand(() => _ = Guard(c => RefreshWordsCoreAsync(c, SelectedCore)), () => CanTalk);
        RefreshStackCommand = new RelayCommand(() => _ = Guard(c => RefreshStackCoreAsync(c, SelectedCore)), () => CanTalk);
        StoreSourceCommand = new RelayCommand(() => _ = StoreSourceAsync(SelectedCore), () => CanTalk);
        LoadSourceCommand = new RelayCommand(() => _ = LoadSourceAsync(SelectedCore), () => CanTalk && SelectedCore.SourceStored);
        EraseSourceCommand = new RelayCommand(() => _ = EraseSourceAsync(SelectedCore), () => CanTalk && SelectedCore.SourceStored);
        InsertWordCommand = new RelayCommand(p =>
        {
            if (p is ForthWord w)
            {
                SelectedCore.InputLine = (SelectedCore.InputLine + " " + w.Name).TrimStart();
            }
        });
        PatternLoadCommand = new RelayCommand(() => { if (Patterns.ToForth(start: true) is { } forth) { _ = RunTextAsync(SelectedCore, forth); } },
                                              () => CanTalk && !Patterns.HasErrors);
        PatternStartCommand = new RelayCommand(() => _ = SendLineAsync(SelectedCore, "pg-start"), () => CoreReachable);
        PatternStopCommand = new RelayCommand(() => _ = SendLineAsync(SelectedCore, "pg-stop"), () => CoreReachable);
        PatternToEditorCommand = new RelayCommand(PatternToEditor, () => !Patterns.HasErrors);

        flushTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(40), DispatcherPriority.Background, (_, _) => FlushTerminals(),
                                         Dispatcher.CurrentDispatcher);
        statusTimer = new DispatcherTimer(TimeSpan.FromSeconds(1.5), DispatcherPriority.Background, (_, _) => _ = PollStatusAsync(),
                                          Dispatcher.CurrentDispatcher) { IsEnabled = false };
        boardTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(250), DispatcherPriority.Background, (_, _) => _ = PollBoardAsync(),
                                         Dispatcher.CurrentDispatcher) { IsEnabled = false };
        afterLineTimer = new DispatcherTimer(TimeSpan.FromMilliseconds(350), DispatcherPriority.Background, (_, _) => AfterLine(),
                                             Dispatcher.CurrentDispatcher) { IsEnabled = false };

        RefreshPorts();
        string? port = preferences["port"];
        SelectedPort = port is not null && Ports.Contains(port) ? port : DefaultPort();
    }

    /// <summary>Forth's output of one core, cleaned for display, on the UI thread.</summary>
    public event Action<int, string>? TerminalText;

    public IReadOnlyList<CoreViewModel> Cores { get; }

    public PatternEditorViewModel Patterns { get; } = new();

    public System.Collections.ObjectModel.ObservableCollection<string> Ports { get; } = [];

    public IReadOnlyList<string> SkinNames => Skins.Names;

    public RelayCommand RefreshPortsCommand { get; }

    public RelayCommand ConnectCommand { get; }

    public RelayCommand SelectCoreCommand { get; }

    public RelayCommand RestartCommand { get; }

    public RelayCommand SendInputCommand { get; }

    public RelayCommand RunEditorCommand { get; }

    public RelayCommand RefreshWordsCommand { get; }

    public RelayCommand RefreshStackCommand { get; }

    public RelayCommand StoreSourceCommand { get; }

    public RelayCommand LoadSourceCommand { get; }

    public RelayCommand EraseSourceCommand { get; }

    public RelayCommand InsertWordCommand { get; }

    public RelayCommand PatternLoadCommand { get; }

    public RelayCommand PatternStartCommand { get; }

    public RelayCommand PatternStopCommand { get; }

    public RelayCommand PatternToEditorCommand { get; }

    public IUserDialogs? Dialogs
    {
        get => Patterns.Dialogs;
        set
        {
            foreach (CoreViewModel core in Cores)
            {
                core.Editor.Dialogs = value;
            }

            Patterns.Dialogs = value;
        }
    }

    /// <summary>The core whose terminal, editor, stacks, dictionary and saved source are shown.</summary>
    public CoreViewModel SelectedCore
    {
        get => selectedCore;
        private set
        {
            CoreViewModel old = selectedCore;
            if (!Set(ref selectedCore, value))
            {
                return;
            }

            old.IsSelected = false;
            value.IsSelected = true;
            preferences["core"] = value.Index.ToString(System.Globalization.CultureInfo.InvariantCulture);
            OnPropertyChanged(nameof(SelectedCoreIndex));
            OnPropertyChanged(nameof(CanTalk));
            OnPropertyChanged(nameof(CoreReachable));
            CommandManagerInvalidate();
        }
    }

    public int SelectedCoreIndex
    {
        get => SelectedCore.Index;
        set => SelectCore(value);
    }

    public bool IsCore0Selected
    {
        get => SelectedCore.Index == 0;
        set { if (value) { SelectCore(0); } }
    }

    public bool IsCore1Selected
    {
        get => SelectedCore.Index == 1;
        set { if (value) { SelectCore(1); } }
    }

    public string? SelectedPort
    {
        get => selectedPort;
        set => Set(ref selectedPort, value);
    }

    public string SelectedSkin
    {
        get => selectedSkin;
        set
        {
            value = Skins.Normalize(value);
            if (!Set(ref selectedSkin, value))
            {
                return;
            }

            preferences["skin"] = value;
            if (Application.Current is { } application)
            {
                Skins.Apply(application, value);
            }

            if (Skins.ShowsBoard(value))
            {
                ShowBoard = true;
            }
        }
    }

    public bool ShowBoard
    {
        get => showBoard;
        set
        {
            if (Set(ref showBoard, value))
            {
                preferences["board"] = value ? "on" : "off";
                UpdateBoardTimer();
            }
        }
    }

    /// <summary>The editor area shows the pattern editor instead of the source.</summary>
    public bool ShowPattern
    {
        get => showPattern;
        set
        {
            if (Set(ref showPattern, value))
            {
                preferences["editor"] = value ? "pattern" : "source";
                OnPropertyChanged(nameof(ShowSource));
                UpdateBoardTimer();
            }
        }
    }

    public bool ShowSource
    {
        get => !showPattern;
        set => ShowPattern = !value;
    }

    public bool IsConnected
    {
        get => isConnected;
        private set
        {
            if (Set(ref isConnected, value))
            {
                OnPropertyChanged(nameof(ConnectLabel));
                OnPropertyChanged(nameof(CanTalk));
                OnPropertyChanged(nameof(CoreReachable));
            }
        }
    }

    /// <summary>The selected core exists on the connected board.</summary>
    public bool CoreReachable => IsConnected && SelectedCore.IsPresent;

    /// <summary>The selected core is reachable and no long operation (store, run) is running.</summary>
    public bool CanTalk => CoreReachable && busyCount == 0;

    public string ConnectLabel => IsConnected ? "Disconnect" : "Connect";

    public string ConnectionText
    {
        get => connectionText;
        private set => Set(ref connectionText, value);
    }

    /// <summary>The connection line's tooltip: protocol and kernel image.</summary>
    public string ConnectionDetails
    {
        get => connectionDetails;
        private set => Set(ref connectionDetails, value);
    }

    public string StatusText
    {
        get => statusText;
        private set => Set(ref statusText, value);
    }

    public bool StatusIsError
    {
        get => statusIsError;
        private set => Set(ref statusIsError, value);
    }

    public BoardState? Board
    {
        get => board;
        private set => Set(ref board, value);
    }

    /// <summary>0..1 while a source is sent, else 0.</summary>
    public double Progress
    {
        get => progress;
        private set => Set(ref progress, value);
    }

    public void SelectCore(int index)
    {
        if (index < 0 || index >= Cores.Count)
        {
            return;
        }

        SelectedCore = Cores[index];
        OnPropertyChanged(nameof(IsCore0Selected));
        OnPropertyChanged(nameof(IsCore1Selected));
    }

    /// <summary>The board is read while it is shown, and for the pattern editor's playing step.</summary>
    private void UpdateBoardTimer() => boardTimer.IsEnabled = (ShowBoard || ShowPattern) && IsConnected;

    // ---------------------------------------------------------------------------------
    // Connection
    // ---------------------------------------------------------------------------------

    public async Task ToggleConnectionAsync()
    {
        if (IsConnected)
        {
            Disconnect("Disconnected.");
            return;
        }

        if (SelectedPort is not { } port)
        {
            return;
        }

        IByteTransport transport = port == SimulatedBoard.PortName ? new SimulatedBoard() : new SerialTransport(port);
        var newLink = new ForthLink(transport);
        newLink.TerminalReceived += OnTerminalBytes;
        newLink.Faulted += exception => Application.Current?.Dispatcher.BeginInvoke(() =>
            Disconnect($"Connection lost: {exception.Message}", error: true));
        try
        {
            newLink.Open();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            newLink.Dispose();
            SetStatus($"Cannot open {port}: {exception.Message}", true);
            return;
        }

        link = newLink;
        client = new BoardClient(newLink);
        IsConnected = true;
        flushTimer.Start();
        try
        {
            BoardVersion version = await client.VersionAsync();
            preferences["port"] = port;
            if (client.Cores >= 2)
            {
                await client.MultiplexAsync(true);
            }

            for (int i = 0; i < Cores.Count; i++)
            {
                Cores[i].IsPresent = i < client.Cores;
                Cores[i].AbsentReason = i < client.Cores ? "" :
                    $"Firmware {version.Firmware} has one Forth core: core {i} needs the dual-core firmware.";
                Cores[i].ForthState = i < client.Cores ? "" : "not on this firmware";
            }

            ConnectionText = $"{port} · {version.Product} {version.Firmware} · " + (client.Cores >= 2 ? $"{client.Cores} cores" : "1 core");
            ConnectionDetails = $"Firmware {version.Product} {version.Firmware}, protocol {version.Protocol}, " +
                                $"kernel image {version.KernelWords} cells (checksum {version.KernelChecksum:X4}), " +
                                (client.Cores >= 2 ? $"{client.Cores} Forth cores" : "one Forth core (single-core firmware)");
            SetStatus("Connected. Type Forth below, or run the editor's text with F5. Core 0 / Core 1 switch the view.", false);
            OnPropertyChanged(nameof(CanTalk));
            OnPropertyChanged(nameof(CoreReachable));
            statusTimer.Start();
            UpdateBoardTimer();
            foreach (CoreViewModel core in Cores.Where(c => c.IsPresent))
            {
                await client.SendLineAsync("", core.Index);    // Forth answers with its prompt
                await RefreshAllAsync(client, core);
            }
        }
        catch (Exception exception) when (exception is LinkException or BoardRefusedException or InvalidOperationException)
        {
            Disconnect($"No {ProductName} answer on {port}. Is the board running the ZYNQ-FPGA-FORTH32 or dual-core firmware?", error: true);
        }
    }

    private void Disconnect(string message, bool error = false)
    {
        statusTimer.Stop();
        boardTimer.Stop();
        afterLineTimer.Stop();
        link?.Dispose();
        link = null;
        client = null;
        IsConnected = false;
        busyCount = 0;
        ConnectionText = "Not connected";
        ConnectionDetails = "";
        foreach (CoreViewModel core in Cores)
        {
            core.Forget("Not connected.");
        }

        OnPropertyChanged(nameof(CanTalk));
        OnPropertyChanged(nameof(CoreReachable));
        Board = null;
        Patterns.PlayingStep = null;
        FlushTerminals();
        SetStatus(message, error);
    }

    private void RefreshPorts()
    {
        string? keep = SelectedPort;
        Ports.Clear();
        foreach (string name in SerialTransport.PortNames())
        {
            Ports.Add(name);
        }

        Ports.Add(SimulatedBoard.PortName);
        SelectedPort = keep is not null && Ports.Contains(keep) ? keep : DefaultPort();
    }

    /// <summary>The last serial port (the board's is usually the newest), else the simulator.</summary>
    private string? DefaultPort() => Ports.LastOrDefault(p => p != SimulatedBoard.PortName) ?? Ports.LastOrDefault();

    // ---------------------------------------------------------------------------------
    // Terminal
    // ---------------------------------------------------------------------------------

    private void OnTerminalBytes(int core, ReadOnlyMemory<byte> bytes)
    {
        if (core >= 0 && core < Cores.Count)
        {
            Cores[core].AppendOutput(bytes.Span);
        }
    }

    private void FlushTerminals()
    {
        foreach (CoreViewModel core in Cores)
        {
            core.FlushTerminal();
        }
    }

    /// <summary>Connects each core's cleaned output to the window's terminal for it.</summary>
    public void AttachTerminals()
    {
        foreach (CoreViewModel core in Cores)
        {
            int index = core.Index;
            core.TerminalText += text => TerminalText?.Invoke(index, text);
        }
    }

    private async Task SendInputAsync(CoreViewModel core)
    {
        if (client is null)
        {
            return;
        }

        string line = core.TakeInputLine();
        await SendLineAsync(core, line);
        string[] tokens = line.ToLowerInvariant().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        core.RefreshWordsAfterLine |= tokens.Any(t => DefiningWords.Contains(t));
        lastLineCore = core.Index;
        afterLineTimer.Stop();
        afterLineTimer.Start();
    }

    private Task SendLineAsync(CoreViewModel core, string line) => Guard(c => c.SendLineAsync(line, core.Index));

    /// <summary>Up/Down in the terminal line of the shown core.</summary>
    public void History(int step) => SelectedCore.History(step);

    private void AfterLine()
    {
        afterLineTimer.Stop();
        CoreViewModel core = Cores[lastLineCore];
        _ = Guard(c => RefreshStackCoreAsync(c, core));
        if (core.RefreshWordsAfterLine)
        {
            core.RefreshWordsAfterLine = false;
            _ = Guard(c => RefreshWordsCoreAsync(c, core));
        }
    }

    // ---------------------------------------------------------------------------------
    // Requests
    // ---------------------------------------------------------------------------------

    private async Task RestartAsync(CoreViewModel core, bool skipAutostart)
    {
        await Guard(async c =>
        {
            await c.RestartAsync(skipAutostart, core.Index);
            SetStatus($"{core.Name}: Forth restarted" + (skipAutostart ? " without the saved source." : "."), false);
            await Task.Delay(400);
            await WaitForInputAsync(c, core.Index);
            await RefreshAllAsync(c, core);
        });
    }

    private async Task RunTextAsync(CoreViewModel core, string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        await Guard(async c =>
        {
            int lines = text.Split('\n').Length;
            SetStatus($"Sending {lines} line(s) to {core.Name}…", false);
            await c.SendTextAsync(text, core.Index, new Progress<double>(p => Progress = p));
            await WaitForInputAsync(c, core.Index);
            Progress = 0;
            SetStatus($"Sent {lines} line(s) to {core.Name}.", false);
            await RefreshAllAsync(c, core);
        }, longRunning: true);
        Progress = 0;
    }

    private async Task StoreSourceAsync(CoreViewModel core)
    {
        if (Dialogs is not null && core.SourceStored &&
            !Dialogs.Confirm("Store source", $"Replace the source saved for {core.Name} ({core.SourceSummary}) with the editor's text?"))
        {
            return;
        }

        bool autostart = core.SourceStored ? core.SourceAutostart : core.StoreWithAutostart;
        await Guard(async c =>
        {
            SetStatus($"Writing {core.Name}'s source to the board's flash…", false);
            await c.StoreAsync(core.Editor.Text, autostart, core.Index);
            SetStatus($"{core.Name}'s source saved on the board" + (autostart ? "; it runs at every start." : "."), false);
            core.ShowStatus(await c.StatusAsync(core.Index));
        }, longRunning: true);
    }

    private async Task LoadSourceAsync(CoreViewModel core)
    {
        if (!core.Editor.ConfirmDiscard())
        {
            return;
        }

        await Guard(async c =>
        {
            string? source = await c.SourceAsync(core.Index);
            if (source is null)
            {
                SetStatus($"No source is saved for {core.Name}.", true);
                return;
            }

            core.Editor.Load(source, null);
            SetStatus($"Loaded {core.Name}'s saved source into its editor.", false);
        });
    }

    private async Task EraseSourceAsync(CoreViewModel core)
    {
        if (Dialogs is not null && !Dialogs.Confirm("Erase source", $"Erase the source saved for {core.Name}?"))
        {
            return;
        }

        await Guard(async c =>
        {
            await c.EraseAsync(core.Index);
            SetStatus($"{core.Name}'s saved source is erased.", false);
            core.ShowStatus(await c.StatusAsync(core.Index));
        }, longRunning: true);
    }

    private async Task SetAutostartAsync(CoreViewModel core, bool on)
    {
        await Guard(async c =>
        {
            await c.AutostartAsync(on, core.Index);
            SetStatus(on ? $"{core.Name}: autostart on, the saved source runs at every start." : $"{core.Name}: autostart off.", false);
            core.ShowStatus(await c.StatusAsync(core.Index));
        }, longRunning: true);
    }

    private static async Task RefreshAllAsync(BoardClient c, CoreViewModel core)
    {
        core.ShowStatus(await c.StatusAsync(core.Index));
        await RefreshWordsCoreAsync(c, core);
        await RefreshStackCoreAsync(c, core);
    }

    private static async Task RefreshWordsCoreAsync(BoardClient c, CoreViewModel core) =>
        core.ShowWords(await c.WordsAsync(core.Index));

    private static async Task RefreshStackCoreAsync(BoardClient c, CoreViewModel core)
    {
        try
        {
            core.ShowStack(await c.StackAsync(core.Index));
        }
        catch (BoardRefusedException)
        {
            // busy: Forth is between two lines; the next refresh catches it
        }
    }

    private async Task PollStatusAsync()
    {
        if (polling || client is null || busyCount > 0)
        {
            return;
        }

        polling = true;
        try
        {
            foreach (CoreViewModel core in Cores.Where(c => c.IsPresent))
            {
                try
                {
                    core.ShowStatus(await client.StatusAsync(core.Index));
                }
                catch (Exception exception) when (exception is LinkException or BoardRefusedException)
                {
                    core.ForthState = "no answer";
                }

                if (client is null)
                {
                    break;
                }
            }
        }
        finally
        {
            polling = false;
        }
    }

    private async Task PollBoardAsync()
    {
        if (boardPolling || client is null || busyCount > 0)
        {
            return;
        }

        boardPolling = true;
        try
        {
            Board = await client.BoardAsync();
            Patterns.PlayingStep = Board.Pattern is { Running: true } pg ? pg.Step : null;
        }
        catch (Exception exception) when (exception is LinkException or BoardRefusedException or FormatException or KeyNotFoundException)
        {
        }
        finally
        {
            boardPolling = false;
        }
    }

    /// <summary>Waits until the core's Forth has read everything queued for it (at most a minute).</summary>
    private static async Task WaitForInputAsync(BoardClient c, int core)
    {
        for (int i = 0; i < 600; i++)
        {
            if ((await c.StatusAsync(core)).InputPending == 0)
            {
                return;
            }

            await Task.Delay(100);
        }
    }

    /// <summary>Runs a request sequence, reporting failures in the status line.</summary>
    private async Task Guard(Func<BoardClient, Task> action, bool longRunning = false)
    {
        if (client is not { } c)
        {
            return;
        }

        if (longRunning)
        {
            busyCount++;
            OnPropertyChanged(nameof(CanTalk));
        }

        try
        {
            await action(c);
        }
        catch (Exception exception) when (exception is LinkException or BoardRefusedException or ArgumentException)
        {
            SetStatus(exception.Message, true);
        }
        finally
        {
            if (longRunning && busyCount > 0)
            {
                busyCount--;
                OnPropertyChanged(nameof(CanTalk));
            }

            CommandManagerInvalidate();
        }
    }

    /// <summary>The pattern's Forth into the shown core's source editor (appended when it holds text).</summary>
    private void PatternToEditor()
    {
        if (Patterns.ToForth(start: true) is not { } forth)
        {
            return;
        }

        EditorViewModel editor = SelectedCore.Editor;
        if (string.IsNullOrWhiteSpace(editor.Text))
        {
            editor.Load(forth, null);
        }
        else
        {
            editor.Text = editor.Text.TrimEnd() + Environment.NewLine + Environment.NewLine + forth;
        }

        ShowPattern = false;
        SetStatus($"The pattern is in {SelectedCore.Name}'s source editor as Forth: Run all loads it, Store editor saves it on the board.", false);
    }

    private void SetStatus(string message, bool error)
    {
        StatusText = message;
        StatusIsError = error;
    }

    private static void CommandManagerInvalidate() => System.Windows.Input.CommandManager.InvalidateRequerySuggested();

    public void Shutdown()
    {
        if (IsConnected)
        {
            Disconnect("Closed.");
        }
    }
}
