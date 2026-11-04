using System.IO;
using System.Text;

namespace ZynqForth.Themes;

/// <summary>
/// The user's choices as <c>key=value</c> lines in %LocalAppData%\ZYNQ-DualCore-FORTH32\preferences.txt:
/// skin, port, board view, last file.
/// </summary>
public sealed class Preferences
{
    private readonly Dictionary<string, string> values;
    private readonly string? path;

    private Preferences(string? path, Dictionary<string, string> values)
    {
        this.path = path;
        this.values = values;
    }

    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZYNQ-DualCore-FORTH32", "preferences.txt");

    public string? this[string key]
    {
        get => values.GetValueOrDefault(key);
        set
        {
            if (value is null)
            {
                values.Remove(key);
            }
            else
            {
                values[key] = value.ReplaceLineEndings(" ");
            }

            Save();
        }
    }

    /// <summary>Preferences that are never written (tests, tools).</summary>
    public static Preferences InMemory() => new(null, []);

    public static Preferences Load(string? file = null)
    {
        file ??= DefaultPath;
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        try
        {
            if (File.Exists(file))
            {
                foreach (string line in File.ReadAllLines(file))
                {
                    int split = line.IndexOf('=');
                    if (split > 0 && !line.StartsWith('#'))
                    {
                        values[line[..split].Trim()] = line[(split + 1)..].Trim();
                    }
                }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }

        return new Preferences(file, values);
    }

    private void Save()
    {
        if (path is null)
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var text = new StringBuilder("# ZYNQ-DualCore-FORTH32 preferences\n");
            foreach ((string key, string value) in values.OrderBy(pair => pair.Key, StringComparer.Ordinal))
            {
                text.Append(key).Append('=').Append(value).Append('\n');
            }

            File.WriteAllText(path, text.ToString(), new UTF8Encoding(false));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }
}
