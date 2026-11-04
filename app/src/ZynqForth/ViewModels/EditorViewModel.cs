using System.IO;
using System.Text;

namespace ZynqForth.ViewModels;

/// <summary>File dialogs and questions, provided by the window.</summary>
public interface IUserDialogs
{
    string? OpenFile(string title, string filter);

    string? SaveFile(string title, string filter, string suggestedName);

    bool Confirm(string title, string message);

    /// <summary>Yes = true, No = false, Cancel = null.</summary>
    bool? YesNoCancel(string title, string message);
}

/// <summary>The source editor: the text, its file and whether it changed since the last save.</summary>
public sealed class EditorViewModel : ObservableObject
{
    public const string Filter = "Forth source (*.fs;*.fth;*.4th;*.f)|*.fs;*.fth;*.4th;*.f|Text (*.txt)|*.txt|All files (*.*)|*.*";

    private string text = "";
    private string? filePath;
    private bool isModified;

    public EditorViewModel()
    {
        NewCommand = new RelayCommand(() => { if (ConfirmDiscard()) { New(); } });
        OpenCommand = new RelayCommand(Open);
        SaveCommand = new RelayCommand(() => Save());
        SaveAsCommand = new RelayCommand(() => SaveAs());
    }

    public IUserDialogs? Dialogs { get; set; }

    /// <summary>Messages for the status line.</summary>
    public event Action<string, bool>? Message;

    public string Text
    {
        get => text;
        set
        {
            if (Set(ref text, value))
            {
                IsModified = true;
            }
        }
    }

    public string? FilePath
    {
        get => filePath;
        private set
        {
            if (Set(ref filePath, value))
            {
                OnPropertyChanged(nameof(Title));
            }
        }
    }

    public bool IsModified
    {
        get => isModified;
        private set
        {
            if (Set(ref isModified, value))
            {
                OnPropertyChanged(nameof(Title));
            }
        }
    }

    public string Title => (FilePath is null ? "untitled.fs" : Path.GetFileName(FilePath)) + (IsModified ? " *" : "");

    public RelayCommand NewCommand { get; }

    public RelayCommand OpenCommand { get; }

    public RelayCommand SaveCommand { get; }

    public RelayCommand SaveAsCommand { get; }

    public void New()
    {
        Text = "";
        FilePath = null;
        IsModified = false;
    }

    /// <summary>Replaces the text, e.g. with the board's saved source.</summary>
    public void Load(string newText, string? path)
    {
        Text = newText;
        FilePath = path;
        IsModified = path is null && newText.Length > 0;
    }

    public void OpenFile(string path)
    {
        try
        {
            Load(File.ReadAllText(path), path);
            IsModified = false;
            Message?.Invoke($"Opened {path}", false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            Message?.Invoke($"Cannot open {path}: {exception.Message}", true);
        }
    }

    /// <summary>Asks to save unsaved changes; false when the user cancels.</summary>
    public bool ConfirmDiscard()
    {
        if (!IsModified || Dialogs is null)
        {
            return true;
        }

        return Dialogs.YesNoCancel("ZYNQ-DualCore-FORTH32", $"Save the changes to {Title.TrimEnd(' ', '*')}?") switch
        {
            true => Save(),
            false => true,
            null => false,
        };
    }

    public bool Save() => FilePath is null ? SaveAs() : WriteTo(FilePath);

    public bool SaveAs()
    {
        string? path = Dialogs?.SaveFile("Save Forth source", Filter, FilePath is null ? "untitled.fs" : Path.GetFileName(FilePath));
        return path is not null && WriteTo(path);
    }

    private void Open()
    {
        if (!ConfirmDiscard())
        {
            return;
        }

        string? path = Dialogs?.OpenFile("Open Forth source", Filter);
        if (path is not null)
        {
            OpenFile(path);
        }
    }

    private bool WriteTo(string path)
    {
        try
        {
            File.WriteAllText(path, Text, new UTF8Encoding(false));
            FilePath = path;
            IsModified = false;
            Message?.Invoke($"Saved {path}", false);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            Message?.Invoke($"Cannot save {path}: {exception.Message}", true);
            return false;
        }
    }
}
