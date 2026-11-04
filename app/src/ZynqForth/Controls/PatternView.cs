using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using ZynqForth.Patterns;
using ZynqForth.Themes;
using ZynqForth.ViewModels;

namespace ZynqForth.Controls;

/// <summary>
/// The pattern as a timing diagram: an idle column (the levels while stopped), then one column
/// per step, the column width growing with the logarithm of the duration, one row per channel.
/// Repeats are brackets above the steps, wait steps carry a T. Click the header to select steps
/// (Shift extends), click or drag in a row to set levels, click the idle column to switch a
/// channel's idle level. Colours come from the skin.
/// </summary>
public sealed class PatternView : FrameworkElement
{
    public const double RowHeight = 20;

    public static readonly DependencyProperty EditorProperty = DependencyProperty.Register(
        nameof(Editor), typeof(PatternEditorViewModel), typeof(PatternView),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsMeasure, OnEditorChanged));

    private const double BracketStep = 12;
    private const double HeaderHeight = 30;
    private const double IdleWidth = 40;

    /// <summary>The step number <see cref="Hit"/> gives the idle column.</summary>
    private const int IdleColumn = -2;

    private bool? paint;                        // the level a drag paints
    private (int Step, int Channel) lastCell = (-1, -1);

    public PatternView()
    {
        Focusable = true;
        FocusVisualStyle = null;
        Loaded += (_, _) => Skins.Changed += InvalidateVisual;
        Unloaded += (_, _) => Skins.Changed -= InvalidateVisual;
    }

    public PatternEditorViewModel? Editor
    {
        get => (PatternEditorViewModel?)GetValue(EditorProperty);
        set => SetValue(EditorProperty, value);
    }

    /// <summary>The space above the first channel row (brackets and header).</summary>
    public static double TopOf(Pattern pattern) => BracketStep * Math.Max(1, MaxDepth(pattern)) + HeaderHeight;

    private static void OnEditorChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (PatternView)d;
        if (e.OldValue is PatternEditorViewModel old)
        {
            old.Changed -= view.Refresh;
        }

        if (e.NewValue is PatternEditorViewModel editor)
        {
            editor.Changed += view.Refresh;
        }
    }

    private void Refresh()
    {
        InvalidateMeasure();
        InvalidateVisual();
    }

    private static double ColumnWidth(long ticks) => 36 + 14 * Math.Log10(Math.Max(1, ticks));

    private static int MaxDepth(Pattern pattern) =>
        pattern.Repeats.Count == 0 ? 0 : pattern.Repeats.Max(r => Depth(pattern, r));

    /// <summary>1 for an outermost repeat, 2 inside one, ...</summary>
    private static int Depth(Pattern pattern, PatternRepeat r) =>
        pattern.Repeats.Count(o => o.First <= r.First && r.Last <= o.Last);

    private double[] ColumnEdges(Pattern pattern)
    {
        var edges = new double[pattern.Steps.Count + 1];
        edges[0] = IdleWidth;
        for (int i = 0; i < pattern.Steps.Count; i++)
        {
            edges[i + 1] = edges[i] + ColumnWidth(pattern.Steps[i].Ticks);
        }

        return edges;
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        if (Editor?.Pattern is not { } pattern)
        {
            return new Size(0, 0);
        }

        return new Size(ColumnEdges(pattern)[^1] + 110, TopOf(pattern) + Pattern.ChannelCount * RowHeight + 8);
    }

    protected override void OnRender(DrawingContext dc)
    {
        if (Editor is not { } editor)
        {
            return;
        }

        Pattern pattern = editor.Pattern;
        Brush background = Skins.Brush(this, "Zf.EditorBackground", Brushes.Black);
        Brush text = Skins.Brush(this, "Zf.EditorText", Brushes.White);
        Brush dim = Skins.Brush(this, "Zf.DimText", Brushes.Gray);
        Brush accent = Skins.Brush(this, "Zf.Accent", Brushes.DodgerBlue);
        Brush selection = Skins.Brush(this, "Zf.Selection", Brushes.DarkSlateBlue);
        Brush warning = Skins.Brush(this, "Zf.Warning", Brushes.Goldenrod);
        var grid = new Pen(Skins.Brush(this, "Zf.Border", Brushes.DimGray), 1);
        double[] x = ColumnEdges(pattern);
        double top = TopOf(pattern);
        double bottom = top + Pattern.ChannelCount * RowHeight;

        dc.DrawRectangle(background, null, new Rect(0, 0, ActualWidth, ActualHeight));

        // selected and playing steps
        if (editor.HasSelection)
        {
            dc.DrawRectangle(selection, null,
                new Rect(x[editor.SelectionFirst], top - HeaderHeight, x[editor.SelectionLast + 1] - x[editor.SelectionFirst],
                         bottom - top + HeaderHeight));
        }

        if (editor.PlayingStep is int playing && playing < pattern.Steps.Count)
        {
            var mark = new StreamGeometry();
            using (StreamGeometryContext g = mark.Open())
            {
                double cx = (x[playing] + x[playing + 1]) / 2;
                g.BeginFigure(new Point(cx - 6, top - HeaderHeight), true, true);
                g.LineTo(new Point(cx + 6, top - HeaderHeight), false, false);
                g.LineTo(new Point(cx, top - HeaderHeight + 7), false, false);
            }

            dc.DrawGeometry(warning, null, mark);
        }

        // repeat brackets, outermost highest
        foreach (PatternRepeat r in pattern.Repeats.Where(r => r.First >= 0 && r.Last < pattern.Steps.Count && r.First <= r.Last))
        {
            double y = (Depth(pattern, r) - 1) * BracketStep + 9;
            double x0 = x[r.First] + 3, x1 = x[r.Last + 1] - 3;
            var pen = new Pen(accent, 1.5);
            dc.DrawLine(pen, new Point(x0, y + 4), new Point(x0, y));
            dc.DrawLine(pen, new Point(x0, y), new Point(x1, y));
            dc.DrawLine(pen, new Point(x1, y), new Point(x1, y + 4));
            FormattedText count = Format(r.Count == 0 ? "×∞" : "×" + r.Count, accent, 10, true);
            var box = new Rect((x0 + x1 - count.Width) / 2 - 2, y - 7, count.Width + 4, 12);
            dc.DrawRectangle(background, null, box);
            dc.DrawText(count, new Point(box.X + 2, y - 7));
        }

        // header: step number, duration, wait mark; then the grid
        for (int i = 0; i < pattern.Steps.Count; i++)
        {
            PatternStep step = pattern.Steps[i];
            double cx = (x[i] + x[i + 1]) / 2;
            Center(dc, (step.Wait ? "T " : "") + i, cx, top - HeaderHeight + 2, step.Wait ? warning : text, 10, step.Wait);
            Center(dc, Durations.Format(step.Ticks), cx, top - HeaderHeight + 15, dim, 9, false);
            dc.DrawLine(grid, new Point(x[i], top - HeaderHeight), new Point(x[i], bottom));
        }

        dc.DrawLine(grid, new Point(x[^1], top - HeaderHeight), new Point(x[^1], bottom));
        dc.DrawRectangle(WithOpacity(dim, 0.10), null, new Rect(0, top - HeaderHeight, IdleWidth, bottom - top + HeaderHeight));
        Center(dc, "idle", IdleWidth / 2, top - HeaderHeight + 8, dim, 10, false);
        string end = pattern.End == PatternEnd.Stop ? "end: idle" : $"↺ step {pattern.RestartAt}";
        dc.DrawText(Format(end, dim, 10, false), new Point(x[^1] + 6, top - HeaderHeight + 8));

        // the waveforms
        for (int c = 0; c < Pattern.ChannelCount; c++)
        {
            double y0 = top + c * RowHeight;
            dc.DrawLine(grid, new Point(0, y0 + RowHeight), new Point(x[^1], y0 + RowHeight));
            bool enabled = (pattern.Enabled & (1 << c)) != 0;
            var pen = new Pen(enabled ? accent : dim, enabled ? 1.6 : 1);
            Brush fill = WithOpacity(enabled ? accent : dim, 0.18);
            double high = y0 + 4, low = y0 + RowHeight - 4;
            var dashed = new Pen(dim, 1) { DashStyle = DashStyles.Dash };

            // before the start: the idle level; the edge into step 0 is a real one
            bool idle = (pattern.Idle & (1 << c)) != 0;
            dc.DrawLine(dashed, new Point(4, idle ? high : low), new Point(x[0], idle ? high : low));
            bool? previous = idle;
            for (int i = 0; i < pattern.Steps.Count; i++)
            {
                bool level = (pattern.Steps[i].Levels & (1 << c)) != 0;
                double y = level ? high : low;
                if (level)
                {
                    dc.DrawRectangle(fill, null, new Rect(x[i], high, x[i + 1] - x[i], low - high));
                }

                if (previous is bool p && p != level)
                {
                    dc.DrawLine(pen, new Point(x[i], high), new Point(x[i], low));
                }

                dc.DrawLine(pen, new Point(x[i], y), new Point(x[i + 1], y));
                previous = level;
            }

            // what follows the last step
            bool after = pattern.End == PatternEnd.Stop
                ? (pattern.Idle & (1 << c)) != 0
                : pattern.RestartAt < pattern.Steps.Count && (pattern.Steps[pattern.RestartAt].Levels & (1 << c)) != 0;
            if (previous is bool last && last != after)
            {
                dc.DrawLine(dashed, new Point(x[^1], high), new Point(x[^1], low));
            }

            dc.DrawLine(dashed, new Point(x[^1], after ? high : low), new Point(x[^1] + 24, after ? high : low));
        }
    }

    // ---------------------------------------------------------------------------------
    // Mouse and keys
    // ---------------------------------------------------------------------------------

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        Focus();
        if (Editor is not { } editor || Hit(e.GetPosition(this)) is not { } hit)
        {
            return;
        }

        (int step, int channel) = hit;
        if (step == IdleColumn)
        {
            if (channel >= 0)
            {
                editor.ToggleIdle(channel);
            }

            return;
        }

        if (step < 0)
        {
            return;
        }

        if (channel < 0)
        {
            editor.Select(step, Keyboard.Modifiers.HasFlag(ModifierKeys.Shift));
            return;
        }

        editor.Snapshot();
        paint = !editor.Level(step, channel);
        lastCell = (step, channel);
        editor.SetLevel(step, channel, paint.Value);
        CaptureMouse();
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (paint is not bool level || Editor is not { } editor || Hit(e.GetPosition(this)) is not { } hit ||
            hit.Step < 0 || hit.Channel < 0 || hit == lastCell)
        {
            return;
        }

        lastCell = hit;
        editor.SetLevel(hit.Step, hit.Channel, level);
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        paint = null;
        ReleaseMouseCapture();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        if (Editor is not { } editor)
        {
            return;
        }

        bool shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        bool control = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        switch (e.Key)
        {
            case Key.Left:
                editor.Select(shift ? editor.SelectionLast - 1 : editor.SelectionFirst - 1, shift);
                break;
            case Key.Right:
                editor.Select(editor.SelectionLast + 1, shift);
                break;
            case Key.Delete:
                Execute(editor.DeleteCommand);
                break;
            case Key.Insert:
                Execute(editor.InsertCommand);
                break;
            case Key.D when control:
                Execute(editor.DuplicateCommand);
                break;
            case Key.Z when control:
                Execute(editor.UndoCommand);
                break;
            default:
                return;
        }

        e.Handled = true;
    }

    private static void Execute(ICommand command)
    {
        if (command.CanExecute(null))
        {
            command.Execute(null);
        }
    }

    /// <summary>The step and channel under a point; channel -1 = the header above the rows.</summary>
    private (int Step, int Channel)? Hit(Point point)
    {
        if (Editor?.Pattern is not { } pattern)
        {
            return null;
        }

        double[] x = ColumnEdges(pattern);
        double top = TopOf(pattern);
        int channel = point.Y < top ? -1 : (int)((point.Y - top) / RowHeight);
        if (channel >= Pattern.ChannelCount)
        {
            return (-1, -1);
        }

        if (point.X < IdleWidth)
        {
            return (IdleColumn, channel);
        }

        int step = Array.FindIndex(x, 1, e => point.X < e) - 1;
        return step < 0 || step >= pattern.Steps.Count ? (-1, -1) : (step, channel);
    }

    private void Center(DrawingContext dc, string value, double cx, double y, Brush brush, double size, bool bold)
    {
        FormattedText formatted = Format(value, brush, size, bold);
        dc.DrawText(formatted, new Point(cx - formatted.Width / 2, y));
    }

    private FormattedText Format(string value, Brush brush, double size, bool bold)
    {
        var family = Skins.Value(this, "Zf.UiFont", new FontFamily("Segoe UI"));
        var typeface = new Typeface(family, FontStyles.Normal, bold ? FontWeights.SemiBold : FontWeights.Normal, FontStretches.Normal);
        return new FormattedText(value, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, typeface, size, brush,
                                 VisualTreeHelper.GetDpi(this).PixelsPerDip);
    }

    private static Brush WithOpacity(Brush brush, double opacity)
    {
        Brush copy = brush.Clone();
        copy.Opacity = opacity;
        copy.Freeze();
        return copy;
    }
}
