using System.Text;
using ZynqForth.Protocol;

namespace ZynqForth.Board;

/// <summary>A service request the board refused (<c>err &lt;name&gt; &lt;reason&gt;</c>).</summary>
public sealed class BoardRefusedException(string request, string reason)
    : Exception($"The board refused '{request}': {reason}.")
{
    public string Reason { get; } = reason;
}

/// <summary>
/// The service requests of docs/Protocol.md as typed calls, plus Forth input. Requests that
/// concern one Forth take its core number; core 0 is the only one on single-core firmware.
/// </summary>
public sealed class BoardClient(ForthLink link)
{
    /// <summary>The largest source the flash sector holds.</summary>
    public const int SourceMax = 65536 - 16;

    /// <summary>What may be queued in the board's input ring before waiting for Forth.</summary>
    private const int InputWindow = 16 * 1024;

    private static readonly TimeSpan FlashTimeout = TimeSpan.FromSeconds(30);

    private readonly SemaphoreSlim inputGate = new(1, 1);
    private int inputCore;      // where the board's terminal input points; -1 = not known yet

    public ForthLink Link { get; } = link ?? throw new ArgumentNullException(nameof(link));

    /// <summary>Lines as Forth expects them: LF, CR LF and CR all become CR; tabs become spaces.</summary>
    public static byte[] ToForthText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        string normal = text.Replace("\r\n", "\r", StringComparison.Ordinal).Replace('\n', '\r').Replace('\t', ' ');
        byte[] bytes = new byte[normal.Length];
        for (int i = 0; i < normal.Length; i++)
        {
            char c = normal[i];
            bytes[i] = c is '\r' or (>= ' ' and <= '~') ? (byte)c : (byte)'?';
        }

