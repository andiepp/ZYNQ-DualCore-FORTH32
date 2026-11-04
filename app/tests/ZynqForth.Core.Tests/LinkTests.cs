using System.Text;
using ZynqForth.Board;
using ZynqForth.Protocol;

namespace ZynqForth.Tests;

/// <summary>A transport whose "board" answers requests from a table and echoes terminal input.</summary>
internal sealed class FakeTransport : IByteTransport
{
    private readonly List<byte> request = [];
    private int payloadLeft;
    private bool inRequest;

    public event Action<ReadOnlyMemory<byte>>? Received;

    public event Action<Exception>? Faulted;

    public string Name => "fake";

    public Func<string, byte[], string?> Answer { get; set; } = (_, _) => null;

    public StringBuilder TerminalInput { get; } = new();

    public List<(string Request, byte[] Payload)> Requests { get; } = [];

    public int StoreLength { get; set; }

    public void Open()
    {
    }

    public void Write(ReadOnlySpan<byte> bytes)
    {
        foreach (byte b in bytes)
        {
            if (payloadLeft > 0)
            {
                request.Add(b);
                if (--payloadLeft == 0)
                {
                    Complete();
                }
            }
            else if (inRequest)
            {
                if (b == '\n')
                {
                    string line = Encoding.ASCII.GetString([.. request]);
                    string[] words = line.Split(' ');
                    if (words[0] == "store" && int.Parse(words[1]) > 0)
                    {
                        payloadLeft = int.Parse(words[1]);
                        request.Add(b);
                    }
                    else
                    {
                        request.Add(b);
                        Complete();
                    }
                }
                else
                {
                    request.Add(b);
                }
            }
            else if (b == StreamSplitter.Soh)
            {
                inRequest = true;
                request.Clear();
            }
            else
            {
                TerminalInput.Append((char)b);
            }
        }
    }

    public void Push(string text) => Received?.Invoke(Encoding.Latin1.GetBytes(text));

    public void Fail() => Faulted?.Invoke(new IOException("unplugged"));

    public void Dispose()
    {
    }

    private void Complete()
    {
        inRequest = false;
        int lineEnd = request.IndexOf((byte)'\n');
        string line = Encoding.ASCII.GetString([.. request.Take(lineEnd)]);
        byte[] payload = [.. request.Skip(lineEnd + 1)];
        Requests.Add((line, payload));
        string? answer = Answer(line, payload);
        if (answer is not null)
        {
            Push(answer);
        }
    }
}

public class LinkTests
{
    private readonly FakeTransport transport = new();
    private readonly ForthLink link;
    private readonly BoardClient client;

    public LinkTests()
    {
        link = new ForthLink(transport);
        client = new BoardClient(link);
    }

    [Fact]
    public async Task RequestGetsItsAnswerWhileTerminalOutputPassesBy()
    {
        var terminal = new StringBuilder();
        link.TerminalReceived += (_, b) => terminal.Append(Encoding.ASCII.GetString(b.Span));
        transport.Answer = (line, _) => line == "echo hi" ? "ok\r\n\u0001ok echo 2\nhi more" : null;

        Assert.True(await client.EchoAsync("hi"));
        Assert.Equal("ok\r\n more", terminal.ToString());
    }

    [Fact]
    public async Task RefusalBecomesAnException()
    {
        transport.Answer = (_, _) => "\u0001err autostart none\n";
        BoardRefusedException refused = await Assert.ThrowsAsync<BoardRefusedException>(() => client.AutostartAsync(true));
        Assert.Equal("none", refused.Reason);
    }

    [Fact]
    public async Task SilenceTimesOut()
    {
        await Assert.ThrowsAsync<LinkException>(() =>
            link.RequestAsync("status", timeout: TimeSpan.FromMilliseconds(100)));
    }

    [Fact]
    public async Task FaultFailsTheWaitingRequest()
    {
        Task<Answer> waiting = link.RequestAsync("status", timeout: TimeSpan.FromSeconds(10));
        transport.Fail();
        await Assert.ThrowsAsync<LinkException>(() => waiting);
    }

    [Fact]
    public async Task StoreSendsLengthCrcAndPayload()
    {
        transport.Answer = (line, _) => line.StartsWith("store", StringComparison.Ordinal) ? "\u0001ok store 0\n" : null;
        await client.StoreAsync(": sq dup * ;\n12 sq .", autostart: true);

        (string request, byte[] payload) = Assert.Single(transport.Requests);
        byte[] expected = ": sq dup * ;\r12 sq .\r"u8.ToArray();
        Assert.Equal($"store {expected.Length} {Crc32.Compute(expected):X8} on", request);
        Assert.Equal(expected, payload);
    }

    [Fact]
    public async Task SourceNoneIsNull()
    {
        transport.Answer = (_, _) => "\u0001err source none\n";
        Assert.Null(await client.SourceAsync());
    }

    [Fact]
    public async Task SendTextWaitsForRoomInTheInputRing()
    {
        int pending = 15 * 1024;
        transport.Answer = (line, _) =>
        {
            if (line != "status")
            {
                return null;
            }

            string text = $"state running\ninput {pending}\n";
            pending = 0;        // Forth catches up after the first look
            return $"\u0001ok status {text.Length}\n{text}";
        };

        string source = new string('x', 20000);
        await client.SendTextAsync(source);
        Assert.Equal(source + "\r", transport.TerminalInput.ToString());
        Assert.True(transport.Requests.Count >= 3);
    }

    [Fact]
    public void TerminalInputNeverStartsARequest()
    {
        link.SendTerminal("a\u0001b");
        Assert.Equal("a?b", transport.TerminalInput.ToString());
    }
}
