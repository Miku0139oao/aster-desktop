package backend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/ebitengine/purego"
	"golang.org/x/sys/unix"
)

type macClient struct {
	Client
	mu             sync.Mutex
	invoke         func(string) *byte
	free           func(*byte)
	loadErr        error
	sequence       uint64
	tun, proxy     bool
	trafficSession string
	pid            int
}

type object = map[string]any
type macProfile struct {
	ID      string
	Content string
}
type macState struct {
	State struct {
		ActiveID   string
		Settings   object
		Profiles   []macProfile
		Selections map[string]string
	}
	Core struct{ Running bool }
}

func (s macState) active() macProfile {
	for _, profile := range s.State.Profiles {
		if profile.ID == s.State.ActiveID {
			return profile
		}
	}
	return macProfile{}
}

func WithMacService(client Client, library string) Client {
	m := &macClient{Client: client}
	handle, err := purego.Dlopen(library, purego.RTLD_NOW|purego.RTLD_LOCAL)
	if err != nil {
		m.loadErr = errors.New("install Aster Desktop from its package to use the background service")
		return m
	}
	purego.RegisterLibFunc(&m.invoke, handle, "aster_privilege_request")
	purego.RegisterLibFunc(&m.free, handle, "aster_privilege_free")
	return m
}

func (m *macClient) native(ctx context.Context, method string, params, output any) error {
	if m.loadErr != nil {
		return m.loadErr
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	m.sequence++
	req, err := json.Marshal(object{"id": m.sequence, "method": method, "params": params})
	if err != nil {
		return err
	}
	if len(req) >= maxRequestBytes {
		return errors.New("background service request is too large")
	}
	ptr := m.invoke(string(req))
	if ptr == nil {
		return errors.New("background service did not respond")
	}
	defer m.free(ptr)
	var res reply
	if err := json.Unmarshal([]byte(unix.BytePtrToString(ptr)), &res); err != nil {
		return err
	}
	if res.Error != nil {
		return errors.New(res.Error.Message)
	}
	if res.ID != m.sequence {
		return errors.New("background service response did not match the request")
	}
	if output != nil && len(res.Result) > 0 {
		return json.Unmarshal(res.Result, output)
	}
	return nil
}

func (m *macClient) service(ctx context.Context) (object, error) {
	status := object{"installed": false, "approved": false, "platform": "macos"}
	if m.loadErr != nil {
		return status, nil
	}
	return status, m.native(ctx, "serviceStatus", nil, &status)
}
func (m *macClient) state(ctx context.Context) (macState, error) {
	var state macState
	err := m.Client.Call(ctx, "state", nil, &state)
	return state, err
}
func (m *macClient) Call(ctx context.Context, method string, params, result any) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return err
	}
	return m.call(ctx, method, params, result)
}
func (m *macClient) call(ctx context.Context, method string, params, result any) error {
	switch method {
	case "listApplications":
		var applications []object
		if err := m.Client.Call(ctx, method, params, &applications); err != nil {
			return err
		}
		paths := make([]string, 0, min(256, len(applications)))
		for _, application := range applications {
			if path, _ := application["path"].(string); application["installed"] == true && path != "" {
				paths = append(paths, path)
				if len(paths) == 256 {
					break
				}
			}
		}
		var icons map[string]string
		if err := m.native(ctx, "applicationIcons", paths, &icons); err == nil {
			for _, application := range applications {
				path, _ := application["path"].(string)
				if icon := icons[path]; icon != "" {
					application["icon"] = icon
				}
			}
		}
		return decodeResult(applications, result)
	case "state", "status":
		var state map[string]json.RawMessage
		if err := m.Client.Call(ctx, method, nil, &state); err != nil {
			return err
		}
		service, err := m.service(ctx)
		if err != nil {
			return err
		}
		state["service"], _ = json.Marshal(service)
		var core json.RawMessage
		if m.tun {
			if err := m.native(ctx, "status", nil, &core); err != nil {
				return err
			}
			state["core"] = core
			var status struct {
				Running bool
				PID     int
			}
			_ = json.Unmarshal(core, &status)
			if status.PID != m.pid && status.Running {
				m.newTrafficSession()
				m.pid = status.PID
			}
			m.tun = status.Running
			if m.tun {
				m.recordTraffic(ctx)
			}
		}
		if m.proxy {
			var status struct{ Running bool }
			_ = json.Unmarshal(state["core"], &status)
			if !status.Running {
				if err := m.native(ctx, "proxyStop", nil, nil); err != nil {
					return err
				}
				m.proxy = false
			}
		}
		return decodeResult(state, result)
	case "connect":
		return m.connect(ctx, result)
	case "deleteProfile":
		if m.tun {
			state, err := m.state(ctx)
			if err != nil {
				return err
			}
			p, _ := params.(map[string]any)
			if p["id"] == state.State.ActiveID {
				return errors.New("disconnect before deleting the active configuration")
			}
		}
	case "disconnect":
		return m.disconnect(ctx, result)
	case "installService", "uninstallService":
		state, err := m.state(ctx)
		if err != nil {
			return err
		}
		if state.Core.Running || m.tun {
			return errors.New("disconnect before changing the background service")
		}
		return m.native(ctx, method, nil, result)
	case "diagnose":
		service, err := m.service(ctx)
		if err != nil {
			return err
		}
		metadata := object{"externalService": service}
		if m.tun {
			var core json.RawMessage
			if err := m.native(ctx, "status", nil, &core); err != nil {
				return err
			}
			metadata["externalStatus"] = core
		}
		return m.Client.Call(ctx, method, metadata, result)
	case "checkUpdates":
		return m.Client.Call(ctx, method, object{"externalProxy": m.tun}, result)
	case "updateCore":
		return m.updateCore(ctx, result)
	case "controller", "logs":
		if m.tun {
			if err := m.native(ctx, method, params, result); err != nil {
				return err
			}
			p, _ := params.(map[string]any)
			path, _ := p["path"].(string)
			if method == "controller" && p["method"] == "PUT" && strings.HasPrefix(path, "/proxies/") {
				group, _ := url.PathUnescape(strings.TrimPrefix(path, "/proxies/"))
				body, _ := p["body"].(map[string]any)
				return m.Client.Call(ctx, "rememberSelection", object{"group": group, "name": body["name"]}, nil)
			}
			return nil
		}
	case "settings", "edit", "restore", "patchProfile", "manageObject", "manageRules", "batchApplicationRules", "applyRefresh", "activate", "refresh":
		if m.tun {
			return m.apply(ctx, method, params, result)
		}
	}
	return m.Client.Call(ctx, method, params, result)
}
func decodeResult(value, result any) error {
	if result == nil {
		return nil
	}
	b, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return json.Unmarshal(b, result)
}

