package desktop

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestStartMenuCatalogResolvesFriendlyShortcutWithoutLaunching(t *testing.T) {
	root := filepath.Join(t.TempDir(), "應用程式 space")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	exe, _ := os.Executable()
	// JSON passes literal paths to PowerShell; shortcut arguments are not
	// executed or used as executable identity, including the uninstall entry.
	// WScript.Shell saves shortcuts through the legacy ANSI interface. Create
	// an ASCII fixture, then move it with Unicode file APIs. Discovery itself
	// uses Shell.Application so it works with Chinese paths on English Windows.
	input, _ := json.Marshal(map[string]string{"root": filepath.Dir(root), "exe": exe})
	script := `[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false); $data = [Console]::In.ReadToEnd() | ConvertFrom-Json; $shell = New-Object -ComObject WScript.Shell; foreach ($name in @('Browser', 'Uninstall Browser')) { $link = $shell.CreateShortcut([IO.Path]::Combine($data.root, $name + '.lnk')); $link.TargetPath = $data.exe; $link.Arguments = '--should-never-run'; $link.Save() }`
	command := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script)
	hideCommand(command)
	command.Stdin = strings.NewReader(string(input))
	if out, err := command.CombinedOutput(); err != nil {
		t.Fatalf("shortcut fixture: %s %v", out, err)
	}
	for oldName, name := range map[string]string{"Browser": "友善瀏覽器", "Uninstall Browser": "Uninstall Browser"} {
		if err := os.Rename(filepath.Join(filepath.Dir(root), oldName+".lnk"), filepath.Join(root, name+".lnk")); err != nil {
			t.Fatal(err)
		}
	}
	apps, err := startMenuApplications(context.Background(), []string{root})
	if err != nil {
		t.Fatal(err)
	}
	if len(apps) != 1 || apps[0].Name != "友善瀏覽器" || !strings.EqualFold(apps[0].Path, exe) {
		t.Fatalf("incorrect shortcut identity: %v", apps)
	}
}
