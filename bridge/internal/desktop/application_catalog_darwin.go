package desktop

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func installedApplications(ctx context.Context) ([]Application, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	home, _ := os.UserHomeDir()
	apps := []Application{}
	for _, root := range []string{filepath.Join(home, "Applications"), "/Applications", "/System/Applications"} {
		_ = filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil {
				return nil
			}
			if strings.HasSuffix(path, ".app") {
				if app, ok := readApplicationBundle(ctx, path); ok {
					apps = append(apps, app)
				}
				if entry.IsDir() {
					return filepath.SkipDir
				}
			}
			// Include Applications/Utilities but avoid recursively scanning data.
			if entry.IsDir() && path != root {
				relative, _ := filepath.Rel(root, path)
				if strings.Count(relative, string(filepath.Separator)) >= 2 {
					return filepath.SkipDir
				}
			}
			return nil
		})
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	return apps, nil
}

func readApplicationBundle(ctx context.Context, bundle string) (Application, bool) {
	output, err := exec.CommandContext(ctx, "/usr/bin/plutil", "-convert", "json", "-o", "-", filepath.Join(bundle, "Contents", "Info.plist")).Output()
	if err != nil {
		return Application{}, false
	}
	var info map[string]any
	if json.Unmarshal(output, &info) != nil {
		return Application{}, false
	}
	executable, _ := info["CFBundleExecutable"].(string)
	if executable == "" || executable == "." || executable == ".." || strings.ContainsAny(executable, `/\`) {
		return Application{}, false
	}
	path, err := filepath.EvalSymlinks(filepath.Join(bundle, "Contents", "MacOS", executable))
	if err != nil {
		return Application{}, false
	}
	if file, err := os.Stat(path); err != nil || !file.Mode().IsRegular() || file.Mode().Perm()&0111 == 0 {
		return Application{}, false
	}
	name, _ := info["CFBundleDisplayName"].(string)
	if name == "" {
		name, _ = info["CFBundleName"].(string)
	}
	if name == "" {
		name = strings.TrimSuffix(filepath.Base(bundle), ".app")
	}
	return Application{Name: name, Path: path}, true
}

func describeApplication(path string) Application {
	name := filepath.Base(path)
	// Main bundle executables get human-readable names; helpers retain their
	// own identity and are available through the background-process filter.
	if index := strings.LastIndex(path, ".app/Contents/MacOS/"); index >= 0 && !strings.Contains(path[index+len(".app/Contents/MacOS/"):], "/") {
		name = filepath.Base(path[:index])
	}
	background := strings.Contains(path, "/Helpers/") || strings.Contains(path, "/Frameworks/") || !strings.Contains(path, ".app/Contents/MacOS/")
	return Application{Name: name, Background: background}
}
