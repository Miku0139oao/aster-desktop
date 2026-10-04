//go:build !windows && !darwin

package desktop

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func applicationPaths(ctx context.Context) ([]string, error) {
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
