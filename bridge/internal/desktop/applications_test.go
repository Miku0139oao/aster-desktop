package desktop

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestListApplicationsIncludesCurrentExecutable(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	apps, err := ListApplications(ctx)
	if err != nil {
		t.Fatal(err)
	}
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	executableInfo, err := os.Stat(exe)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	seen := map[string]bool{}
	for _, app := range apps {
		if !filepath.IsAbs(app.Path) || app.Name == "" || seen[app.Path] {
			t.Fatal("invalid or duplicate application identity")
		}
		seen[app.Path] = true
		// CI temp directories may have aliases or short Windows names. Compare
		// executable file identities rather than their textual spelling.
		if info, err := os.Stat(app.Path); err == nil && os.SameFile(info, executableInfo) {
			found = true
		}
	}
	if !found {
		t.Fatalf("current executable %q was not enumerated in %v", exe, apps)
	}
}
