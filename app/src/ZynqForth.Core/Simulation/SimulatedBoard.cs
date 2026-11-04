using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using ZynqForth.Board;
using ZynqForth.Protocol;

namespace ZynqForth.Simulation;

/// <summary>
/// A dual-core board in the app: protocol 3 (docs/Protocol.md) with two small Forth
/// interpreters, so the app can be tried and tested without the hardware. The interpreters
/// know integers, floats, colon definitions, strings, the LEDs and the mailboxes between
/// the cores; they are not the HF32 kernel.
/// </summary>
public sealed class SimulatedBoard : IByteTransport
{
    /// <summary>The name the app lists among the serial ports.</summary>
    public const string PortName = "SIM";

    public const string FirmwareVersion = "4.0-sim";

    private readonly BlockingCollection<byte[]> inbox = [];
    private readonly List<byte> request = [];
    private readonly SimCore[] cores;
    private Thread? worker;
    private bool inRequest;
    private int payloadLeft;
    private int inputCore;
    private bool multiplex;
    private int markedCore;
    private bool disposed;

    public SimulatedBoard()
    {
        cores = [new SimCore(this, 0), new SimCore(this, 1)];
    }

    public event Action<ReadOnlyMemory<byte>>? Received;

    public event Action<Exception>? Faulted;

    public string Name => PortName;

    /// <summary>LD0..LD3, shared by the cores like the real I/O.</summary>
    internal int Leds { get; set; }

    public void Open()
    {
        if (worker is not null)
        {
            return;
        }

        worker = new Thread(Run) { IsBackground = true, Name = "simulated board" };
        worker.Start();
        inbox.Add([]);      // power-up: both cores start
    }