        return bytes;
    }

    /// <summary>The stored form back as editor text, CR line ends become CR LF.</summary>
    public static string FromForthText(byte[] bytes) =>
        Encoding.ASCII.GetString(bytes).Replace("\r\n", "\r", StringComparison.Ordinal)
                                        .Replace("\n", "\r", StringComparison.Ordinal)
                                        .Replace("\r", Environment.NewLine, StringComparison.Ordinal);

    /// <summary>The number of Forth cores: 1 until <see cref="VersionAsync"/> found the dual-core firmware.</summary>
    public int Cores { get; private set; } = 1;

    /// <summary>Asks for the version and learns from it how many cores the board has.</summary>
    public async Task<BoardVersion> VersionAsync()
    {
        BoardVersion version = BoardVersion.Parse(await TextAsync("version"));
        Cores = version.IsDualCore ? version.Cores : 1;
        inputCore = Cores == 1 ? 0 : -1;
        return version;
    }

    public async Task<BoardStatus> StatusAsync(int core = 0) => BoardStatus.Parse(await TextAsync(Addressed("status", core)));

    public async Task<WordList> WordsAsync(int core = 0) => WordList.Parse(await TextAsync(Addressed("words", core)));

    public async Task<DataStack> StackAsync(int core = 0) => DataStack.Parse(await TextAsync(Addressed("stack", core)));

    /// <summary>The I/O is shared by the cores: one answer for the whole board.</summary>
    public async Task<BoardState> BoardAsync() => BoardState.Parse(await TextAsync("board"));

    public async Task<bool> EchoAsync(string word) => await TextAsync("echo " + word) == word;

    public Task RestartAsync(bool skipAutostart, int core = 0) =>
        TextAsync(Addressed(skipAutostart ? "restart skip" : "restart", core));

    /// <summary>
    /// Terminal multiplexing (protocol 3): on, the board sends every core's output, each run
    /// after a core marker; off, only core 0's, as a terminal program expects.
    /// </summary>
    public Task MultiplexAsync(bool on)
    {
        RequireDualCore();
        return TextAsync(on ? "mux on" : "mux off");
    }

    /// <summary>The saved source, or null when none is stored.</summary>
    public async Task<string?> SourceAsync(int core = 0)
    {
        Answer answer = await Link.RequestAsync(Addressed("source", core), timeout: TimeSpan.FromSeconds(15));
        if (!answer.Ok)
        {
            return answer.Reason == "none" ? null : throw new BoardRefusedException("source", answer.Reason);
        }

        return FromForthText(answer.Payload);
    }

    /// <summary>Saves the source in the core's flash sector (CR line ends, a final CR added).</summary>
    public async Task StoreAsync(string source, bool autostart, int core = 0)
    {
        byte[] text = ToForthText(source);
        if (text.Length > 0 && text[^1] != '\r')
        {
            text = [.. text, (byte)'\r'];
        }

        if (text.Length > SourceMax)
        {
            throw new ArgumentException($"The source has {text.Length} bytes; the board keeps at most {SourceMax}.");
        }

        await TextAsync(Addressed($"store {text.Length} {Crc32.Compute(text):X8} {(autostart ? "on" : "off")}", core), text, FlashTimeout);
    }

    public Task EraseAsync(int core = 0) => TextAsync(Addressed("erase", core), timeout: FlashTimeout);

    public Task AutostartAsync(bool on, int core = 0) =>
        TextAsync(Addressed(on ? "autostart on" : "autostart off", core), timeout: FlashTimeout);

    /// <summary>One terminal line for the core; CR ends it.</summary>
    public Task SendLineAsync(string line, int core = 0) => SendTerminalAsync([.. ToForthText(line), (byte)'\r'], core);

    /// <summary>
    /// Terminal bytes for one core. With two cores the board's input is pointed at the core
    /// first (<c>input n</c>) when it points elsewhere; bytes for different cores never mix.
    /// </summary>
    public async Task SendTerminalAsync(byte[] bytes, int core = 0)
    {
        CheckCore(core);
        await inputGate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (inputCore != core)
            {
                await TextAsync($"input {core}").ConfigureAwait(false);
                inputCore = core;
            }

            Link.SendTerminal(bytes);
        }
        finally
        {
            inputGate.Release();
        }
    }

    /// <summary>
    /// Feeds a whole text to a core's Forth as if typed. Large texts go in pieces, each sent
    /// once the core's input ring has room, so nothing is lost while Forth compiles.
    /// </summary>
    public async Task SendTextAsync(string text, int core = 0, IProgress<double>? progress = null,
                                    CancellationToken cancellation = default)
    {
        byte[] bytes = ToForthText(text);
        if (bytes.Length > 0 && bytes[^1] != '\r')
        {
            bytes = [.. bytes, (byte)'\r'];
        }

        int sent = 0;
        while (sent < bytes.Length)
        {
            cancellation.ThrowIfCancellationRequested();
            BoardStatus status = await StatusAsync(core);
            int room = InputWindow - status.InputPending;
            if (room < 1024)
            {
                await Task.Delay(100, cancellation);
                continue;
            }

            int count = Math.Min(room, bytes.Length - sent);
            await SendTerminalAsync(bytes[sent..(sent + count)], core);
            sent += count;
            progress?.Report((double)sent / bytes.Length);
        }
    }

    /// <summary>A request that concerns one core: core 0 keeps the protocol 2 form, others end in the core number.</summary>
    private string Addressed(string request, int core)
    {
        CheckCore(core);
        return core == 0 ? request : $"{request} {core}";
    }

    private void CheckCore(int core)
    {
        if (core < 0 || core >= Cores)
        {
            throw new ArgumentOutOfRangeException(nameof(core), core, Cores == 1
                ? "This firmware has one Forth core."
                : $"The board has cores 0 to {Cores - 1}.");
        }
    }

    private void RequireDualCore()
    {
        if (Cores < 2)
        {
            throw new InvalidOperationException("This firmware has one Forth core.");
        }
    }

    private async Task<string> TextAsync(string request, byte[]? payload = null, TimeSpan? timeout = null)
    {
        Answer answer = await Link.RequestAsync(request, payload, timeout);
        return answer.Ok ? answer.Text : throw new BoardRefusedException(request.Split(' ')[0], answer.Reason);
    }
}

/// <summary>CRC-32 (IEEE, reflected, as zlib), the one the firmware checks.</summary>
public static class Crc32
{
    private static readonly uint[] Table = [.. Enumerable.Range(0, 256).Select(n =>
    {
        uint c = (uint)n;
        for (int k = 0; k < 8; k++)
        {
            c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        }

        return c;
    })];

    public static uint Compute(ReadOnlySpan<byte> data)
    {
        uint crc = 0xFFFFFFFFu;
        foreach (byte b in data)
        {
            crc = Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        }

        return ~crc;
    }
}
