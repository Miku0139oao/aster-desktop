package desktop

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"testing"
)

// gomobile builds for Android and iOS cannot take the -ldflags injection the
// desktop scripts use, so the default must always equal pubspec.yaml.
func TestVersionMatchesPubspec(t *testing.T) {
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate the test source")
	}
	root := filepath.Join(filepath.Dir(file), "..", "..", "..")
	manifest, err := os.ReadFile(filepath.Join(root, "pubspec.yaml"))
	if err != nil {
		t.Fatalf("read pubspec.yaml: %v", err)
	}
	match := regexp.MustCompile(`(?m)^version:\s*([^+\s]+)\+\d+\s*$`).FindStringSubmatch(string(manifest))
	if match == nil {
		t.Fatal("pubspec.yaml has no version")
	}
	if Version != match[1] {
		t.Fatalf("desktop.Version is %q but pubspec.yaml says %q; update model.go together with pubspec.yaml", Version, match[1])
	}
}