    public void Write(ReadOnlySpan<byte> bytes)
    {
        if (!disposed)
        {
            inbox.Add(bytes.ToArray());
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        inbox.CompleteAdding();
    }

    internal SimCore Other(SimCore core) => cores[1 - core.Index];

    /// <summary>Forth output of one core: core 0's always goes out, core 1's only while multiplexing.</summary>
    internal void Output(SimCore core, string text)
    {
        if (text.Length == 0)
        {
            return;
        }

        if (!multiplex && core.Index != 0)
        {
            core.Held.Append(text);
            if (core.Held.Length > 4096)
            {
                core.Held.Remove(0, core.Held.Length - 4096);
            }

            return;
        }

        var bytes = new List<byte>(text.Length + 4);
        if (multiplex && markedCore != core.Index)
        {
            bytes.AddRange(Encoding.ASCII.GetBytes($"\u0001@{core.Index}\n"));
            markedCore = core.Index;
        }

        foreach (char c in text)
        {
            byte b = (byte)c;
            bytes.Add(b);
            if (b == StreamSplitter.Soh)
            {
                bytes.Add(b);
            }
        }

        Send([.. bytes]);
    }

    private void Run()
    {
        try
        {
            foreach (SimCore core in cores)
            {
                core.Start(skip: false);
            }

            foreach (byte[] chunk in inbox.GetConsumingEnumerable())
            {
                foreach (byte b in chunk)
                {
                    Take(b);
                }
            }
        }
        catch (Exception exception) when (exception is not OutOfMemoryException)
        {
            Faulted?.Invoke(exception);
        }
    }

    private void Take(byte b)
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
                string[] words = Encoding.ASCII.GetString([.. request]).Split(' ');
                request.Add(b);
                if (words[0] == "store" && words.Length > 1 && int.TryParse(words[1], out int length) && length is > 0 and <= BoardClient.SourceMax)
                {
                    payloadLeft = length;
                }
                else
                {
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
        else if (b == 0x12)
        {
            cores[inputCore].Start(skip: false);     // Ctrl-R
        }
        else
        {
            cores[inputCore].Key(b);
        }
    }

    private void Complete()
    {
        inRequest = false;
        int lineEnd = request.IndexOf((byte)'\n');
        string line = Encoding.ASCII.GetString([.. request.Take(lineEnd)]);
        byte[] payload = [.. request.Skip(lineEnd + 1)];
        List<string> args = [.. line.Split(' ', StringSplitOptions.RemoveEmptyEntries)];
        if (args.Count == 0)
        {
            return;
        }

        string name = args[0];
        args.RemoveAt(0);
        SimCore core = cores[0];
        if (name is "status" or "stack" or "words" or "restart" or "source" or "store" or "erase" or "autostart" &&
            args.Count > 0 && args[^1] is { Length: 1 } last && char.IsDigit(last[0]))
        {
            int n = last[0] - '0';
            if (n >= cores.Length)
            {
                Refuse(name, "core");
                return;
            }

            core = cores[n];
            args.RemoveAt(args.Count - 1);
        }

        switch (name, args.Count)
        {
            case ("echo", 1):
                Reply(name, args[0]);
                break;
            case ("version", 0):
                Reply(name, $"firmware zynq-dual-forth32 {FirmwareVersion}\nprotocol 3\nkernel 6100 4D32\ncell 32\nfloat 32\ncores 2\n");
                break;
            case ("status", 0):
                Reply(name, core.Status());
                break;
            case ("stack", 0):
                Reply(name, core.StackText());
                break;
            case ("words", 0):
                Reply(name, core.WordsText());
                break;
            case ("board", 0):
                Reply(name, BoardText());
                break;
            case ("restart", 0):
            case ("restart", 1) when args[0] == "skip":
                Reply(name, "");
                core.Start(skip: args.Count == 1);
                break;
            case ("input", 1) when int.TryParse(args[0], out int target) && target >= 0 && target < cores.Length:
                inputCore = target;
                Reply(name, "");
                break;
            case ("mux", 1) when args[0] is "on" or "off":
                bool on = args[0] == "on";
                Reply(name, "");
                if (on && !multiplex)
                {
                    multiplex = true;
                    markedCore = 0;
                    foreach (SimCore c in cores)
                    {
                        string held = c.Held.ToString();
                        c.Held.Clear();
                        Output(c, held);
                    }
                }

                multiplex = on;
                break;
            case ("source", 0):
                if (core.Source is null)
                {
                    Refuse(name, "none");
                }
                else
                {
                    Reply(name, Encoding.ASCII.GetString(core.Source));
                }

                break;
            case ("store", 3) when args[2] is "on" or "off":
                if (!int.TryParse(args[0], out int length) || length != payload.Length)
                {
                    Refuse(name, "length");
                }
                else if (!uint.TryParse(args[1], NumberStyles.HexNumber, null, out uint crc) || crc != Crc32.Compute(payload))
                {
                    Refuse(name, "crc");
                }
                else
                {
                    core.Source = payload;
                    core.Autostart = args[2] == "on";
                    Reply(name, "");
                }

                break;
            case ("erase", 0):
                core.Source = null;
                Reply(name, "");
                break;
            case ("autostart", 1) when args[0] is "on" or "off":
                if (core.Source is null)
                {
                    Refuse(name, "none");
                }
                else
                {
                    core.Autostart = args[0] == "on";
                    Reply(name, "");
                }

                break;
            case ("store" or "autostart" or "restart" or "input" or "mux" or "echo", _):
                Refuse(name, "args");
                break;
            default:
                Refuse(name, "unknown");
                break;
        }
    }

    private string BoardText()
    {
        var xadc = new string[32];
        Array.Fill(xadc, "0000");
        xadc[0] = "9C40";       // about 34 °C
        xadc[1] = "5550";       // 1.0 V
        xadc[2] = "9990";       // 1.8 V
        xadc[6] = "5550";
        return $"board {Leds & 0xF:X8}\nports 00000000 00000000 00000000\npwm 00000000\nxadc {string.Join(' ', xadc)}\n" +
               "pg 00020000 00000000\nfn " + string.Join(' ', Enumerable.Repeat("0000", 14)) + "\n";
    }

    private void Reply(string name, string text)
    {
        byte[] payload = Encoding.ASCII.GetBytes(text);
        Send([.. Encoding.ASCII.GetBytes($"\u0001ok {name} {payload.Length}\n"), .. payload]);
    }

    private void Refuse(string name, string reason) => Send(Encoding.ASCII.GetBytes($"\u0001err {name} {reason}\n"));

    private void Send(byte[] bytes)
    {
        if (!disposed)
        {
            Received?.Invoke(bytes);
        }
    }
}

/// <summary>One simulated core: a small outer interpreter with its own stacks, dictionary and saved source.</summary>
internal sealed class SimCore
{
    private const int Stacks = 20;

