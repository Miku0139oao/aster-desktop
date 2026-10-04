package desktop

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestApplicationBundleCatalogUsesRealExecutableAndDisplayName(t *testing.T) {
	bundle := filepath.Join(t.TempDir(), "Friendly App.app")
	bin := filepath.Join(bundle, "Contents", "MacOS")
	if err := os.MkdirAll(bin, 0700); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(bin, "actual-process")
	if err := os.WriteFile(executable, []byte("fixture"), 0700); err != nil {
		t.Fatal(err)
	}
	plist := `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleDisplayName</key><string>友善應用程式</string><key>CFBundleExecutable</key><string>actual-process</string></dict></plist>`
	info := filepath.Join(bundle, "Contents", "Info.plist")
	if err := os.WriteFile(info, []byte(plist), 0600); err != nil {
		t.Fatal(err)
	}
	app, ok := readApplicationBundle(context.Background(), bundle)
	actual, _ := filepath.EvalSymlinks(executable)
	if !ok || app.Name != "友善應用程式" || app.Path != actual {
		t.Fatalf("incorrect app identity: %v %v", app, ok)
	}
	bad := `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>../outside</string></dict></plist>`
	if err := os.WriteFile(info, []byte(bad), 0600); err != nil {
		t.Fatal(err)
	}
	if _, ok := readApplicationBundle(context.Background(), bundle); ok {
		t.Fatal("bundle executable traversal accepted")
	}
}
