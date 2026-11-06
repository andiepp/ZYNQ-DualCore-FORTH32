using System.Collections.Concurrent;
using System.Text;
using ZynqForth.Board;
using ZynqForth.Protocol;
using ZynqForth.Simulation;

namespace ZynqForth.Tests;

/// <summary>Protocol 3: core markers, core-addressed requests, the input switch, and the simulated board.</summary>
public class DualCoreTests
{
    private const string DualVersion = "firmware zynq-dual-forth32 4.0\nprotocol 3\nkernel 6100 4D32\ncell 32\nfloat 32\ncores 2\n";

    [Fact]
    public void VersionCountsCores()
    {
        BoardVersion dual = BoardVersion.Parse(DualVersion);
        Assert.Equal("zynq-dual-forth32", dual.Product);
        Assert.Equal(2, dual.Cores);
        Assert.True(dual.IsDualCore);

        BoardVersion single = BoardVersion.Parse("firmware zynq-forth32 3.1\nprotocol 2\nkernel 6011 BEEF\n");
        Assert.Equal(1, single.Cores);
        Assert.False(single.IsDualCore);

        // a cores line means nothing below protocol 3
        Assert.Equal(1, BoardVersion.Parse("firmware x 1\nprotocol 2\ncores 2\n").Cores);
    }

    [Fact]
    public void StatusReadsCoreAndMailbox()
    {
        BoardStatus status = BoardStatus.Parse("state running\ninput 0\ncore 1\nmailbox 3\n");
        Assert.Equal(1, status.Core);
        Assert.Equal(3, status.Mailbox);
        Assert.Null(BoardStatus.Parse("state running\n").Mailbox);
    }

    [Fact]
    public void CoreMarkersRouteTheOutput()
    {
        var splitter = new StreamSplitter();
        var cores = new List<int>();
        splitter.CoreSwitched += cores.Add;
        var text = new StringBuilder();
        splitter.TerminalBytes += b => text.Append(Encoding.ASCII.GetString(b.Span));
        splitter.Feed("a\u0001@1\nb\u0001@0\nc"u8);
        Assert.Equal([1, 0], cores);
        Assert.Equal("abc", text.ToString());
    }

    [Fact]
    public async Task LinkTagsOutputWithItsCore()
    {
        var transport = new FakeTransport();
        using var link = new ForthLink(transport);
        var seen = new List<(int, string)>();
        link.TerminalReceived += (core, b) => seen.Add((core, Encoding.ASCII.GetString(b.Span)));
        transport.Push("zero \u0001@1\none \u0001@0\nagain");
        await Task.Yield();
        Assert.Equal([(0, "zero "), (1, "one "), (0, "again")], seen);
    }

    [Fact]
    public async Task CoreOneRequestsEndInTheCoreNumber()
    {
        var transport = new FakeTransport();
        var client = new BoardClient(new ForthLink(transport));
        transport.Answer = (line, _) =>
        {
            string name = line.Split(' ')[0];
            string text = name switch
            {
                "version" => DualVersion,
                "status" => "state running\ninput 0\n",
                "stack" => "0\nf 0\n",
                "words" => "here 05E40\n",
                _ => "",
            };
            return $"\u0001ok {name} {text.Length}\n{text}";
        };

        await client.VersionAsync();
        await client.StatusAsync(0);
        await client.StatusAsync(1);
        await client.StackAsync(1);
        await client.WordsAsync(1);
        await client.RestartAsync(skipAutostart: true, core: 1);
        await client.AutostartAsync(true, 1);
        await client.StoreAsync("1 2 +", autostart: false, core: 1);

        string[] requests = [.. transport.Requests.Select(r => r.Request)];
        Assert.Equal("status", requests[1]);
        Assert.Equal("status 1", requests[2]);
        Assert.Equal("stack 1", requests[3]);
        Assert.Equal("words 1", requests[4]);
        Assert.Equal("restart skip 1", requests[5]);
        Assert.Equal("autostart on 1", requests[6]);
        Assert.StartsWith("store 6 ", requests[7]);
        Assert.EndsWith(" off 1", requests[7]);
    }