    private static readonly string[] Primitives =
    [
        "+", "-", "*", "/", "mod", "negate", "abs", "max", "min", "=", "<", ">", "0=", "and", "or", "xor", "invert",
        "dup", "drop", "swap", "over", "rot", "nip", "depth", ".", "u.", ".s", "emit", "cr", "space", "words",
        "f+", "f-", "f*", "f/", "fsqrt", "fdup", "fdrop", "fswap", "f.", "f.s", "s>f", "f>s", "fdepth",
        "led!", "led@", "core#", "send", "receive", "mail?",
    ];

    private readonly SimulatedBoard board;
    private readonly StringBuilder line = new();
    private readonly List<int> stack = [];
    private readonly List<float> floats = [];
    private readonly List<(string Name, int Address, List<string> Body)> defined = [];
    private readonly StringBuilder output = new();
    private List<string>? compiling;
    private string compilingName = "";
    private int[] snapStack = [];
    private float[] snapFloats = [];
    private int starts;
    private string lastStart = "none";
    private int here = 0x05E40;
    private int depthOfCalls;

    public SimCore(SimulatedBoard board, int index)
    {
        this.board = board;
        Index = index;
    }

    public int Index { get; }

    /// <summary>Output kept back while the terminals are not multiplexed (core 1).</summary>
    public StringBuilder Held { get; } = new();

    public byte[]? Source { get; set; }

    public bool Autostart { get; set; }

    public Queue<int> Mailbox { get; } = new();

    public void Start(bool skip)
    {
        starts++;
        line.Clear();
        stack.Clear();
        floats.Clear();
        defined.Clear();
        compiling = null;
        here = 0x05E40;
        Snap();
        board.Output(this, $"\r\n[zynq-dual-forth32] core {Index}: {SimulatedBoard.FirmwareVersion}, simulated kernel\r\n" +
                           $"HF32 Forth core {Index} (simulator)\r\n");
        bool feed = !skip && Autostart && Source is not null;
        lastStart = feed ? "fed" : skip ? "skipped" : "none";
        if (feed)
        {
            foreach (byte b in Source!)
            {
                Key(b);
            }
        }
    }

    /// <summary>One byte of terminal input: echoed; CR interprets the line.</summary>
    public void Key(byte b)
    {
        if (b is (byte)'\r' or (byte)'\n')
        {
            if (b == '\n' && line.Length == 0)
            {
                return;
            }

            board.Output(this, " ");
            string text = line.ToString();
            line.Clear();
            output.Clear();
            bool ok = Interpret(text);
            if (ok && compiling is null)
            {
                output.Append(" ok");
            }

            output.Append("\r\n");
            Snap();
            board.Output(this, output.ToString());
        }
        else if (b is 8 or 127)
        {
            if (line.Length > 0)
            {
                line.Length--;
                board.Output(this, "\b \b");
            }
        }
        else if (b is >= 32 and < 127 && line.Length < 255)
        {
            line.Append((char)b);
            board.Output(this, ((char)b).ToString());
        }
    }

    public string Status()
    {
        string source = Source is null ? "none" : "stored";
        return $"state running\npc {0x0400 + Index * 0x40:X4}\ninput 0\nstarts {starts}\nsource {source}\n" +
               $"length {Source?.Length ?? 0}\ncrc {(Source is null ? 0 : Crc32.Compute(Source)):X8}\n" +
               $"autostart {(Autostart ? "on" : "off")}\nlast {lastStart}\ncore {Index}\nmailbox {Mailbox.Count}\n";
    }

    public string StackText() =>
        $"{snapStack.Length}{string.Concat(snapStack.Select(v => $" {unchecked((uint)v):X8}"))}\n" +
        $"f {snapFloats.Length}{string.Concat(snapFloats.Select(f => $" {BitConverter.SingleToUInt32Bits(f):X8}"))}\n";

    public string WordsText()
    {
        var text = new StringBuilder($"here {here:X5}\n");
        for (int i = defined.Count - 1; i >= 0; i--)
        {
            text.Append($"{defined[i].Address:X5} - {defined[i].Name}\n");
        }

        for (int i = Primitives.Length - 1; i >= 0; i--)
        {
            text.Append($"{0x00100 + i * 0x20:X5} {(i < 17 ? "n" : "-")} {Primitives[i]}\n");
        }

        return text.ToString();
    }

