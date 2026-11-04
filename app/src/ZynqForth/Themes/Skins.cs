using System.Windows;
using System.Windows.Media;

namespace ZynqForth.Themes;

/// <summary>
/// The skins. Every skin file defines the same keys (Themes/IdeDark.xaml lists them all);
/// Styles.xaml and the windows use them as dynamic resources, so a skin switches live.
/// </summary>
public static class Skins
{
    public const string IdeDark = "IDE dark";
    public const string IdeLight = "IDE light";
    public const string GreenPhosphor = "Green phosphor";
    public const string Amber = "Amber";
    public const string LabPanel = "Lab panel";

    public static IReadOnlyList<string> Names { get; } = [IdeDark, IdeLight, GreenPhosphor, Amber, LabPanel];

    /// <summary>Raised after a skin was applied, for controls that draw themselves.</summary>
    public static event Action? Changed;

    public static string Normalize(string? name) => Names.Contains(name) ? name! : IdeDark;

    /// <summary>Whether the skin shows the board view by default.</summary>
    public static bool ShowsBoard(string name) => name == LabPanel;

    public static void Apply(Application application, string name)
    {
        ArgumentNullException.ThrowIfNull(application);
        string file = Normalize(name) switch
        {
            IdeLight => "IdeLight.xaml",
            GreenPhosphor => "GreenPhosphor.xaml",
            Amber => "Amber.xaml",
            LabPanel => "LabPanel.xaml",
            _ => "IdeDark.xaml",
        };
        var skin = new ResourceDictionary
        {
            Source = new Uri($"pack://application:,,,/ZynqDualForth32;component/Themes/{file}", UriKind.Absolute),
        };

        // the skin is the first merged dictionary, the shared styles the second
        application.Resources.MergedDictionaries[0] = skin;
        Changed?.Invoke();
    }

    public static Brush Brush(FrameworkElement element, string key, Brush fallback) =>
        element.TryFindResource(key) as Brush ?? fallback;

    public static T Value<T>(FrameworkElement element, string key, T fallback) =>
        element.TryFindResource(key) is T value ? value : fallback;
}
