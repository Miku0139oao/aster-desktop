package desktop

import (
	"context"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"
)

type Application struct {
	Name       string `json:"name"`
	Path       string `json:"path"`
	Running    bool   `json:"running"`
	Installed  bool   `json:"installed"`
	Background bool   `json:"background"`
	Icon       string `json:"icon,omitempty"`
}

var applicationCatalogCache struct {
	sync.Mutex
	updated time.Time
	apps    []Application
}

// Catalog discovery never launches an application. Keep it separate from the
// live process snapshot so refresh still reports accurate running state.
func cachedApplicationCatalog(ctx context.Context) []Application {
	applicationCatalogCache.Lock()
	defer applicationCatalogCache.Unlock()
	if time.Since(applicationCatalogCache.updated) < 30*time.Second {
		return applicationCatalogCache.apps
	}
	apps, err := installedApplications(ctx)
	if err == nil {
		applicationCatalogCache.apps = apps
	}
	applicationCatalogCache.updated = time.Now()
	return applicationCatalogCache.apps
}

func applicationIdentity(path string) string {
	path = filepath.Clean(path)
	if runtime.GOOS == "windows" {
		return strings.ToLower(path)
	}
	return path
}

// Read executable identities only, never command-line arguments or environment.
func ListApplications(ctx context.Context) ([]Application, error) {
	paths, err := applicationPaths(ctx)
	if err != nil {
		return nil, err
	}
	return mergeApplications(paths, cachedApplicationCatalog(ctx)), nil
}

func mergeApplications(paths []string, catalog []Application) []Application {
	seen := make(map[string]int)
	apps := []Application{}
	for _, app := range catalog {
		key := applicationIdentity(app.Path)
		if !filepath.IsAbs(app.Path) || app.Name == "" {
			continue
		}
		if _, exists := seen[key]; exists {
			continue
		}
		app.Installed, app.Running, app.Background = true, false, false
		seen[key] = len(apps)
		apps = append(apps, app)
	}
	for _, path := range paths {
		if !filepath.IsAbs(path) {
			continue
		}
		key := applicationIdentity(path)
		if index, exists := seen[key]; exists {
			// The kernel identity is the path the core will see (aliases matter).
			apps[index].Path, apps[index].Running = path, true
			continue
		}
		app := describeApplication(path)
		app.Path, app.Running = path, true
		seen[key] = len(apps)
		apps = append(apps, app)
	}
	sort.Slice(apps, func(i, j int) bool {
		if strings.EqualFold(apps[i].Name, apps[j].Name) {
			return apps[i].Path < apps[j].Path
		}
		return strings.ToLower(apps[i].Name) < strings.ToLower(apps[j].Name)
	})
	return apps
}