    private void Snap()
    {
        snapStack = [.. stack.TakeLast(Stacks)];
        snapFloats = [.. floats.TakeLast(Stacks)];
    }

    private bool Interpret(string text)
    {
        try
        {
            List<string> tokens = [.. Tokens(text)];
            for (int i = 0; i < tokens.Count; i++)
            {
                string token = tokens[i];
                if (compiling is null && token == ":")
                {
                    if (i + 1 >= tokens.Count || tokens[i + 1].StartsWith('\u0000'))
                    {
                        throw new SimAbort(": needs a name");
                    }

                    compilingName = tokens[++i].ToLowerInvariant();
                    compiling = [];
                }
                else if (compiling is not null)
                {
                    if (token == ";")
                    {
                        defined.Add((compilingName, here, compiling));
                        here += 4 * (compiling.Count + 2);
                        compiling = null;
                    }
                    else
                    {
                        compiling.Add(token);
                    }
                }
                else
                {
                    Execute(token);
                }
            }

            return true;
        }
        catch (SimAbort abort)
        {
            output.Append(' ').Append(abort.Message);
            stack.Clear();
            floats.Clear();
            compiling = null;
            depthOfCalls = 0;
            return false;
        }
    }

    /// <summary>Words, with <c>." text"</c> kept as one token and comments dropped.</summary>
    private static IEnumerable<string> Tokens(string text)
    {
        int i = 0;
        while (i < text.Length)
        {
            while (i < text.Length && text[i] == ' ')
            {
                i++;
            }

            int start = i;
            while (i < text.Length && text[i] != ' ')
            {
                i++;
            }

            if (start == i)
            {
                yield break;
            }

            string word = text[start..i];
            if (word == "\\")
            {
                yield break;
            }

            if (word is "(" or ".\"")
            {
                int end = text.IndexOf(word == "(" ? ')' : '"', Math.Min(i + 1, text.Length));
                string inner = end < 0 ? text[Math.Min(i + 1, text.Length)..] : text[(i + 1)..end];
                i = end < 0 ? text.Length : end + 1;
                if (word == ".\"")
                {
                    yield return "\u0000" + inner;
                }

                continue;
            }

            yield return word;
        }
    }

    private void Execute(string token)
    {
        if (token.StartsWith('\u0000'))
        {
            output.Append(token[1..]);
            return;
        }

        string word = token.ToLowerInvariant();
        for (int i = defined.Count - 1; i >= 0; i--)
        {
            if (defined[i].Name == word)
            {
                if (++depthOfCalls > 64)
                {
                    throw new SimAbort("nesting?");
                }

                foreach (string t in defined[i].Body)
                {
                    Execute(t);
                }

                depthOfCalls--;
                return;
            }
        }

        if (Primitive(word))
        {
            return;
        }

        if (word is ":" or ";")
        {
            throw new SimAbort(word + " ?");
        }

        if (TryInteger(word, out int n))
        {
            stack.Add(n);
        }
        else if ((word.Contains('.') || word.Contains('e')) &&
                 float.TryParse(word, NumberStyles.Float, CultureInfo.InvariantCulture, out float f))
        {
            floats.Add(f);
        }
        else
        {
            throw new SimAbort(token + " ?");
        }
    }

    private static bool TryInteger(string word, out int value)
    {
        bool hex = word.StartsWith('$');
        string digits = hex ? word[1..] : word;
        if (hex && int.TryParse(digits, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out value))
        {
            return true;
        }

        if (!hex && long.TryParse(digits, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out long wide) &&
            wide is >= int.MinValue and <= uint.MaxValue)
        {
            value = unchecked((int)wide);
            return true;
        }

        value = 0;
        return false;
    }

    private int Pop()
    {
        if (stack.Count == 0)
        {
            throw new SimAbort("stack?");
        }

        int v = stack[^1];
        stack.RemoveAt(stack.Count - 1);
        return v;
    }

    private float FPop()
    {
        if (floats.Count == 0)
        {
            throw new SimAbort("fstack?");
        }

        float v = floats[^1];
        floats.RemoveAt(floats.Count - 1);
        return v;
    }

