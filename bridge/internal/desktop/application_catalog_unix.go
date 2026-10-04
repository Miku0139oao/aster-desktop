//go:build !windows && !darwin

package desktop

import (
	"bufio"
	"context"
	"encoding/base64"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func installedApplications(ctx context.Context) ([]Application, error) {
	home, _ := os.UserHomeDir()
	dataHome := os.Getenv("XDG_DATA_HOME")
	if dataHome == "" {
		dataHome = filepath.Join(home, ".local", "share")
	}
	dataDirs := os.Getenv("XDG_DATA_DIRS")
	if dataDirs == "" {
		dataDirs = "/usr/local/share:/usr/share"
	}
	roots := append([]string{dataHome}, filepath.SplitList(dataDirs)...)
	apps := []Application{}
	seen := map[string]bool{}
	for _, root := range roots {
		_ = filepath.WalkDir(filepath.Join(root, "applications"), func(path string, entry os.DirEntry, err error) error {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if err != nil || entry.IsDir() || !strings.HasSuffix(path, ".desktop") {
				return nil
			}
			rel, _ := filepath.Rel(filepath.Join(root, "applications"), path)
			id := strings.ReplaceAll(rel, string(filepath.Separator), "-")
			if seen[id] {
				return nil
			}
			seen[id] = true // Hidden user entries override the system entry too.
			content, err := os.ReadFile(path)
			if err != nil || len(content) > 256*1024 {
				return nil
			}
			if app, ok := desktopApplication(string(content)); ok {
				app.Icon = desktopIcon(desktopEntry(string(content))["Icon"], roots)
				apps = append(apps, app)
			}
			return nil
		})
	}
	return apps, ctx.Err()
}

func desktopEntry(content string) map[string]string {
	values := map[string]string{}
	active := false
	scanner := bufio.NewScanner(strings.NewReader(content))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "[") {
			active = line == "[Desktop Entry]"
			continue
		}
		if !active || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if ok {
			values[strings.TrimSpace(key)] = strings.TrimSpace(value)
		}
	}
	return values
}

func desktopApplication(content string) (Application, bool) {
	values := desktopEntry(content)
	if values["Type"] != "Application" || values["Hidden"] == "true" || values["NoDisplay"] == "true" || values["Terminal"] == "true" {
		return Application{}, false
	}
	executable, ok := desktopExecutable(values["Exec"])
	if !ok {
		return Application{}, false
	}
	if !filepath.IsAbs(executable) {
		var err error
		executable, err = exec.LookPath(executable)
		if err != nil {
			return Application{}, false
		}
	}
	path, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return Application{}, false
	}
	// A launcher script, flatpak or a shell is not the application's process
	// identity. Do not silently create an ineffective (or overly broad) rule.
	file, err := os.Open(path)
	if err != nil {
		return Application{}, false
	}
	defer file.Close()
	var magic [4]byte
	if _, err := io.ReadFull(file, magic[:]); err != nil || string(magic[:]) != "\x7fELF" {
		return Application{}, false
	}
	if info, err := file.Stat(); err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0111 == 0 {
		return Application{}, false
	}
	name := values["Name"]
	locale := strings.Split(strings.Split(os.Getenv("LANG"), ".")[0], "@")[0]
	if localized := values["Name["+locale+"]"]; localized != "" {
		name = localized
	} else if localized := values["Name["+strings.Split(locale, "_")[0]+"]"]; localized != "" {
		name = localized
	}
	if name == "" {
		return Application{}, false
	}
	return Application{Name: name, Path: path}, true
}

// Parse only the executable token with Desktop Entry quoting, not shell syntax.
func desktopExecutable(command string) (string, bool) {
	command = strings.TrimSpace(command)
	var result strings.Builder
	quoted, escaped := false, false
	for _, r := range command {
		if escaped {
			result.WriteRune(r)
			escaped = false
			continue
		}
		if r == '\\' {
			escaped = true
			continue
		}
		if r == '"' {
			quoted = !quoted
			continue
		}
		if !quoted && (r == ' ' || r == '\t') {
			break
		}
		result.WriteRune(r)
	}
	value := result.String()
	base := filepath.Base(value)
	if value == "" || quoted || escaped || strings.ContainsAny(value, "%\x00\n\r") {
		return "", false
	}
	for _, wrapper := range []string{"env", "sh", "bash", "dash", "zsh", "flatpak", "snap", "python", "python3", "wine"} {
		if base == wrapper {
			return "", false
		}
	}
	return value, true
}

func desktopIcon(icon string, roots []string) string {
	paths := []string{}
	if filepath.IsAbs(icon) {
		paths = append(paths, icon)
	} else if icon != "" && !strings.ContainsAny(icon, `/\`) {
		for _, root := range roots {
			for _, size := range []string{"48x48", "32x32"} {
				paths = append(paths, filepath.Join(root, "icons", "hicolor", size, "apps", icon+".png"))
			}
			paths = append(paths, filepath.Join(root, "pixmaps", icon+".png"))
		}
	}
	for _, path := range paths {
		if filepath.Ext(path) != ".png" {
			continue
		}
		if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() || info.Size() > 32768 {
			continue
		}
		if bytes, err := os.ReadFile(path); err == nil {
			return base64.StdEncoding.EncodeToString(bytes)
		}
	}
	return ""
}

func describeApplication(path string) Application {
	return Application{Name: filepath.Base(path), Background: true}
}
