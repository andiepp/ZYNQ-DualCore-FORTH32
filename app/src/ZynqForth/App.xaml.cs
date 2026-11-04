using System.Windows;
using ZynqForth.Simulation;
using ZynqForth.Themes;
using ZynqForth.ViewModels;
using ZynqForth.Views;

namespace ZynqForth;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var preferences = Preferences.Load();
        var viewModel = new MainViewModel(preferences);
        Skins.Apply(this, viewModel.SelectedSkin);
        MainWindow = new MainWindow(viewModel);
        MainWindow.Show();

        // ZynqDualForth32.exe [--skin <name>] [--connect [COMn|SIM]] [--core 0|1] [file.fs ...] [file.pattern]
        // A source file opens in the editor of the core named by the last --core before it (core 0 by default).
        string[] args = e.Args;
        int core = 0;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--skin" && i + 1 < args.Length)
            {
                viewModel.SelectedSkin = args[++i];
            }
            else if (args[i] == "--core" && i + 1 < args.Length && int.TryParse(args[i + 1], out int n) &&
                     n >= 0 && n < MainViewModel.CoreCount)
            {
                core = n;
                i++;
                viewModel.SelectCore(core);
            }
            else if (args[i] == "--connect")
            {
                if (i + 1 < args.Length && (args[i + 1].StartsWith("COM", StringComparison.OrdinalIgnoreCase) ||
                                            args[i + 1].Equals(SimulatedBoard.PortName, StringComparison.OrdinalIgnoreCase)))
                {
                    viewModel.SelectedPort = args[++i].ToUpperInvariant();
                }

                _ = viewModel.ToggleConnectionAsync();
            }
            else if (System.IO.File.Exists(args[i]) &&
                     args[i].EndsWith(".pattern", StringComparison.OrdinalIgnoreCase))
            {
                viewModel.Patterns.OpenFile(args[i]);
                viewModel.ShowPattern = true;
            }
            else if (System.IO.File.Exists(args[i]))
            {
                viewModel.Cores[core].Editor.OpenFile(args[i]);
            }
        }
    }
}