    [Fact]
    public async Task InputIsSwitchedOnlyWhenTheCoreChanges()
    {
        var transport = new FakeTransport();
        var client = new BoardClient(new ForthLink(transport));
        transport.Answer = (line, _) =>
        {
            string name = line.Split(' ')[0];
            string text = name == "version" ? DualVersion : "";
            return $"\u0001ok {name} {text.Length}\n{text}";
        };

        await client.VersionAsync();
        await client.SendLineAsync("1", 0);
        await client.SendLineAsync("2", 0);
        await client.SendLineAsync("3", 1);
        await client.SendLineAsync("4", 0);

        Assert.Equal(["version", "input 0", "input 1", "input 0"], transport.Requests.Select(r => r.Request));
        Assert.Equal("1\r2\r3\r4\r", transport.TerminalInput.ToString());
    }

    [Fact]
    public async Task SingleCoreFirmwareHasNoCoreOne()
    {
        var transport = new FakeTransport();
        var client = new BoardClient(new ForthLink(transport));
        transport.Answer = (line, _) =>
        {
            string name = line.Split(' ')[0];
            string text = name == "version" ? "firmware zynq-forth32 3.1\nprotocol 2\n" : "state running\n";
            return $"\u0001ok {name} {text.Length}\n{text}";
        };

        await client.VersionAsync();
        Assert.Equal(1, client.Cores);
        await client.SendLineAsync("1 2 +");
        await client.StatusAsync();
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => client.StatusAsync(1));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => client.SendLineAsync("x", 1));
        await Assert.ThrowsAsync<InvalidOperationException>(() => client.MultiplexAsync(true));

        // protocol 2 requests only: no input switch, no core numbers
        Assert.Equal(["version", "status"], transport.Requests.Select(r => r.Request));
    }
}

/// <summary>The simulated board through the real protocol classes.</summary>
public sealed class SimulatedBoardTests : IDisposable
{
    private readonly SimulatedBoard board = new();
    private readonly ForthLink link;
    private readonly BoardClient client;
    private readonly ConcurrentDictionary<int, StringBuilder> output = new();

    public SimulatedBoardTests()
    {
        link = new ForthLink(board);
        link.TerminalReceived += (core, bytes) =>
        {
            StringBuilder text = output.GetOrAdd(core, _ => new StringBuilder());
            lock (text)
            {
                text.Append(Encoding.ASCII.GetString(bytes.Span));
            }
        };
        client = new BoardClient(link);
        link.Open();
    }

    public void Dispose() => link.Dispose();

    [Fact]
    public async Task BothCoresTalkSeparately()
    {
        BoardVersion version = await client.VersionAsync();
        Assert.Equal(2, client.Cores);
        Assert.Equal(SimulatedBoard.FirmwareVersion, version.Firmware);
        await client.MultiplexAsync(true);

        await client.SendLineAsync("2 3 + .", 0);
        await client.SendLineAsync(": sq dup * ;", 1);
        await client.SendLineAsync("7 sq 9", 1);
        await WaitForAsync(() => Text(1).Contains("7 sq 9  ok", StringComparison.Ordinal));

        Assert.Contains("2 3 + . 5  ok", Text(0), StringComparison.Ordinal);
        Assert.DoesNotContain("sq", Text(0), StringComparison.Ordinal);
        Assert.Contains("HF32 Forth core 1", Text(1), StringComparison.Ordinal);    // held until mux on

        DataStack stack1 = await client.StackAsync(1);
        Assert.Equal([49u, 9u], stack1.Items);
        Assert.Empty((await client.StackAsync(0)).Items);
        Assert.Contains((await client.WordsAsync(1)).Words, w => w.Name == "sq");
        Assert.DoesNotContain((await client.WordsAsync(0)).Words, w => w.Name == "sq");
    }

