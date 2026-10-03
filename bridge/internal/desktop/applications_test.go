package desktop

import (
	"context"
	"os"
	"path/filepath"
	"strings"
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
	exe, _ = filepath.EvalSymlinks(exe)
	found := false
	seen := map[string]bool{}
	for _, app := range apps {
		if !filepath.IsAbs(app.Path) || app.Name == "" || seen[app.Path] {
			t.Fatal("invalid or duplicate application identity")
		}
		seen[app.Path] = true
		if strings.EqualFold(app.Path, exe) {
			found = true
		}
	}
	if !found {
		t.Fatal("current executable was not enumerated")
	}
}
