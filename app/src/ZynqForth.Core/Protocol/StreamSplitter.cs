using System.Text;

namespace ZynqForth.Protocol;

/// <summary>An answer to a service request: <c>ok &lt;name&gt; &lt;length&gt;</c> plus payload, or <c>err &lt;name&gt; &lt;reason&gt;</c>.</summary>
public sealed record Answer(bool Ok, string Name, byte[] Payload, string Reason)
{
    public string Text => Encoding.ASCII.GetString(Payload);

    public static Answer Success(string name, byte[] payload) => new(true, name, payload, "");

    public static Answer Failure(string name, string reason) => new(false, name, [], reason);
}

/// <summary>
/// Splits the bytes from the board into Forth's terminal output and service answers.
/// An answer starts with SOH (0x01), a header line ending in LF, then for <c>ok</c> the
/// payload of the stated length. A doubled SOH is a 0x01 that Forth printed itself.
/// With the dual-core firmware's terminal multiplexing on, <c>SOH @n LF</c> marks where the
/// output of core n begins.
/// </summary>
public sealed class StreamSplitter
{
    public const byte Soh = 0x01;
    private const int HeaderMax = 256;

    private enum State { Terminal, AfterSoh, Header, Payload }

    private readonly StringBuilder header = new();
    private State state;
    private string name = "";
    private byte[] payload = [];
    private int payloadFill;

    /// <summary>Bytes of Forth's output, in order.</summary>
    public event Action<ReadOnlyMemory<byte>>? TerminalBytes;

    public event Action<Answer>? AnswerReceived;

    /// <summary>A core marker <c>SOH @n LF</c> (protocol 3): the following terminal bytes are core n's.</summary>
    public event Action<int>? CoreSwitched;

    /// <summary>A header that could not be read; the splitter returns to terminal output.</summary>
    public event Action<string>? Garbled;

    public void Feed(ReadOnlySpan<byte> data)
    {
        int run = 0;            // start of the pending terminal run in data
        for (int i = 0; i < data.Length; i++)
        {
            byte b = data[i];
            switch (state)
            {
                case State.Terminal:
                    if (b == Soh)
                    {
                        Flush(data[run..i]);
                        state = State.AfterSoh;
                        run = i + 1;
                    }

                    continue;

                case State.AfterSoh:
                    if (b == Soh)
                    {
                        Flush([Soh]);
                        state = State.Terminal;
                    }
                    else
                    {
                        header.Clear().Append((char)b);
                        state = State.Header;
                    }

                    break;

                case State.Header:
                    if (b == (byte)'\n')
                    {
                        EndHeader();
                    }
                    else if (header.Length >= HeaderMax)
                    {
                        Garbled?.Invoke(header.ToString());
                        state = State.Terminal;
                    }
                    else
                    {
                        header.Append((char)b);
                    }

                    break;

                case State.Payload:
                    int take = Math.Min(payload.Length - payloadFill, data.Length - i);
                    data.Slice(i, take).CopyTo(payload.AsSpan(payloadFill));
                    payloadFill += take;
                    i += take - 1;
                    if (payloadFill == payload.Length)
                    {
                        state = State.Terminal;
                        AnswerReceived?.Invoke(Answer.Success(name, payload));
                    }

                    break;
            }

            run = i + 1;
        }

        if (state == State.Terminal)
        {
            Flush(data[run..]);
        }
    }

    private void EndHeader()
    {
        string[] words = header.ToString().TrimEnd('\r').Split(' ', StringSplitOptions.RemoveEmptyEntries);
        state = State.Terminal;
        if (words is [var marker] && marker.Length == 2 && marker[0] == '@' && marker[1] is >= '0' and <= '9')
        {
            // protocol 3: the terminal bytes from here on are core n's output
            CoreSwitched?.Invoke(marker[1] - '0');
        }
        else if (words is ["ok", var okName, var lengthText] && int.TryParse(lengthText, out int length) && length >= 0)
        {
            if (length == 0)
            {
                AnswerReceived?.Invoke(Answer.Success(okName, []));
                return;
            }

            name = okName;
            payload = new byte[length];
            payloadFill = 0;
            state = State.Payload;
        }
        else if (words is ["err", var errName, ..])
        {
            AnswerReceived?.Invoke(Answer.Failure(errName, string.Join(' ', words.Skip(2))));
        }
        else
        {
            Garbled?.Invoke(header.ToString());
        }
    }

    private void Flush(ReadOnlySpan<byte> bytes)
    {
        if (!bytes.IsEmpty)
        {
            TerminalBytes?.Invoke(bytes.ToArray());
        }
    }
}
