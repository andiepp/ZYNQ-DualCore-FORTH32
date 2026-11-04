using System.Text;

namespace ZynqForth.Protocol;

/// <summary>The board did not answer a service request, or answered something else.</summary>
public sealed class LinkException(string message) : Exception(message);

/// <summary>
/// Forth's terminal and the service requests over one byte stream (docs/Protocol.md).
/// Requests are sent one at a time; terminal input may be sent at any moment between them.
/// </summary>
public sealed class ForthLink : IDisposable
{
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(5);

    private readonly IByteTransport transport;
    private readonly StreamSplitter splitter = new();
    private readonly SemaphoreSlim requestGate = new(1, 1);
    private readonly Lock answerLock = new();
    private TaskCompletionSource<Answer>? pending;
    private volatile int outputCore;

    public ForthLink(IByteTransport transport)
    {
        this.transport = transport ?? throw new ArgumentNullException(nameof(transport));
        transport.Received += data => splitter.Feed(data.Span);
        transport.Faulted += exception =>
        {
            FailPending(new LinkException("The connection failed: " + exception.Message));
            Faulted?.Invoke(exception);
        };
        splitter.TerminalBytes += bytes => TerminalReceived?.Invoke(outputCore, bytes);
        splitter.CoreSwitched += core => outputCore = core;
        splitter.AnswerReceived += OnAnswer;
        splitter.Garbled += header => Garbled?.Invoke(header);
    }

    /// <summary>
    /// Forth's output and the core that printed it (0 unless the dual-core firmware marks
    /// another one), raised on the transport's reader thread.
    /// </summary>
    public event Action<int, ReadOnlyMemory<byte>>? TerminalReceived;

    public event Action<Exception>? Faulted;

    /// <summary>An answer header that made no sense, or an answer nobody waited for.</summary>
    public event Action<string>? Garbled;

    public string Name => transport.Name;

    public void Open() => transport.Open();

    /// <summary>Terminal input: the bytes go to the Forth the board's input points at, as typed.</summary>
    public void SendTerminal(ReadOnlySpan<byte> bytes)
    {
        if (bytes.IndexOf(StreamSplitter.Soh) >= 0)
        {
            // a SOH would start a service request; Forth never needs one
            byte[] copy = bytes.ToArray();
            copy.AsSpan().Replace(StreamSplitter.Soh, (byte)'?');
            transport.Write(copy);
            return;
        }

        transport.Write(bytes);
    }

    public void SendTerminal(string text) => SendTerminal(Encoding.ASCII.GetBytes(text));

    /// <summary>Sends <c>SOH request LF</c> plus an optional payload and waits for the answer.</summary>
    public async Task<Answer> RequestAsync(string request, byte[]? payload = null, TimeSpan? timeout = null,
                                           CancellationToken cancellation = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(request);
        if (request.Contains('\n') || request.Contains((char)StreamSplitter.Soh))
        {
            throw new ArgumentException("A request is one line.", nameof(request));
        }

        string expected = request.Split(' ', 2)[0];
        await requestGate.WaitAsync(cancellation).ConfigureAwait(false);
        try
        {
            var completion = new TaskCompletionSource<Answer>(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (answerLock)
            {
                pending = completion;
            }

            byte[] head = Encoding.ASCII.GetBytes(request);
            byte[] message = new byte[head.Length + 2 + (payload?.Length ?? 0)];
            message[0] = StreamSplitter.Soh;
            head.CopyTo(message, 1);
            message[head.Length + 1] = (byte)'\n';
            payload?.CopyTo(message, head.Length + 2);
            transport.Write(message);

            Task finished = await Task.WhenAny(completion.Task, Task.Delay(timeout ?? DefaultTimeout, cancellation))
                                      .ConfigureAwait(false);
            if (finished != completion.Task)
            {
                lock (answerLock)
                {
                    pending = null;
                }

                cancellation.ThrowIfCancellationRequested();
                throw new LinkException($"The board did not answer '{expected}'.");
            }

            Answer answer = await completion.Task.ConfigureAwait(false);
            if (answer.Name != expected)
            {
                throw new LinkException($"The board answered '{answer.Name}' to '{expected}'.");
            }

            return answer;
        }
        finally
        {
            requestGate.Release();
        }
    }

    public void Dispose()
    {
        FailPending(new LinkException("The connection was closed."));
        transport.Dispose();
        requestGate.Dispose();
    }

    private void OnAnswer(Answer answer)
    {
        TaskCompletionSource<Answer>? completion;
        lock (answerLock)
        {
            completion = pending;
            pending = null;
        }

        if (completion is null)
        {
            Garbled?.Invoke($"unexpected answer '{answer.Name}'");
            return;
        }

        completion.TrySetResult(answer);
    }

    private void FailPending(Exception exception)
    {
        TaskCompletionSource<Answer>? completion;
        lock (answerLock)
        {
            completion = pending;
            pending = null;
        }

        completion?.TrySetException(exception);
    }
}
