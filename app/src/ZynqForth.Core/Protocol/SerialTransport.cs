using System.IO.Ports;

namespace ZynqForth.Protocol;

/// <summary>A byte stream to the board.</summary>
public interface IByteTransport : IDisposable
{
    /// <summary>Raised on a background thread for every chunk received.</summary>
    event Action<ReadOnlyMemory<byte>>? Received;

    event Action<Exception>? Faulted;

    string Name { get; }

    void Open();

    /// <summary>Writes the bytes as one piece: writes from several threads never interleave.</summary>
    void Write(ReadOnlySpan<byte> bytes);
}

/// <summary>The Arty Z7's USB UART: 115200 8N1, no handshake.</summary>
public sealed class SerialTransport : IByteTransport
{
    public const int BaudRate = 115200;

    private readonly SerialPort port;
    private readonly Lock writeLock = new();
    private CancellationTokenSource? reading;
    private Thread? reader;
    private bool disposed;

    public SerialTransport(string portName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(portName);
        port = new SerialPort(portName, BaudRate, Parity.None, 8, StopBits.One)
        {
            Handshake = Handshake.None,
            DtrEnable = false,
            RtsEnable = false,
            ReadTimeout = SerialPort.InfiniteTimeout,
            WriteTimeout = 10000,
            ReadBufferSize = 256 * 1024,
        };
    }

    public event Action<ReadOnlyMemory<byte>>? Received;

    public event Action<Exception>? Faulted;

    public string Name => port.PortName;

    /// <summary>The serial ports Windows knows now, sorted by number.</summary>
    public static IReadOnlyList<string> PortNames() =>
        [.. SerialPort.GetPortNames().Distinct().OrderBy(PortNumber).ThenBy(name => name, StringComparer.Ordinal)];

    public void Open()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        port.Open();
        port.DiscardInBuffer();
        reading = new CancellationTokenSource();
        reader = new Thread(() => ReadLoop(reading.Token)) { IsBackground = true, Name = $"{port.PortName} reader" };
        reader.Start();
    }

    public void Write(ReadOnlySpan<byte> bytes)
    {
        lock (writeLock)
        {
            port.BaseStream.Write(bytes);
            port.BaseStream.Flush();
        }
    }

    public void Dispose()
    {
        if (disposed)
        {
            return;
        }

        disposed = true;
        reading?.Cancel();
        try
        {
            port.Close();
        }
        catch (IOException)
        {
        }

        port.Dispose();
        reader?.Join(500);
        reading?.Dispose();
    }

    private void ReadLoop(CancellationToken cancellation)
    {
        byte[] buffer = new byte[8192];
        try
        {
            while (!cancellation.IsCancellationRequested)
            {
                int count = port.BaseStream.Read(buffer, 0, buffer.Length);
                if (count > 0)
                {
                    Received?.Invoke(buffer.AsMemory(0, count));
                }
            }
        }
        catch (Exception exception) when (exception is IOException or InvalidOperationException
                                              or UnauthorizedAccessException or OperationCanceledException)
        {
            if (!disposed)
            {
                Faulted?.Invoke(exception);
            }
        }
    }

    private static int PortNumber(string name) =>
        name.StartsWith("COM", StringComparison.OrdinalIgnoreCase) && int.TryParse(name.AsSpan(3), out int number)
            ? number
            : int.MaxValue;
}
