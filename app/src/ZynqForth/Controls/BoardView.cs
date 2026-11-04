using System.Globalization;
using System.Windows;
using System.Windows.Media;
using ZynqForth.Board;
using ZynqForth.Themes;

namespace ZynqForth.Controls;

/// <summary>
/// The Arty Z7-20 as Forth sees it: LD0..LD3, the RGB LEDs, BTN0..BTN3, SW0/SW1, the shield
/// pins (level, direction, PWM), the analog readings and the pattern generator's Pmod pins. Drawn at a fixed size; put it in
/// a Viewbox to scale it. Colours come from the skin (Zf.Board*, Zf.Led*, Zf.Pin*).
/// </summary>
public sealed class BoardView : FrameworkElement
{
    public static readonly DependencyProperty StateProperty = DependencyProperty.Register(
        nameof(State), typeof(BoardState), typeof(BoardView),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    private const double Width0 = 960;
    private const double Height0 = 210;
    private const double Pitch = 23;

    public BoardView()
    {
        Loaded += (_, _) => Skins.Changed += InvalidateVisual;
        Unloaded += (_, _) => Skins.Changed -= InvalidateVisual;
    }

    public BoardState? State
    {
        get => (BoardState?)GetValue(StateProperty);
        set => SetValue(StateProperty, value);
    }

    protected override Size MeasureOverride(Size availableSize) => new(Width0, Height0);

    protected override void OnRender(DrawingContext dc)
    {
        Brush pcb = Skins.Brush(this, "Zf.BoardPcb", Brushes.DarkGreen);
        Brush text = Skins.Brush(this, "Zf.BoardText", Brushes.White);
        Brush border = Skins.Brush(this, "Zf.Border", Brushes.Black);
        var outline = new Pen(border, 1);
        BoardState? s = State;

        dc.DrawRoundedRectangle(pcb, outline, new Rect(0.5, 0.5, Width0 - 1, Height0 - 1), 10, 10);
        Label(dc, "ARTY Z7-20 · HF32 FORTH", 16, 12, text, 13, bold: true);
        if (s is null)
        {
            Label(dc, "not connected", Width0 - 16, 12, Skins.Brush(this, "Zf.DimText", Brushes.Gray), 12, align: TextAlignment.Right);
        }

        DrawBoardIo(dc, s, text, outline);
        DrawShield(dc, s, text, outline);
        DrawPmods(dc, s, text, outline);
    }

    /// <summary>Pmod JA (channels 0..7) and JB (8..15) as the generator drives them.</summary>
    private void DrawPmods(DrawingContext dc, BoardState? s, Brush text, Pen outline)
    {
        Brush driven = Skins.Brush(this, "Zf.PinDriven", Brushes.OrangeRed);
        Brush drivenLow = Skins.Brush(this, "Zf.PinDrivenLow", Brushes.Maroon);
        Brush off = Skins.Brush(this, "Zf.PinLow", Brushes.DimGray);
        Brush pcb = Skins.Brush(this, "Zf.BoardPcb", Brushes.DarkGreen);
        PatternStatus? pg = s?.Pattern;

        const double left = 826;
        Label(dc, "PMOD · PATTERN", left - 20, 34, text, 10);
        foreach ((string name, int first, double y) in new[] { ("JA", 0, 56.0), ("JB", 8, 112.0) })
        {
            Label(dc, name, left - 20, y + 11, text, 10);
            // as on the board: VCC (pins 6/12) and GND (5/11) at the left, then pins 4..1 over 10..7
            for (int row = 0; row < 2; row++)
            {
                for (int col = 0; col < 6; col++)
                {
                    var rect = new Rect(left + col * 22, y + row * 22, 18, 18);
                    if (col < 2)
                    {
                        dc.DrawRectangle(pcb, outline, rect);
                        Label(dc, col == 1 ? "G" : "V", rect.X + 9, rect.Y + 3, text, 9, align: TextAlignment.Center);
                        continue;
                    }

                    int channel = first + row * 4 + (5 - col);
                    bool enabled = pg is not null && (pg.Enabled & (1 << channel)) != 0;
                    bool level = pg is not null && (pg.Levels & (1 << channel)) != 0;
                    dc.DrawRectangle(!enabled ? off : level ? driven : drivenLow, outline, rect);
                    Label(dc, channel.ToString(CultureInfo.InvariantCulture), rect.X + 9, rect.Y + 3, text, 9,
                          align: TextAlignment.Center);
                }
            }
        }

        if (s is not null)
        {
            Label(dc, pg is null ? "pattern generator: firmware 2.2 needed" : "pattern " + pg.Summary,
                  Width0 - 16, 164, text, 11, align: TextAlignment.Right);
        }
    }

    private void DrawBoardIo(DrawingContext dc, BoardState? s, Brush text, Pen outline)
    {
        Brush ledOn = Skins.Brush(this, "Zf.LedOn", Brushes.Lime);
        Brush ledOff = Skins.Brush(this, "Zf.LedOff", Brushes.DimGray);
        Brush cap = Skins.Brush(this, "Zf.ButtonCap", Brushes.Gray);
        Brush capPressed = Skins.Brush(this, "Zf.ButtonCapPressed", Brushes.DodgerBlue);

        // LD3..LD0 as on the board, highest at the left
        double x = 20, y = 52;
        Label(dc, "LEDS", x, y - 18, text, 10);
        for (int i = 3; i >= 0; i--)
        {
            bool on = s is not null && (s.Leds & (1 << i)) != 0;
            var rect = new Rect(x, y, 22, 11);
            if (on)
            {
                dc.DrawRoundedRectangle(null, new Pen(WithOpacity(ledOn, 0.4), 5), Inflate(rect, 1), 3, 3);
            }

            dc.DrawRoundedRectangle(on ? ledOn : ledOff, outline, rect, 2, 2);
            Label(dc, "LD" + i, x + 11, y + 15, text, 10, align: TextAlignment.Center);
            x += 34;
        }

        // RGB LD5 and LD4
        x = 166;
        Label(dc, "RGB", x, y - 18, text, 10);
        foreach (int led in new[] { 5, 4 })
        {
            int bits = s is null ? 0 : (s.Rgb >> (led == 4 ? 0 : 3)) & 7;
            Brush fill = bits == 0
                ? ledOff
                : new SolidColorBrush(Color.FromRgb((byte)((bits & 1) != 0 ? 255 : 30),
                                                    (byte)((bits & 2) != 0 ? 230 : 30),
                                                    (byte)((bits & 4) != 0 ? 255 : 30)));
            var centre = new Point(x + 11, y + 6);
            if (bits != 0)
            {
                dc.DrawEllipse(null, new Pen(WithOpacity(fill, 0.45), 5), centre, 12, 12);
            }

            dc.DrawEllipse(fill, outline, centre, 9, 9);
            Label(dc, "LD" + led, x + 11, y + 15, text, 10, align: TextAlignment.Center);
            x += 36;
        }

        // buttons BTN3..BTN0 and switches SW1, SW0
        x = 20;
        y = 120;
        Label(dc, "BUTTONS", x, y - 22, text, 10);
        for (int i = 3; i >= 0; i--)
        {
            bool pressed = s is not null && (s.Buttons & (1 << i)) != 0;
            var centre = new Point(x + 12, y + 8);
            dc.DrawRectangle(Skins.Brush(this, "Zf.LedOff", Brushes.DimGray), outline, new Rect(x, y - 4, 24, 24));
            dc.DrawEllipse(pressed ? capPressed : cap, outline, centre, 8, 8);
            Label(dc, "BTN" + i, x + 12, y + 24, text, 10, align: TextAlignment.Center);
            x += 34;
        }

        x = 166;
        Label(dc, "SWITCHES", x, y - 22, text, 10);
        for (int i = 1; i >= 0; i--)
        {
            bool on = s is not null && (s.Switches & (1 << i)) != 0;
            var slot = new Rect(x + 4, y - 6, 14, 28);
            dc.DrawRoundedRectangle(Skins.Brush(this, "Zf.LedOff", Brushes.DimGray), outline, slot, 3, 3);
            dc.DrawRoundedRectangle(on ? capPressed : cap, outline, new Rect(x + 5, on ? y - 5 : y + 8, 12, 13), 2, 2);
            Label(dc, "SW" + i, x + 11, y + 24, text, 10, align: TextAlignment.Center);
            x += 36;
        }

        // chip temperature and supplies
        if (s is not null)
        {
            Label(dc, string.Create(CultureInfo.InvariantCulture, $"XC7Z020  {s.Temperature:0.0} °C"), 20, 164, text, 11);
            Label(dc, string.Create(CultureInfo.InvariantCulture, $"VCCINT {s.VccInt:0.00} V  VCCAUX {s.VccAux:0.00} V"),
                  20, 182, text, 11);
        }
    }

    private void DrawShield(DrawingContext dc, BoardState? s, Brush text, Pen outline)
    {
        Brush high = Skins.Brush(this, "Zf.PinHigh", Brushes.SkyBlue);
        Brush low = Skins.Brush(this, "Zf.PinLow", Brushes.DimGray);
        Brush driven = Skins.Brush(this, "Zf.PinDriven", Brushes.OrangeRed);
        Brush drivenLow = Skins.Brush(this, "Zf.PinDrivenLow", Brushes.Maroon);
        Brush pwm = Skins.Brush(this, "Zf.PinPwm", Brushes.Orchid);

        double left = 300;
        Label(dc, "SHIELD", left, 34, text, 10);
        Legend(dc, left + 60, 34, [(high, "in 1"), (low, "in 0"), (driven, "out 1"), (drivenLow, "out 0"), (pwm, "function")], text, outline);

        // upper row IO0..IO13 then A0..A5, lower row IO26..IO41 (as the shield headers), then
        // SCL, SDA and the SPI header's pins
        int[] upper = [.. Enumerable.Range(0, 20)];
        int[] lower = [.. Enumerable.Range(26, 16)];
        int[] extra = [.. Enumerable.Range(42, 6)];
        DrawPinRow(dc, s, upper, left, 70, text, outline, high, low, driven, drivenLow, pwm);
        DrawPinRow(dc, s, lower, left, 128, text, outline, high, low, driven, drivenLow, pwm);
        DrawPinRow(dc, s, extra, left + 16 * Pitch + 4, 128, text, outline, high, low, driven, drivenLow, pwm,
                   pitch: 22, labelSize: 8, functionBelow: true);

        if (s is null)
        {
            return;
        }

        // the analog values under A0..A5, the differential pairs and the PWM channels
        for (int a = 0; a < 6; a++)
        {
            double cx = left + (14 + a) * Pitch + 8;
            Label(dc, s.Analog(a).ToString("0.00", CultureInfo.InvariantCulture), cx, 104, text, 9, align: TextAlignment.Center);
        }

        string pairs = string.Create(CultureInfo.InvariantCulture,
            $"A6/A7 {s.Analog(6):0.000} V   A8/A9 {s.Analog(7):0.000} V   A10/A11 {s.Analog(8):0.000} V");
        Label(dc, pairs, left, 182, text, 11);

        var channels = new List<string>();
        for (int c = 0; c < 4; c++)
        {
            if ((s.PwmEnabled & (1 << c)) != 0)
            {
                channels.Add($"PWM{c} → {BoardState.Label(s.PwmPins[c])}");
            }
        }

        if (s.ToneOn)
        {
            channels.Add("tone on");
        }

        Label(dc, channels.Count == 0 ? "PWM off" : string.Join("   ", channels), Width0 - 16, 182, text, 11,
              align: TextAlignment.Right);
    }

    private void DrawPinRow(DrawingContext dc, BoardState? s, int[] pins, double left, double y, Brush text, Pen outline,
                            Brush high, Brush low, Brush driven, Brush drivenLow, Brush pwm,
                            double pitch = Pitch, double labelSize = 9, bool functionBelow = false)
    {
        for (int i = 0; i < pins.Length; i++)
        {
            int number = pins[i];
            ShieldPin? pin = s?.Pins.FirstOrDefault(p => p.Number == number);
            double x = left + i * pitch;
            Brush fill = pin is null ? low
                : pin.PwmChannel is not null || pin.Function is not null ? pwm
                : pin.Driven ? (pin.Level ? driven : drivenLow)
                : pin.Level ? high : low;
            var rect = new Rect(x, y, 16, 16);
            dc.DrawRectangle(fill, outline, rect);
            dc.DrawEllipse(Skins.Brush(this, "Zf.BoardPcb", Brushes.DarkGreen), null, new Point(x + 8, y + 8), 3, 3);
            if (pin?.PwmChannel is int channel)
            {
                Label(dc, "~" + channel, x + 8, y - 13, text, 9, align: TextAlignment.Center);
            }
            else if (pin?.Function is string function && !(functionBelow && function == BoardState.Label(number)))
            {
                // the narrow SCL/SDA/SPI header pins carry it under their name, staggered
                double ly = functionBelow ? y + 30 + (i % 2) * 10 : y - 12;
                Label(dc, function, x + 8, ly, text, 8, align: TextAlignment.Center);
            }

            Label(dc, BoardState.Label(number), x + 8, y + 19, text, labelSize, align: TextAlignment.Center);
        }
    }

    private void Legend(DrawingContext dc, double x, double y, (Brush Brush, string Text)[] items, Brush text, Pen outline)
    {
        foreach ((Brush brush, string label) in items)
        {
            dc.DrawRectangle(brush, outline, new Rect(x, y + 2, 10, 10));
            FormattedText formatted = Format(label, text, 10, false);
            dc.DrawText(formatted, new Point(x + 14, y));
            x += 22 + formatted.Width;
        }
    }

    private void Label(DrawingContext dc, string value, double x, double y, Brush brush, double size,
                       bool bold = false, TextAlignment align = TextAlignment.Left)
    {
        FormattedText formatted = Format(value, brush, size, bold);
        formatted.TextAlignment = align;
        dc.DrawText(formatted, new Point(x, y));
    }

    private FormattedText Format(string value, Brush brush, double size, bool bold)
    {
        var family = Skins.Value(this, "Zf.UiFont", new FontFamily("Segoe UI"));
        var typeface = new Typeface(family, FontStyles.Normal, bold ? FontWeights.SemiBold : FontWeights.Normal, FontStretches.Normal);
        return new FormattedText(value, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, typeface, size, brush,
                                 VisualTreeHelper.GetDpi(this).PixelsPerDip);
    }

    private static Rect Inflate(Rect rect, double by)
    {
        rect.Inflate(by, by);
        return rect;
    }

    private static Brush WithOpacity(Brush brush, double opacity)
    {
        Brush copy = brush.Clone();
        copy.Opacity = opacity;
        copy.Freeze();
        return copy;
    }
}
