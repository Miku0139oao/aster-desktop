package desktop

import (
	"context"
	"path/filepath"
	"sort"
	"strings"
)

type Application struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

// Read executable identities only, never command-line arguments or environment.
func ListApplications(ctx context.Context) ([]Application, error) {
	paths, err := applicationPaths(ctx)
	if err != nil {
		return nil, err
	}
	seen := make(map[string]bool)
	apps := []Application{}
	for _, path := range paths {
		if !filepath.IsAbs(path) || seen[path] {
			continue
		}
		seen[path] = true
		name := filepath.Base(path)
		name = strings.TrimSuffix(name, ".exe")
		apps = append(apps, Application{Name: name, Path: path})
	}
	sort.Slice(apps, func(i, j int) bool {
		if strings.EqualFold(apps[i].Name, apps[j].Name) {
			return apps[i].Path < apps[j].Path
		}
		return strings.ToLower(apps[i].Name) < strings.ToLower(apps[j].Name)
	})
	return apps, nil
}
