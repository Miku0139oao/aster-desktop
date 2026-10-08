package desktop

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"gopkg.in/yaml.v3"
)

func NewServiceCore(binary, dir string) *Core {
	core := NewCore(binary, dir)
	b, err := os.ReadFile(filepath.Join(filepath.Dir(dir), "cores", "selection.json"))
	if err == nil {
		var selection map[string]string
		if json.Unmarshal(b, &selection) == nil {
			path := selection["active"]
			if filepath.Dir(path) == filepath.Join(filepath.Dir(dir), "cores") {
				if _, err = os.Stat(path); err == nil {
					core.Binary = path
				}
			}
		}
	}
	return core
}
func UpdateServiceCore(ctx context.Context, core *Core, proxyPort int) (any, error) {
	if proxyPort != 0 && (proxyPort < 1024 || proxyPort > 65535) {
		return nil, errors.New("invalid update proxy port")
	}
	// Reuse the supervisor's core and ownership. NewApp/Close would recover its
	// proxy and stop the newly restarted TUN when this request returns.
	store, err := OpenStore(filepath.Dir(core.Dir))
	if err != nil {
		return nil, err
	}
	lock, err := lockInstance(filepath.Join(store.Dir, "desktop.lock"))
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	app := &App{Store: store, Core: core, Privileged: true, Emit: func(string, any) {}}
	core.mu.Lock()
	content, settings := core.activeContent, core.activeSettings
	core.mu.Unlock()
	if content == "" {
		// After a service restart, validate the last protected runtime too.
		if data, e := os.ReadFile(filepath.Join(core.Dir, "runtime.yaml")); e == nil {
			content = string(data)
			var runtime struct {
				Port      int    `yaml:"mixed-port"`
				Mode      string `yaml:"mode"`
				LAN       bool   `yaml:"allow-lan"`
				Interface string `yaml:"interface-name"`
				Tun       struct {
					Enable bool `yaml:"enable"`
				} `yaml:"tun"`
			}
			if err := yaml.Unmarshal(data, &runtime); err != nil {
				return nil, err
			}
			settings = DefaultSettings()
			settings.MixedPort, settings.Mode, settings.AllowLAN = runtime.Port, runtime.Mode, runtime.LAN
			settings.Tun, settings.TunInterface, settings.SystemProxy = runtime.Tun.Enable, runtime.Interface, false
		}
	}
	if content != "" {
		store.State.Profiles = []Profile{{ID: "last-runtime", Content: content}}
		store.State.ActiveID, store.State.Settings = "last-runtime", settings
	}
	if core.Status().Running {
		proxyPort = settings.MixedPort // The service always chooses its own TUN listener.
		body, err := core.Request(ctx, "GET", "/proxies", nil)
		if err != nil {
			return nil, err
		}
		var current struct {
			Proxies map[string]struct {
				Type string
				Now  string
			}
		}
		if err = json.Unmarshal(body, &current); err != nil {
			return nil, err
		}
		store.State.Selections = map[string]string{}
		for name, group := range current.Proxies {
			if group.Type == "Selector" && group.Now != "" {
				store.State.Selections[name] = group.Now
			}
		}
	}
	// The caller may supply only a bounded loopback port for its normal core.
	// Download URLs and executable paths remain exclusively service-managed.
	ctx, closeClient := updateContext(ctx, proxyPort)
	defer closeClient()
	return app.UpdateCore(ctx)
}
