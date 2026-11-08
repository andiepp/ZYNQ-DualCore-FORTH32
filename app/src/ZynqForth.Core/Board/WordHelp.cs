using System.Text.Json;
using System.Text.Json.Serialization;

namespace ZynqForth.Board;

/// <summary>One word's help, taken from the manual's word reference (tools/make_word_help.py).</summary>
public sealed record HelpEntry(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("stack")] string Stack,
    [property: JsonPropertyName("text")] string Text,
    [property: JsonPropertyName("section")] string Section,
    [property: JsonPropertyName("area")] string Area,
    [property: JsonPropertyName("related")] IReadOnlyList<string> Related,
    [property: JsonPropertyName("examples")] IReadOnlyList<string> Examples);

/// <summary>
/// The word help and its search: every term of the query must appear in a word's name, stack
/// effect, area or description; a hit in the name counts most (exact, then prefix, then
/// anywhere), then the stack effect, the area and the description.
/// </summary>
public sealed class WordHelp
{
    public const string AllAreas = "All";

    private readonly Dictionary<string, HelpEntry> byName;

    public WordHelp(IReadOnlyList<HelpEntry> entries)
    {
        Entries = entries;
        byName = new Dictionary<string, HelpEntry>(StringComparer.OrdinalIgnoreCase);
        foreach (HelpEntry e in entries)
        {
            byName.TryAdd(e.Name, e);
        }

        Areas = [AllAreas, .. entries.Select(e => e.Section).Distinct()
                                    .OrderBy(SectionOrder).Select(s => AreaOf(s))];
    }

    public IReadOnlyList<HelpEntry> Entries { get; }

    /// <summary>"All", then the manual's sections in their order (without the number).</summary>
    public IReadOnlyList<string> Areas { get; }

    public static WordHelp Parse(string json) =>
        new(JsonSerializer.Deserialize<List<HelpEntry>>(json) ?? []);

    public HelpEntry? Find(string name) => byName.GetValueOrDefault(name.Trim());

    public IReadOnlyList<HelpEntry> Search(string query, string area = AllAreas)
    {
        string[] terms = query.Split((char[])[' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
        var hits = new List<(HelpEntry Entry, int Score)>();
        foreach (HelpEntry e in Entries)
        {
            if (area != AllAreas && e.Area != area)
            {
                continue;
            }

            int score = 0;
            bool all = true;
            foreach (string t in terms)
            {
                int s = Score(e, t);
                if (s == 0)
                {
                    all = false;
                    break;
                }

                score += s;
            }

            if (all)
            {
                // the kernel's internal words (manual 5.25) after the ones meant for use
                hits.Add((e, e.Area == "Internal words" ? score - 50 : score));
            }
        }

        return [.. hits.OrderByDescending(h => h.Score).ThenBy(h => h.Entry.Name, StringComparer.OrdinalIgnoreCase)
                       .Select(h => h.Entry)];
    }

    private static int Score(HelpEntry e, string term)
    {
        const StringComparison ic = StringComparison.OrdinalIgnoreCase;
        if (e.Name.Equals(term, ic))
        {
            return 1000;
        }

        if (e.Name.StartsWith(term, ic))
        {
            return 400;
        }

        if (e.Name.Contains(term, ic))
        {
            return 200;
        }

        if (e.Stack.Contains(term, ic))
        {
            return 60;
        }

        if (e.Area.Contains(term, ic))
        {
            return 40;
        }

        int at = e.Text.IndexOf(term, ic);
        if (at < 0)
        {
            return 0;
        }

        // a whole word in the description counts a little more than a part of one
        bool start = at == 0 || !char.IsLetterOrDigit(e.Text[at - 1]);
        bool end = at + term.Length >= e.Text.Length || !char.IsLetterOrDigit(e.Text[at + term.Length]);
        return start && end ? 30 : 20;
    }

    private static double SectionOrder(string section)
    {
        string[] parts = section.Split(' ', 2)[0].Split('.');
        return parts.Length == 2 && int.TryParse(parts[0], out int a) && int.TryParse(parts[1], out int b) ? a * 100 + b : 1e9;
    }

    public static string AreaOf(string section) =>
        section.Contains(' ') && char.IsDigit(section[0]) ? section[(section.IndexOf(' ') + 1)..] : section;
}
