// Collect Go module versions and upstream license texts for binary bundles.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type module struct {
	Path, Version, Dir string
	Main               bool
}

func main() {
	core := flag.String("core", "", "pinned core source directory")
	out := flag.String("out", ".build/third-party", "notice output directory")
	flag.Parse()
	if err := collect(*core, *out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func collect(core, out string) error {
	if err := os.MkdirAll(out, 0755); err != nil {
		return err
	}
	modules := map[string]module{}
	for _, dir := range []string{"bridge", core} {
		target := "."
		if dir == "bridge" {
			target = "./cmd/aster-bridge"
		}
		command := exec.Command("go", "list", "-deps", "-tags", "with_gvisor", "-json", target)
		command.Dir = dir
		data, err := command.Output()
		if err != nil {
			return fmt.Errorf("module list in %s: %w", dir, err)
		}
		decoder := json.NewDecoder(strings.NewReader(string(data)))
		for {
			var pkg struct{ Module *module }
			if err = decoder.Decode(&pkg); err == io.EOF {
				break
			}
			if err != nil {
				return err
			}
			if pkg.Module == nil {
				continue
			}
			m := *pkg.Module
			if !m.Main || dir == core {
				modules[m.Path+"@"+m.Version] = m
			}
		}
	}
	for key, m := range modules {
		if m.Dir == "" {
			continue
		}
		dest := filepath.Join(out, strings.NewReplacer("/", "_", "\\", "_", "@", "_").Replace(key))
		found := false
		err := filepath.WalkDir(m.Dir, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			name := strings.ToUpper(entry.Name())
			if !entry.IsDir() && (strings.HasPrefix(name, "LICENSE") || strings.HasPrefix(name, "COPYING") || strings.HasPrefix(name, "NOTICE")) {
				relative, _ := filepath.Rel(m.Dir, path)
				target := filepath.Join(dest, relative)
				if err = os.MkdirAll(filepath.Dir(target), 0755); err != nil {
					return err
				}
				data, err := os.ReadFile(path)
				if err != nil {
					return err
				}
				if err = os.WriteFile(target, data, 0644); err != nil {
					return err
				}
				found = true
			}
			return nil
		})
		if err != nil {
			return err
		}
		if !found {
			return fmt.Errorf("no root license text for %s", key)
		}
	}
	for key, m := range modules {
		m.Dir = ""
		modules[key] = m
	}
	data, err := json.MarshalIndent(modules, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(out, "modules.json"), data, 0644)
}
