using System.Text.RegularExpressions;
using ZynqForth.Board;

namespace ZynqForth.Tests;

/// <summary>The word help built from the manual (app/src/ZynqForth/Help/words.json) and its search.</summary>
public class HelpTests
{
    private static readonly Lazy<WordHelp> Help = new(() =>
        WordHelp.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Help", "words.json"))));

    [Fact]
    public void EveryColonDefinitionOfTheKernelHasHelp()
    {
        // tools/make_word_help.py checks all of the kernel's words; this repeats it for the
        // colon definitions, in case words.json was not regenerated after a kernel change
        string? dir = AppContext.BaseDirectory;
        while (dir is not null && !File.Exists(Path.Combine(dir, "forth", "kernel.fs")))
        {
            dir = Path.GetDirectoryName(dir);
        }

        Assert.NotNull(dir);
        string kernel = File.ReadAllText(Path.Combine(dir!, "forth", "kernel.fs"));
        string[] names = [.. Regex.Matches(kernel, @"^: (\S+)", RegexOptions.Multiline).Select(m => m.Groups[1].Value).Distinct()];
        Assert.True(names.Length > 300, $"only {names.Length} colon definitions found");
        string[] missing = [.. names.Where(n => Help.Value.Find(n) is null)];
        Assert.True(missing.Length == 0, string.Join(" ", missing));
    }

    [Fact]
    public void EntriesCarryTheManualsText()
    {
        HelpEntry e = Help.Value.Find("uart-open")!;
        Assert.Equal("( baud tx rx u -- )", e.Stack);
        Assert.StartsWith("5.16", e.Section);
        Assert.Contains("baud rate", e.Text);
        Assert.Contains("uart-close", e.Related);
        Assert.Contains(e.Examples, x => x.Contains("uart-open"));
        Assert.NotNull(Help.Value.Find("DUP"));          // names are case-insensitive, as in Forth
    }

    [Fact]
    public void FloatAndTwoCoreWordsAreThere()
    {
        HelpEntry fsqrt = Help.Value.Find("fsqrt")!;
        Assert.Equal("Floating point", fsqrt.Area);
        Assert.Contains("F:", fsqrt.Stack);
        HelpEntry send = Help.Value.Find("send")!;
        Assert.Equal("Two cores", send.Area);
        Assert.Contains("receive", send.Related);
        Assert.Contains(send.Examples, x => x.Contains("send"));
        Assert.DoesNotContain('`', Help.Value.Find("f.")!.Text);     // code spans become plain text
        Assert.Equal(Help.Value.Find("loop")!.Related.Count, Help.Value.Find("loop")!.Related.Distinct().Count());
    }

    [Fact]
    public void NameMatchesComeFirst()
    {
        IReadOnlyList<HelpEntry> hits = Help.Value.Search("dup");
        Assert.Equal("dup", hits[0].Name);
        Assert.Contains(hits, h => h.Name == "?dup");
        Assert.Contains(hits, h => h.Name == "2dup");
        Assert.Contains(hits, h => h.Name == "fdup");
        int firstOther = hits.ToList().FindIndex(h => !h.Name.Contains("dup"));
        Assert.True(firstOther < 0 || hits.Take(firstOther).All(h => h.Name.Contains("dup")));
    }

    [Fact]
    public void DescriptionsAreSearchedToo()
    {
        Assert.Contains(Help.Value.Search("baud"), h => h.Name == "uart-open");
        Assert.Contains(Help.Value.Search("mailbox"), h => h.Name == "send");
        Assert.Equal("uart-open", Help.Value.Search("uart baud")[0].Name);     // all terms must match
        Assert.Empty(Help.Value.Search("uart xyzzy"));
    }

    [Fact]
    public void AreasFilterTheSearch()
    {
        Assert.Equal(WordHelp.AllAreas, Help.Value.Areas[0]);
        Assert.True(Help.Value.Areas.ToList().IndexOf("Data stack") < Help.Value.Areas.ToList().IndexOf("Serial interfaces"));
        Assert.Equal("Two cores", Help.Value.Areas[^1]);
        IReadOnlyList<HelpEntry> hits = Help.Value.Search("", "Serial interfaces");
        Assert.All(hits, h => Assert.Equal("Serial interfaces", h.Area));
        Assert.Contains(hits, h => h.Name == "i2c-scan");
    }

    [Fact]
    public void InternalWordsComeAfterTheOnesMeantForUse()
    {
        // both have "i2c" inside the name; the kernel's helper comes after the word meant for use
        List<HelpEntry> hits = [.. Help.Value.Search("i2c")];
        Assert.True(hits.FindIndex(h => h.Name == "i2c-scan") < hits.FindIndex(h => h.Name == "(i2c)"));
        Assert.Equal("Internal words", Help.Value.Find("(i2c)")!.Area);
    }
}