func (m *macClient) connect(ctx context.Context, result any) error {
	state, err := m.state(ctx)
	if err != nil {
		return err
	}
	settings := state.State.Settings
	profile := state.active()
	if profile.ID == "" {
		return errors.New("import a configuration before connecting")
	}
	if m.tun {
		return m.native(ctx, "status", nil, result)
	}
	if state.Core.Running {
		return m.Client.Call(ctx, "connect", nil, result)
	}
	if settings["tun"] == true {
		if err := m.native(ctx, "start", object{"content": profile.Content, "settings": settings}, nil); err != nil {
			return err
		}
		m.tun = true
		m.newTrafficSession()
		m.replaySelections(ctx, state.State.Selections)
		return m.native(ctx, "status", nil, result)
	}
	if settings["systemProxy"] != true {
		return m.Client.Call(ctx, "connect", nil, result)
	}
	service, err := m.service(ctx)
	if err != nil {
		return err
	}
	if service["approved"] != true {
		if err := m.native(ctx, "installService", nil, nil); err != nil {
			return err
		}
		return errors.New("approve Aster Desktop in System Settings → Login Items & Extensions, then connect again")
	}
	if err := m.Client.Call(ctx, "connect", object{"skipSystemProxy": true}, result); err != nil {
		return err
	}
	if err := m.native(ctx, "proxyStart", object{"port": settings["mixedPort"]}, nil); err != nil {
		rollback, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		return errors.Join(err, m.Client.Call(rollback, "disconnect", nil, nil))
	}
	m.proxy = true
	return nil
}
func (m *macClient) disconnect(ctx context.Context, result any) error {
	if m.tun {
		m.recordTraffic(ctx)
		if err := m.native(ctx, "stop", nil, result); err != nil {
			return err
		}
		m.tun = false
		return nil
	}
	if m.proxy {
		if err := m.native(ctx, "proxyStop", nil, nil); err != nil {
			return err
		}
		m.proxy = false
	}
	return m.Client.Call(ctx, "disconnect", nil, result)
}
func (m *macClient) apply(ctx context.Context, method string, params, result any) error {
	old, err := m.state(ctx)
	if err != nil {
		return err
	}
	if method == "settings" {
		var update object
		if err := decodeResult(params, &update); err != nil {
			return err
		}
		for _, key := range []string{"tun", "mixedPort", "systemProxy", "tunInterface"} {
			if update[key] != old.State.Settings[key] {
				return errors.New("disconnect before changing how applications connect")
			}
		}
	}
	if err := m.Client.Call(ctx, method, params, result); err != nil {
		return err
	}
	next, err := m.state(ctx)
	if err != nil {
		return err
	}
	previous, current := old.active(), next.active()
	if previous.Content == current.Content && old.State.Settings["mode"] == next.State.Settings["mode"] && old.State.Settings["allowLan"] == next.State.Settings["allowLan"] {
		return nil
	}
	if err := m.native(ctx, "apply", object{"content": current.Content, "settings": next.State.Settings}, nil); err != nil {
		rollback, cancel := context.WithTimeout(context.Background(), time.Minute)
		defer cancel()
		var failures []error
		if previous.ID == current.ID && previous.Content != current.Content {
			// Workspace edits keep a metadata-aware backup. Subscription refresh
			// has its own transaction and does not always make that backup.
			if slices.Contains([]string{"refresh", "applyRefresh"}, method) {
				failures = append(failures, m.Client.Call(rollback, "edit", object{"id": previous.ID, "content": previous.Content}, nil))
			} else {
				failures = append(failures, m.Client.Call(rollback, "restore", object{"id": previous.ID}, nil))
			}
		}
		failures = append(failures, m.Client.Call(rollback, "activate", object{"id": previous.ID}, nil))
		failures = append(failures, m.Client.Call(rollback, "settings", old.State.Settings, nil))
		return errors.Join(append([]error{err}, failures...)...)
	}
	m.replaySelections(ctx, next.State.Selections)
	return nil
}
func (m *macClient) recordTraffic(ctx context.Context) {
	var traffic struct {
		UploadTotal, DownloadTotal uint64
		Connections                json.RawMessage
	}
	if m.native(ctx, "controller", object{"method": "GET", "path": "/connections"}, &traffic) == nil {
		_ = m.Client.Call(ctx, "recordExternalTraffic", object{"session": m.trafficSession, "up": traffic.UploadTotal, "down": traffic.DownloadTotal, "connections": traffic.Connections}, nil)
	}
}
func (m *macClient) newTrafficSession() {
	m.trafficSession = fmt.Sprintf("mac:%d", time.Now().UnixNano())
}
func (m *macClient) replaySelections(ctx context.Context, choices map[string]string) {
	for group, node := range choices {
		_ = m.native(ctx, "controller", object{"method": "PUT", "path": "/proxies/" + url.PathEscape(group), "body": object{"name": node}}, nil)
	}
}
func (m *macClient) updateCore(ctx context.Context, result any) (err error) {
	state, err := m.state(ctx)
	if err != nil {
		return err
	}
	if m.proxy {
		defer func() {
			recoverCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			state, e := m.state(recoverCtx)
			if e == nil && state.Core.Running {
				e = m.native(recoverCtx, "proxyStart", object{"port": state.State.Settings["mixedPort"]}, nil)
			} else {
				e = errors.Join(e, m.native(recoverCtx, "proxyStop", nil, nil))
				if e == nil {
					m.proxy = false
				}
			}
			err = errors.Join(err, e)
		}()
	}
	if err = m.Client.Call(ctx, "updateCore", object{"externalProxy": m.tun}, result); err != nil {
		return err
	}
	service, err := m.service(ctx)
	if err != nil {
		return err
	}
	if !m.tun && service["approved"] != true {
		return nil
	}
	var port any = 0
	if state.Core.Running || m.tun {
		port = state.State.Settings["mixedPort"]
	}
	err = m.native(ctx, "updateCore", object{"port": port}, nil)
	if m.tun {
		restoreCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		var status struct {
			Running bool
			PID     int
		}
		if m.native(restoreCtx, "status", nil, &status) == nil && status.Running {
			if status.PID != m.pid {
				m.newTrafficSession()
				m.pid = status.PID
			}
			m.replaySelections(restoreCtx, state.State.Selections)
		}
	}
	if err != nil {
		return fmt.Errorf("desktop core updated, but background core could not update: %w", err)
	}
	return nil
}
func (m *macClient) Close() error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	m.mu.Lock()
	defer m.mu.Unlock()
	var err error
	if m.tun || m.proxy {
		err = m.disconnect(ctx, nil)
	}
	if m.invoke != nil {
		err = errors.Join(err, m.native(ctx, "close", nil, nil))
	}
	return errors.Join(err, m.Client.Close())
}