    private void Push(int v) => stack.Add(v);

    private void Push(bool flag) => stack.Add(flag ? -1 : 0);

    private static string Float(float f) => FloatText.Format(f) + " ";

    private bool Primitive(string word)
    {
        int a, b;
        float x, y;
        switch (word)
        {
            case "+": b = Pop(); Push(unchecked(Pop() + b)); break;
            case "-": b = Pop(); Push(unchecked(Pop() - b)); break;
            case "*": b = Pop(); Push(unchecked(Pop() * b)); break;
            case "/": b = Pop(); a = Pop(); Push(b == 0 ? throw new SimAbort("division by zero") : a / b); break;
            case "mod": b = Pop(); a = Pop(); Push(b == 0 ? throw new SimAbort("division by zero") : a % b); break;
            case "negate": Push(unchecked(-Pop())); break;
            case "abs": Push(Math.Abs(Pop())); break;
            case "max": b = Pop(); Push(Math.Max(Pop(), b)); break;
            case "min": b = Pop(); Push(Math.Min(Pop(), b)); break;
            case "=": b = Pop(); Push(Pop() == b); break;
            case "<": b = Pop(); Push(Pop() < b); break;
            case ">": b = Pop(); Push(Pop() > b); break;
            case "0=": Push(Pop() == 0); break;
            case "and": b = Pop(); Push(Pop() & b); break;
            case "or": b = Pop(); Push(Pop() | b); break;
            case "xor": b = Pop(); Push(Pop() ^ b); break;
            case "invert": Push(~Pop()); break;
            case "dup": a = Pop(); Push(a); Push(a); break;
            case "drop": Pop(); break;
            case "swap": b = Pop(); a = Pop(); Push(b); Push(a); break;
            case "over": b = Pop(); a = Pop(); Push(a); Push(b); Push(a); break;
            case "rot": int c = Pop(); b = Pop(); a = Pop(); Push(b); Push(c); Push(a); break;
            case "nip": b = Pop(); Pop(); Push(b); break;
            case "depth": Push(stack.Count); break;
            case ".": output.Append(Pop()).Append(' '); break;
            case "u.": output.Append(unchecked((uint)Pop())).Append(' '); break;
            case ".s": output.Append($"<{stack.Count}> ").Append(string.Concat(stack.Select(v => v + " "))); break;
            case "emit": output.Append((char)(Pop() & 0x7F)); break;
            case "cr": output.Append("\r\n"); break;
            case "space": output.Append(' '); break;
            case "words":
                output.Append(string.Join(' ', defined.Select(d => d.Name).Reverse().Concat(Primitives.Reverse())));
                break;
            case "f+": y = FPop(); floats.Add(FPop() + y); break;
            case "f-": y = FPop(); floats.Add(FPop() - y); break;
            case "f*": y = FPop(); floats.Add(FPop() * y); break;
            case "f/": y = FPop(); floats.Add(FPop() / y); break;
            case "fsqrt": floats.Add(MathF.Sqrt(FPop())); break;
            case "fdup": x = FPop(); floats.Add(x); floats.Add(x); break;
            case "fdrop": FPop(); break;
            case "fswap": y = FPop(); x = FPop(); floats.Add(y); floats.Add(x); break;
            case "f.": output.Append(Float(FPop())); break;
            case "f.s": output.Append($"<{floats.Count}> ").Append(string.Concat(floats.Select(Float))); break;
            case "s>f": floats.Add(Pop()); break;
            case "f>s": Push((int)MathF.Truncate(FPop())); break;
            case "fdepth": Push(floats.Count); break;
            case "led!": board.Leds = Pop() & 0xF; break;
            case "led@": Push(board.Leds); break;
            case "core#": Push(Index); break;
            case "send":
                b = Pop();
                a = Pop();
                if (b is < 0 or > 1)
                {
                    throw new SimAbort("no such core");
                }

                (b == Index ? this : board.Other(this)).Mailbox.Enqueue(a);
                break;
            case "receive":
                Push(Mailbox.Count == 0 ? throw new SimAbort("mailbox empty") : Mailbox.Dequeue());
                break;
            case "mail?": Push(Mailbox.Count); break;
            default:
                return false;
        }

        return true;
    }

    private sealed class SimAbort(string message) : Exception(message);
}