    [Fact]
    public async Task MailboxCarriesWordsBetweenCores()
    {
        await client.VersionAsync();
        await client.MultiplexAsync(true);
        await client.SendLineAsync("42 send 43 send mail? .", 0);
        await WaitForAsync(async () => (await client.StatusAsync(1)).Mailbox == 2);

        await client.SendLineAsync("mail? . receive receive + .", 1);
        await WaitForAsync(() => Text(1).Contains("-1 85  ok", StringComparison.Ordinal));
        Assert.Equal(0, (await client.StatusAsync(1)).Mailbox);
        Assert.Contains("0  ok", Text(0), StringComparison.Ordinal);     // core 0's own mailbox is empty
    }

    [Fact]
    public async Task LocksBelongToOneCore()
    {
        await client.VersionAsync();
        await client.MultiplexAsync(true);
        await client.SendLineAsync("3 try-lock .", 0);
        await WaitForAsync(() => Text(0).Contains("-1  ok", StringComparison.Ordinal));
        await client.SendLineAsync("3 try-lock . 3 unlock 3 try-lock .", 1);
        await WaitForAsync(() => Text(1).Contains("0 0  ok", StringComparison.Ordinal));
        await client.SendLineAsync("3 unlock", 0);
        await client.SendLineAsync("3 try-lock .", 1);
        await WaitForAsync(() => Text(1).Contains("-1  ok", StringComparison.Ordinal));
    }

    [Fact]
    public async Task SingleLedWordsChangeOneSharedLed()
    {
        await client.VersionAsync();
        await client.MultiplexAsync(true);
        await client.SendLineAsync("5 led! 1 led-on 3 led-mask .", 0);
        await WaitForAsync(() => Text(0).Contains("8  ok", StringComparison.Ordinal));
        await client.SendLineAsync("0 led-off 3 led-toggle led@ .", 1);
        await WaitForAsync(() => Text(1).Contains("14  ok", StringComparison.Ordinal));   // the LEDs are shared
        Assert.Equal(14, (await client.BoardAsync()).Leds);
        await client.SendLineAsync("4 led-on", 0);
        await WaitForAsync(() => Text(0).Contains("bad led", StringComparison.Ordinal));
        Assert.Equal(14, (await client.BoardAsync()).Leds);
    }

    [Fact]
    public async Task EachCoreHasItsOwnSavedSource()
    {
        await client.VersionAsync();
        await client.StoreAsync("1 led!", autostart: true, core: 1);
        Assert.Equal(SourceState.Stored, (await client.StatusAsync(1)).Source);
        Assert.Equal(SourceState.None, (await client.StatusAsync(0)).Source);
        Assert.Null(await client.SourceAsync(0));
        Assert.Equal("1 led!" + Environment.NewLine, await client.SourceAsync(1));

        await client.RestartAsync(skipAutostart: false, core: 1);
        await WaitForAsync(async () => (await client.BoardAsync()).Leds == 1);   // the LEDs are shared
        Assert.Equal("fed", (await client.StatusAsync(1)).LastStart);
        await client.EraseAsync(1);
        Assert.Equal(SourceState.None, (await client.StatusAsync(1)).Source);
    }

    [Fact]
    public async Task ErrorsClearTheStacksLikeForth()
    {
        await client.VersionAsync();
        await client.SendLineAsync("1 2 nosuchword", 0);
        await WaitForAsync(() => Text(0).Contains("nosuchword ?", StringComparison.Ordinal));
        Assert.Empty((await client.StackAsync(0)).Items);

        await client.SendLineAsync("2.5e0 2.0 f* 1.5", 0);
        await WaitForAsync(() => Text(0).Contains("1.5  ok", StringComparison.Ordinal));
        DataStack stack = await client.StackAsync(0);
        Assert.Equal([5f, 1.5f], stack.Floats.Select(BitConverter.UInt32BitsToSingle));
    }

    private string Text(int core)
    {
        if (!output.TryGetValue(core, out StringBuilder? text))
        {
            return "";
        }

        lock (text)
        {
            return text.ToString();
        }
    }

    private static Task WaitForAsync(Func<bool> condition) => WaitForAsync(() => Task.FromResult(condition()));

    private static async Task WaitForAsync(Func<Task<bool>> condition)
    {
        for (int i = 0; i < 100; i++)
        {
            if (await condition())
            {
                return;
            }

            await Task.Delay(20);
        }

        Assert.Fail("timed out");
    }
}
