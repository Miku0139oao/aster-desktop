//go:build !windows

package desktop

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

func applicationPaths(ctx context.Context) ([]string, error) {
	if runtime.GOOS == "darwin" {
		ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		output, err := exec.CommandContext(ctx, "/bin/ps", "-axww", "-o", "comm=").Output()
		if err != nil {
			return nil, err
		}
		paths := []string{}
		for _, line := range strings.Split(string(output), "\n") {
			if path := strings.TrimSpace(line); filepath.IsAbs(path) {
				// ps reports argv[0], which can use /var while the actual
				// executable and core process lookup resolve /private/var.
				if resolved, err := filepath.EvalSymlinks(path); err == nil {
					paths = append(paths, resolved)
				}
			}
		}
		return paths, nil
	}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	paths := []string{}
	for _, entry := range entries {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if _, err := strconv.Atoi(entry.Name()); err != nil {
			continue
		}
		path, err := os.Readlink(filepath.Join("/proc", entry.Name(), "exe"))
		if err == nil && !strings.HasSuffix(path, " (deleted)") {
			paths = append(paths, path)
		}
	}
	return paths, nil
}
