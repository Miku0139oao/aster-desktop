//go:build !windows

package desktop

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestApplicationEnumerationChild(t *testing.T) {
	if os.Getenv("ASTER_ENUMERATION_CHILD") != "1" {
		return
	}
	fmt.Println("ready")
	_, _ = io.Copy(io.Discard, os.Stdin)
}

func TestApplicationEnumerationResolvesActualExecutable(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "Routing App With Spaces")
	if err := os.WriteFile(path, data, 0700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	child := exec.CommandContext(ctx, path, "-test.run=^TestApplicationEnumerationChild$")
	child.Args[0] = "different-argv-zero"
	child.Env = append(os.Environ(), "ASTER_ENUMERATION_CHILD=1")
	input, err := child.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = input.Close(); _ = child.Wait() })
	line, err := bufio.NewReader(output).ReadString('\n')
	if err != nil || line != "ready\n" {
		t.Fatalf("child did not become ready: %q, %v", line, err)
	}
	apps, err := ListApplications(ctx)
	if err != nil {
		t.Fatal(err)
	}
	wanted, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	for _, app := range apps {
		if actual, err := os.Stat(app.Path); err == nil && os.SameFile(actual, wanted) {
			return
		}
	}
	t.Fatal("application with spaces and different argv[0] was not enumerated")
}
