using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using ZynqForth.Board;

namespace ZynqForth.Views;

/// <summary>
/// Help on every Forth word, from the manual's word reference: a search over names, stack
/// effects and descriptions, an area filter, and the selected word with its stack effect,
/// description, section, related words and examples. The window stays open beside the main
/// window; it keeps its place in %LocalAppData%\ZYNQ-DualCore-FORTH32\help-window.txt.
/// </summary>
public sealed class HelpWindow : Window
{
    private static WordHelp? help;

    private readonly TextBox search;
    private readonly ComboBox area;
    private readonly ListBox list;
    private readonly StackPanel detail;
    private readonly TextBlock count;
    private readonly Action<string> insert;
    private HelpEntry? shown;

    private static string PlaceFile => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ZYNQ-DualCore-FORTH32", "help-window.txt");

    public static WordHelp Help
    {
        get
        {
            if (help is null)
            {
                using Stream? s = typeof(HelpWindow).Assembly.GetManifestResourceStream("ZynqForth.WordHelp.json");
                help = s is null ? new WordHelp([]) : WordHelp.Parse(new StreamReader(s).ReadToEnd());
            }

            return help;
        }
    }

    private sealed record Item(HelpEntry Entry)
    {
        public override string ToString() => Entry.Stack.StartsWith('(') ? $"{Entry.Name}   {Entry.Stack}" : Entry.Name;
    }

