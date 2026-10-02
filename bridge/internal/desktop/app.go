package desktop

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"gopkg.in/yaml.v3"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Request struct {
	ID     int             `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}
type RPCError struct {
	Message string `json:"message"`
	Code    string `json:"code"`
}
type Response struct {
	ID     int       `json:"id"`
	Result any       `json:"result,omitempty"`
	Error  *RPCError `json:"error,omitempty"`
}
type App struct {
	mu           sync.Mutex
	Store        *Store
	Core         *Core
	Emit         func(string, any)
	Privileged   bool
	remote       *ServiceClient
	Binary       string
	GUIPath      string
	instanceLock *os.File
}

func NewApp(dir, binary, gui string) (*App, error) {
	s, err := OpenStore(dir)
	if err != nil {
		return nil, err
	}
	lock, err := lockInstance(filepath.Join(dir, "desktop.lock"))
	if err != nil {
		return nil, err
	}
	core := NewCore(binary, filepath.Join(dir, "runtime"))
	a := &App{Store: s, Core: core, Binary: binary, GUIPath: gui, instanceLock: lock, Emit: func(string, any) {}}
	if err = core.RecoverProxy(); err != nil {
		core.appendLog("Proxy recovery: " + err.Error())
	}
	return a, nil
}
func decode(p json.RawMessage, v any) error {
	if len(p) == 0 {
		return nil
	}
	return json.Unmarshal(p, v)
}
func (a *App) status() CoreStatus {
	if a.remote != nil {
		var status CoreStatus
		if err := a.remote.Call("status", nil, &status); err != nil {
			return CoreStatus{Error: err.Error()}
		}
		return status
	}
	return a.Core.Status()
}
func (a *App) stop() error {
	var err error
	if a.remote != nil {
		err = a.remote.Call("stop", nil, nil)
		a.remote.Close()
		a.remote = nil
	}
	if ce := a.Core.Stop(); ce != nil {
		err = ce
	}
	return err
}
func (a *App) Close() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	err := a.stop()
	if a.instanceLock != nil {
		_ = a.instanceLock.Close()
		a.instanceLock = nil
	}
	return err
}
func (a *App) dispatchCore(ctx context.Context, method, path string, body any) (json.RawMessage, error) {
	if a.remote != nil {
		var result json.RawMessage
		err := a.remote.Call("controller", map[string]any{"method": method, "path": path, "body": body}, &result)
		return result, err
	}
	return a.Core.Request(ctx, method, path, body)
}
func allowedController(method, path string) bool {
	u, err := url.Parse(path)
	if err != nil || u.Host != "" || u.Fragment != "" || strings.Contains(u.Path, "..") || strings.Contains(u.Path, "\\") {
		return false
	}
	p := u.Path
	if method == "GET" {
		for _, prefix := range []string{"/version", "/configs", "/memory", "/proxies", "/group", "/rules", "/connections", "/providers/proxies", "/providers/rules"} {
			if p == prefix || strings.HasPrefix(p, prefix+"/") {
				return true
			}
		}
	}
	if method == "PUT" {
		return strings.HasPrefix(p, "/proxies/") || strings.HasPrefix(p, "/providers/proxies/") || strings.HasPrefix(p, "/providers/rules/")
	}
	if method == "DELETE" {
		return strings.HasPrefix(p, "/connections/") || strings.HasPrefix(p, "/proxies/")
	}
	return method == "PATCH" && p == "/rules/disable"
}
func (a *App) Dispatch(ctx context.Context, req Request) (result any, dispatchError error) {
	a.mu.Lock()
	defer func() {
		if dispatchError == nil {
			b, err := json.Marshal(result)
			if err != nil {
				dispatchError = err
			} else {
				result = json.RawMessage(b)
			}
		}
		a.mu.Unlock()
	}()
	s := a.Store
	switch req.Method {
	case "state":
		return map[string]any{"state": s.State, "core": a.status(), "desktopVersion": Version, "coreCommit": CoreCommit, "service": ServiceStatus()}, nil
	case "settings":
		var next Settings
		if err := decode(req.Params, &next); err != nil {
			return nil, err
		}
		if err := next.Validate(); err != nil {
			return nil, err
		}
		old := s.State.Settings
		if a.status().Running {
			if next.Tun != old.Tun || next.MixedPort != old.MixedPort || next.SystemProxy != old.SystemProxy {
				return nil, errors.New("disconnect before changing how applications connect")
			}
			p, err := s.Profile(s.State.ActiveID)
			if err != nil {
				return nil, err
			}
			if next.Mode != old.Mode || next.AllowLAN != old.AllowLAN {
				if err = a.apply(ctx, p.Content, next); err != nil {
					return nil, err
				}
			}
		}
		if next.AutoStart != old.AutoStart {
			if err := SetAutoStart(next.AutoStart, a.GUIPath); err != nil {
				if a.status().Running {
					if p, e := s.Profile(s.State.ActiveID); e == nil {
						_ = a.apply(ctx, p.Content, old)
					}
				}
				return nil, err
			}
		}
		s.State.Settings = next
		if err := s.Save(); err != nil {
			s.State.Settings = old
			if old.AutoStart != next.AutoStart {
				_ = SetAutoStart(old.AutoStart, a.GUIPath)
			}
			if a.status().Running {
				if p, e := s.Profile(s.State.ActiveID); e == nil {
					_ = a.apply(ctx, p.Content, old)
				}
			}
			return nil, err
		}
		return next, nil
	case "import":
		var p struct{ Name, Content, URL, File string }
		if err := decode(req.Params, &p); err != nil {
			return nil, err
		}
		usage := ""
		if p.URL != "" {
			var err error
			p.Content, usage, err = FetchSubscription(ctx, p.URL)
			if err != nil {
				return nil, err
			}
		}
		if p.File != "" {
			b, err := os.ReadFile(p.File)
			if err != nil {
				return nil, err
			}
			p.Content = string(b)
		}
		result, err := Import([]byte(p.Content))
		if err != nil {
			return nil, err
		}
		result.Content, err = InlineLocalProviders(result.Content, p.File)
		if err != nil {
			return nil, err
		}
		if _, err = a.Core.Validate(ctx, result.Content, s.State.Settings, false); err != nil {
			return nil, err
		}
		if strings.TrimSpace(p.Name) == "" {
			p.Name = fmt.Sprintf("Configuration %d", len(s.State.Profiles)+1)
		}
		profile := Profile{ID: RandomID(), Name: p.Name, Content: result.Content, URL: p.URL, Updated: time.Now().UTC(), Warnings: result.Warnings, Usage: usage}
		s.State.Profiles = append(s.State.Profiles, profile)
		if s.State.ActiveID == "" {
			s.State.ActiveID = profile.ID
		}
		if err = s.Save(); err != nil {
			s.State.Profiles = s.State.Profiles[:len(s.State.Profiles)-1]
			if s.State.ActiveID == profile.ID {
				s.State.ActiveID = ""
			}
			return nil, err
		}
		return profile, nil
	case "refresh":
		var p struct{ ID string }
		if err := decode(req.Params, &p); err != nil {
			return nil, err
		}
		profile, err := s.Profile(p.ID)
		if err != nil {
			return nil, err
		}
		if profile.URL == "" {
			return nil, errors.New("this configuration has no subscription URL")
		}
		content, usage, err := FetchSubscription(ctx, profile.URL)
		if err != nil {
			profile.LastError = err.Error()
			_ = s.Save()
			return nil, err
		}
		result, err := Import([]byte(content))
		if err != nil {
			return nil, err
		}
		if _, err = a.Core.Validate(ctx, result.Content, s.State.Settings, false); err != nil {
			return nil, err
		}
		if s.State.ActiveID == p.ID {
			if err = a.apply(ctx, result.Content, s.State.Settings); err != nil {
				return nil, err
			}
		}
		old := *profile
		profile.Content = result.Content
		profile.Updated = time.Now().UTC()
		profile.Warnings = result.Warnings
		profile.Usage = usage
		profile.LastError = ""
		if err = s.Save(); err != nil {
			*profile = old
			_ = a.apply(ctx, old.Content, s.State.Settings)
			return nil, err
		}
		return profile, nil
	case "activate":
		var p struct{ ID string }
		if err := decode(req.Params, &p); err != nil {
			return nil, err
		}
		profile, err := s.Profile(p.ID)
		if err != nil {
			return nil, err
		}
		if err = a.apply(ctx, profile.Content, s.State.Settings); err != nil {
			return nil, err
		}
		old := s.State.ActiveID
		s.State.ActiveID = p.ID
		if err = s.Save(); err != nil {
			s.State.ActiveID = old
			if before, e := s.Profile(old); e == nil {
				_ = a.apply(ctx, before.Content, s.State.Settings)
			}
			return nil, err
		}
		return profile, nil
	case "deleteProfile":
		var p struct{ ID string }
		if err := decode(req.Params, &p); err != nil {
			return nil, err
		}
		if p.ID == s.State.ActiveID && a.status().Running {
			return nil, errors.New("disconnect before deleting the active configuration")
		}
		for i, pf := range s.State.Profiles {
			if pf.ID == p.ID {
				previous := s.State
				s.State.Profiles = append(append([]Profile{}, s.State.Profiles[:i]...), s.State.Profiles[i+1:]...)
				if s.State.ActiveID == p.ID {
					s.State.ActiveID = ""
					if len(s.State.Profiles) > 0 {
						s.State.ActiveID = s.State.Profiles[0].ID
					}
				}
				if err := s.Save(); err != nil {
					s.State = previous
					return nil, err
				}
				return true, nil
			}
		}
		return nil, errors.New("configuration not found")
	case "edit", "validate", "restore", "patchProfile":
		var p struct {
			ID, Content, Rule string
			Changes           map[string]any
		}
		if err := decode(req.Params, &p); err != nil {
			return nil, err
		}
		profile, err := s.Profile(p.ID)
		if err != nil {
			return nil, err
		}
		if req.Method == "patchProfile" {
			var doc map[string]any
			if err = yaml.Unmarshal([]byte(profile.Content), &doc); err != nil {
				return nil, err
			}
			mergeConfig(doc, p.Changes)
			if p.Rule != "" {
				rules, _ := doc["rules"].([]any)
				doc["rules"] = append([]any{p.Rule}, rules...)
			}
			b, err := yaml.Marshal(doc)
			if err != nil {
				return nil, err
			}
			p.Content = string(b)
		}
		if req.Method == "restore" {
			b, err := os.ReadFile(filepath.Join(s.Dir, "backup-"+safeName(p.ID)+".yaml"))
			if err != nil {
				return nil, errors.New("no previous configuration backup available")
			}
			p.Content = string(b)
		}
		if _, err = a.Core.Validate(ctx, p.Content, s.State.Settings, false); err != nil {
			return nil, err
		}
		if req.Method == "validate" {
			return true, nil
		}
		if s.State.ActiveID == p.ID {
			if err = a.apply(ctx, p.Content, s.State.Settings); err != nil {
				return nil, err
			}
		}
		old := *profile
		if err = AtomicWrite(filepath.Join(s.Dir, "backup-"+safeName(p.ID)+".yaml"), []byte(profile.Content), 0600); err != nil {
			_ = a.apply(ctx, old.Content, s.State.Settings)
			return nil, err
		}
		profile.Content = p.Content
		profile.Updated = time.Now().UTC()
		if err = s.Save(); err != nil {
			*profile = old
			_ = a.apply(ctx, old.Content, s.State.Settings)
			return nil, err
		}
		return profile, nil
	case "connect":
		var options struct{ SkipSystemProxy bool }
		if err := decode(req.Params, &options); err != nil {
			return nil, err
		}
		profile, err := s.Profile(s.State.ActiveID)
		if err != nil {
			return nil, errors.New("import a subscription or configuration before connecting")
		}
		if a.status().Running {
			return a.status(), nil
		}
		if a.remote != nil {
			a.remote.Close()
			a.remote = nil
		}
		settings := s.State.Settings
		if settings.Tun {
			remote, err := ConnectService()
			if err != nil {
				return nil, errors.New("install and approve the background service to proxy all applications")
			}
			a.remote = remote
			if err = remote.Call("start", map[string]any{"content": profile.Content, "settings": settings}, nil); err != nil {
				remote.Close()
				a.remote = nil
				return nil, err
			}
		} else {
			if err = a.Core.Start(ctx, profile.Content, settings, false); err != nil {
				return nil, err
			}
		}
		if settings.SystemProxy && !settings.Tun && !options.SkipSystemProxy {
			if err = a.Core.EnableProxy(settings.MixedPort); err != nil {
				_ = a.stop()
				return nil, err
			}
		}
		for group, node := range s.State.Selections {
			_, _ = a.dispatchCore(ctx, "PUT", "/proxies/"+url.PathEscape(group), map[string]string{"name": node})
		}
		a.beginStreams()
		return a.status(), nil
	case "disconnect":
		return true, a.stop()
	case "controller":
		var p struct {
			Method, Path string
			Body         any
		}
		if err := decode(req.Params, &p); err != nil {
			return nil, err
		}
		if !allowedController(p.Method, p.Path) {
			return nil, errors.New("unsupported controller operation")
		}
		result, err := a.dispatchCore(ctx, p.Method, p.Path, p.Body)
		if err == nil && p.Method == "PUT" && strings.HasPrefix(p.Path, "/proxies/") {
			if body, ok := p.Body.(map[string]any); ok {
				if name, ok := body["name"].(string); ok {
					group, _ := url.PathUnescape(strings.TrimPrefix(strings.Split(p.Path, "?")[0], "/proxies/"))
					s.State.Selections[group] = name
					_ = s.Save()
				}
			}
		}
		return result, err
	case "rememberSelection":
		// macOS routes controller operations through the authenticated XPC helper.
		var p struct{ Group, Name string }
		if err := decode(req.Params, &p); err != nil {
			return nil, err
		}
		if len(p.Group) > 512 || len(p.Name) > 512 {
			return nil, errors.New("invalid selection")
		}
		s.State.Selections[p.Group] = p.Name
		return true, s.Save()
	case "logs":
		if a.remote != nil {
			var logs []string
			err := a.remote.Call("logs", nil, &logs)
			return logs, err
		}
		return a.Core.Logs(), nil
	case "installService":
		if a.status().Running {
			return nil, errors.New("disconnect before installing the background service")
		}
		return ServiceStatus(), InstallService(a.Binary)
	case "uninstallService":
		if a.status().Running {
			return nil, errors.New("disconnect before removing the service")
		}
		return true, UninstallService()
	case "checkUpdates":
		return CheckUpdates(ctx)
	case "updateCore":
		if a.remote != nil {
			return nil, errors.New("disconnect all-applications mode before updating the core")
		}
		result, err := a.UpdateCore(ctx)
		if err != nil {
			return nil, err
		}
		if ServiceStatus()["installed"] == true {
			remote, err := ConnectService()
			if err != nil {
				return nil, fmt.Errorf("desktop core updated, but background service is unavailable: %w", err)
			}
			defer remote.Close()
			if err = remote.Call("updateCore", nil, nil); err != nil {
				return nil, fmt.Errorf("desktop core updated, but background core could not update: %w", err)
			}
		}
		return result, nil
	default:
		return nil, errors.New("unknown desktop operation")
	}
}
func mergeConfig(dst, src map[string]any) {
	for k, v := range src {
		if next, ok := v.(map[string]any); ok {
			old, ok := dst[k].(map[string]any)
			if !ok {
				old = map[string]any{}
			}
			mergeConfig(old, next)
			dst[k] = old
		} else {
			dst[k] = v
		}
	}
}
func (a *App) apply(ctx context.Context, content string, s Settings) error {
	if a.remote != nil {
		return a.remote.Call("apply", map[string]any{"content": content, "settings": s}, nil)
	}
	return a.Core.Apply(ctx, content, s, false)
}
func FetchSubscription(ctx context.Context, raw string) (string, string, error) {
	if err := ValidateURL(raw); err != nil {
		return "", "", err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", raw, nil)
	req.Header.Set("User-Agent", "AsterDesktop/"+Version)
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return errors.New("too many subscription redirects")
		}
		return ValidateURL(req.URL.String())
	}}
	resp, err := client.Do(req)
	if err != nil {
		return "", "", errors.New("subscription could not be downloaded; check the URL and network")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return "", "", fmt.Errorf("subscription server returned %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, MaxConfig+1))
	if err != nil {
		return "", "", err
	}
	if len(b) > MaxConfig {
		return "", "", errors.New("subscription exceeds 16 MiB")
	}
	return string(b), resp.Header.Get("Subscription-Userinfo"), nil
}
