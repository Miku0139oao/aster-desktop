//go:build !windows && !darwin

package desktop

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestDesktopCatalogLocalNamesSymlinksAndHiddenOverrides(t *testing.T) {
	root := t.TempDir()
	user, system := filepath.Join(root, "user"), filepath.Join(root, "system")
	for _, dir := range []string{user, system} {
		if err := os.MkdirAll(filepath.Join(dir, "applications"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("XDG_DATA_HOME", user)
	t.Setenv("XDG_DATA_DIRS", system)
	t.Setenv("LANG", "zh_TW.UTF-8")
	exe, _ := os.Executable()
	alias := filepath.Join(root, "瀏覽器 with space")
	if err := os.Symlink(exe, alias); err != nil {
		t.Fatal(err)
	}
	entry := "[Desktop Entry]\nType=Application\nName=Friendly Browser\nName[zh_TW]=友善瀏覽器\nExec=\"" + alias + "\" --never-execute %U\n"
	for path, content := range map[string]string{
		filepath.Join(system, "applications", "browser.desktop"): entry,
		filepath.Join(system, "applications", "hidden.desktop"):  entry,
		filepath.Join(user, "applications", "hidden.desktop"):    "[Desktop Entry]\nHidden=true\n",
		filepath.Join(system, "applications", "wrapper.desktop"): "[Desktop Entry]\nType=Application\nName=Wrong Identity\nExec=sh -c 'anything'\n",
	} {
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	apps, err := installedApplications(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	actual, _ := filepath.EvalSymlinks(exe)
	if len(apps) != 1 || apps[0].Name != "友善瀏覽器" || apps[0].Path != actual {
		t.Fatalf("incorrect desktop catalog: %v", apps)
	}
}

func TestDesktopExecutableRejectsLaunchWrappersAndMalformedQuotes(t *testing.T) {
	for _, command := range []string{`env FOO=bar browser`, `sh -c browser`, `flatpak run browser`, `"unfinished`, `browser%f`, "browser\x00"} {
		if _, ok := desktopExecutable(command); ok {
			t.Fatalf("unsafe or unresolvable identity accepted: %q", command)
		}
	}
	if path, ok := desktopExecutable(`"/opt/Browser With Spaces/browser" %U`); !ok || path != "/opt/Browser With Spaces/browser" {
		t.Fatalf("quoted identity lost: %q %v", path, ok)
	}
}