    public HelpWindow(Window owner, Action<string> insert)
    {
        Owner = owner;
        this.insert = insert;
        Title = "ZYNQ-DualCore-FORTH32 Help: Forth words";
        Width = 760;
        Height = 560;
        MinWidth = 480;
        MinHeight = 300;
        ShowInTaskbar = false;
        SetResourceReference(BackgroundProperty, "Zf.Window");
        RestorePlace();

        search = new TextBox { Margin = new Thickness(0, 0, 8, 0), ToolTip = "Words, stack effects and descriptions; several terms must all appear" };
        search.SetResourceReference(FontFamilyProperty, "Zf.CodeFont");
        search.TextChanged += (_, _) => Refresh();
        search.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Down && list!.Items.Count > 0)
            {
                list.SelectedIndex = Math.Min(list.SelectedIndex + 1, list.Items.Count - 1);
                e.Handled = true;
            }
            else if (e.Key == Key.Up && list!.Items.Count > 0)
            {
                list.SelectedIndex = Math.Max(list.SelectedIndex - 1, 0);
                e.Handled = true;
            }
            else if (e.Key == Key.Enter && shown is not null)
            {
                this.insert(shown.Name);
                e.Handled = true;
            }
        };

        area = new ComboBox { Width = 230, ItemsSource = Help.Areas, SelectedIndex = 0, ToolTip = "Only the words of one section of the manual" };
        area.SelectionChanged += (_, _) => Refresh();

        var onTop = new CheckBox { Content = "Keep on top", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0),
                                   ToolTip = "Stay above other programs too" };
        onTop.SetResourceReference(ForegroundProperty, "Zf.Text");
        onTop.Click += (_, _) => Topmost = onTop.IsChecked == true;

        var find = new TextBlock { Text = "Find", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
        find.SetResourceReference(ForegroundProperty, "Zf.Text");
        var top = new DockPanel { Margin = new Thickness(8, 8, 8, 4) };
        DockPanel.SetDock(find, Dock.Left);
        DockPanel.SetDock(onTop, Dock.Right);
        DockPanel.SetDock(area, Dock.Right);
        top.Children.Add(find);
        top.Children.Add(onTop);
        top.Children.Add(area);
        top.Children.Add(search);

        list = new ListBox { Margin = new Thickness(8, 0, 4, 0) };
        list.SetResourceReference(FontFamilyProperty, "Zf.CodeFont");
        list.SelectionChanged += (_, _) => Show((list.SelectedItem as Item)?.Entry);
        list.MouseDoubleClick += (_, _) => { if (shown is not null) { this.insert(shown.Name); } };

        detail = new StackPanel { Margin = new Thickness(10, 4, 10, 4) };
        var scroll = new ScrollViewer { Content = detail, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(4, 0, 8, 0) };
        scroll.SetResourceReference(BackgroundProperty, "Zf.Panel");

        var middle = new Grid();
        middle.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star), MinWidth = 160 });
        middle.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(3, GridUnitType.Star), MinWidth = 200 });
        Grid.SetColumn(scroll, 1);
        middle.Children.Add(list);
        middle.Children.Add(scroll);

        count = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        count.SetResourceReference(ForegroundProperty, "Zf.DimText");
        Button Make(string caption, string tip, Action click)
        {
            var b = new Button { Content = caption, ToolTip = tip, Margin = new Thickness(6, 0, 0, 0), MinWidth = 80 };
            b.Click += (_, _) => click();
            return b;
        }

        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(Make("Insert", "Add the word to the shown core's input line (Enter, double-click)", () => { if (shown is not null) { this.insert(shown.Name); } }));
        buttons.Children.Add(Make("Copy", "Copy the word and its help to the clipboard", () => { if (shown is not null) { Clipboard.SetText(AsText(shown)); } }));
        buttons.Children.Add(Make("Close", "Close the help (F2 opens it again)", Close));
        var bottom = new DockPanel { Margin = new Thickness(8, 6, 8, 8) };
        DockPanel.SetDock(buttons, Dock.Right);
        bottom.Children.Add(buttons);
        bottom.Children.Add(count);

        var root = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(top);
        root.Children.Add(bottom);
        root.Children.Add(middle);
        Content = root;

        Closing += (_, _) => SavePlace();
        Loaded += (_, _) => search.Focus();
        Refresh();
    }

    /// <summary>Shows a word: its own entry when there is one, else the search for it.</summary>
    public void ShowWord(string word)
    {
        area.SelectedIndex = 0;
        search.Text = word;
        search.CaretIndex = word.Length;
        HelpEntry? exact = Help.Find(word);
        if (exact is not null)
        {
            foreach (object o in list.Items)
            {
                if (o is Item i && i.Entry == exact)
                {
                    list.SelectedItem = o;
                    list.ScrollIntoView(o);
                    break;
                }
            }
        }

        Activate();
        search.Focus();
    }

    private void Refresh()
    {
        string a = area.SelectedItem as string ?? WordHelp.AllAreas;
        IReadOnlyList<HelpEntry> hits = Help.Search(search.Text, a);
        list.ItemsSource = hits.Select(h => new Item(h)).ToList();
        count.Text = search.Text.Trim().Length == 0 && a == WordHelp.AllAreas
            ? $"{Help.Entries.Count} words"
            : $"{hits.Count} of {Help.Entries.Count} words";
        if (list.Items.Count > 0)
        {
            list.SelectedIndex = 0;
        }
        else
        {
            Show(null);
        }
    }

    private void Show(HelpEntry? e)
    {
        shown = e;
        detail.Children.Clear();
        if (e is null)
        {
            detail.Children.Add(Text("No word matches. Words you defined yourself have no help; the Dictionary lists them.", "Zf.DimText"));
            return;
        }

        var name = Text(e.Name, "Zf.Accent", 22, bold: true, code: true);
        detail.Children.Add(name);
        if (e.Stack.Length > 0)
        {
            detail.Children.Add(Text(e.Stack, "Zf.Text", 15, code: true));
        }

        detail.Children.Add(Text("Manual " + e.Section, "Zf.DimText", 12));
        var body = Text(e.Text, "Zf.Text", 14);
        body.Margin = new Thickness(0, 10, 0, 6);
        detail.Children.Add(body);

        if (e.Related.Count > 0)
        {
            detail.Children.Add(Text("Related", "Zf.DimText", 12, bold: true));
            var wrap = new WrapPanel { Margin = new Thickness(0, 2, 0, 8) };
            foreach (string r in e.Related)
            {
                var link = new Hyperlink(new Run(r)) { Tag = r };
                link.SetResourceReference(TextElement.ForegroundProperty, "Zf.Accent");
                link.Click += (_, _) => ShowWord(r);
                var t = new TextBlock(link) { Margin = new Thickness(0, 0, 12, 2) };
                t.SetResourceReference(FontFamilyProperty, "Zf.CodeFont");
                wrap.Children.Add(t);
            }

            detail.Children.Add(wrap);
        }

        if (e.Examples.Count > 0)
        {
            detail.Children.Add(Text("Examples from the manual", "Zf.DimText", 12, bold: true));
            var ex = Text(string.Join("\n", e.Examples), "Zf.EditorText", 13, code: true);
            ex.Margin = new Thickness(0, 2, 0, 0);
            ex.TextWrapping = TextWrapping.NoWrap;
            detail.Children.Add(new Border { Child = ex, Padding = new Thickness(6), Margin = new Thickness(0, 2, 0, 4) }
                .Also(b => b.SetResourceReference(Border.BackgroundProperty, "Zf.EditorBackground")));
        }
    }

    private static TextBlock Text(string text, string brush, double size = 14, bool bold = false, bool code = false)
    {
        var t = new TextBlock { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, FontWeight = bold ? FontWeights.Bold : FontWeights.Normal };
        t.SetResourceReference(TextBlock.ForegroundProperty, brush);
        if (code)
        {
            t.SetResourceReference(TextBlock.FontFamilyProperty, "Zf.CodeFont");
        }

        return t;
    }

    private static string AsText(HelpEntry e) =>
        $"{e.Name}  {e.Stack}\n{e.Text}\n(Manual {e.Section})" +
        (e.Examples.Count > 0 ? "\n\n" + string.Join("\n", e.Examples) : "");

    private void RestorePlace()
    {
        try
        {
            string[] v = File.ReadAllText(PlaceFile).Split(' ');
            double[] n = [.. v.Select(double.Parse)];
            if (n.Length == 4 && n[2] >= MinWidth && n[3] >= MinHeight &&
                n[0] > SystemParameters.VirtualScreenLeft - 50 && n[0] < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 100 &&
                n[1] > SystemParameters.VirtualScreenTop - 50 && n[1] < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 100)
            {
                WindowStartupLocation = WindowStartupLocation.Manual;
                (Left, Top, Width, Height) = (n[0], n[1], n[2], n[3]);
                return;
            }
        }
        catch (Exception e) when (e is IOException or FormatException or UnauthorizedAccessException)
        {
        }

        WindowStartupLocation = WindowStartupLocation.CenterOwner;
    }

    private void SavePlace()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(PlaceFile)!);
            File.WriteAllText(PlaceFile, string.Join(' ', new[] { Left, Top, Width, Height }.Select(x => ((int)x).ToString())));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
        }
    }
}

internal static class FluentExtensions
{
    public static T Also<T>(this T value, Action<T> action)
    {
        action(value);
        return value;
    }
}
