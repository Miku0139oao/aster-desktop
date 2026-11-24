package desktopui

import (
	"context"
	"encoding/json"
	"net/url"
	"runtime"
	"slices"
	"time"

	"github.com/Miku0139oao/aster-desktop/internal/backend"
	"github.com/egoist/mygo/ui"
)

// App's view state is owned by the UI thread. Requests run off it, and their
// completions return through the window's Update callback.
type App struct {
	client   backend.Client
	post     func(func())
	ctx      context.Context
	cancel   context.CancelFunc
	platform Platform

	snapshot                       Snapshot
	ready, busy, quitting, polling bool
	epoch                          uint64
	stateChanged                   bool
	nextScheduledRefresh           time.Time
	nextHistoryPoll                time.Time
	errorMessage, notice, progress string
	page                           pageID
	palette                        palette
	systemLocale                   string
	translations                   map[string]string

	scroll    [pageCount]ui.ScrollState
	navScroll ui.ScrollState
	lists     [pageCount]ui.ListState
	queries   [pageCount]string
	dialog    dialog

	parsedContent                 string
	parsed                        Object
	proxies                       Object
	providers                     Object
	connections                   Object
	up, down                      float64
	trafficAt                     time.Time
	lastUp, lastDown              float64
	streamAt                      time.Time
	logs                          []string
	logLevels                     map[string]bool
	logSource                     string
	pausedConnections, pausedLogs bool
	sortConnections               string
	connectionFilter              string
	diagnostics                   []Object
	dnsName, dnsType              string
	dnsResult                     Object
	history                       Object
	interfaces                    []Object
	applications                  []Object
	selectedApps                  map[string]bool
	appFilter                     string
	appIcons                      map[string]*ui.Bitmap
	nodeGroup                     string
	favoritesOnly                 bool
	recentOnly                    bool
	nodeDelays                    map[string]int
	nodeGrid                      ui.GridState
	measureCancel                 context.CancelFunc
	objectsOpen                   bool
	objectKind                    string
	ruleFilter                    string
}

type Platform struct {
	PickFile func(title string, extensions []string) (string, error)
	SaveFile func(title, filename string, data []byte) error
	Copy     func(string)
	Quit     func()
	Locale   func(string)
}

func New(client backend.Client, post func(func()), platform Platform, locale string) *App {
	ctx, cancel := context.WithCancel(context.Background())
	return &App{
		client: client, post: post, ctx: ctx, cancel: cancel, platform: platform,
		snapshot:     Snapshot{State: State{Settings: defaultSettings()}},
		systemLocale: locale, translations: map[string]string{},
		selectedApps: map[string]bool{}, appIcons: map[string]*ui.Bitmap{}, nodeDelays: map[string]int{}, logLevels: map[string]bool{},
	}
}

func (a *App) running() bool { return a.snapshot.Core.Running }

func (a *App) Initialize(autostart bool, startErr error) {
	if startErr != nil {
		a.errorMessage = startErr.Error()
		return
	}
	a.run("state", func(ctx context.Context) (func(), error) {
		var initial Snapshot
		if err := a.client.Call(ctx, "state", nil, &initial); err != nil {
			return nil, err
		}
		if autostart && initial.State.ActiveID != "" {
			if err := a.client.Call(ctx, "connect", nil, nil); err != nil {
				return func() { a.setSnapshot(initial) }, err
			}
			if err := a.client.Call(ctx, "state", nil, &initial); err != nil {
				return nil, err
			}
		}
		var proxies Object
		var err error
		if initial.Core.Running {
			proxies, err = a.loadProxies(ctx, &initial, autostart)
		}
		return func() {
			a.setSnapshot(initial)
			a.proxies = proxies
			if a.settings().Tun {
				a.loadInterfaces()
			}
		}, err
	})
}

func (a *App) setSnapshot(s Snapshot) {
	old := a.settings().Language
	wasReady := a.ready
	if a.snapshot.State.ActiveID != s.State.ActiveID || a.running() != s.Core.Running {
		if a.measureCancel != nil {
			a.measureCancel()
		}
		a.proxies, a.providers, a.connections = nil, nil, nil
		a.up, a.down, a.lastUp, a.lastDown = 0, 0, 0, 0
		a.trafficAt, a.streamAt = time.Time{}, time.Time{}
		clear(a.nodeDelays)
		clear(a.selectedApps)
	}
	a.snapshot, a.ready = s, true
	if a.platform.Locale != nil && (!wasReady || old != a.settings().Language) {
		a.platform.Locale(s.State.Settings.Language)
	}
}

type operation func(context.Context) (apply func(), err error)

func (a *App) run(method string, work operation) {
	if a.busy || a.quitting || a.client == nil {
		return
	}
	a.busy, a.errorMessage, a.notice = true, "", ""
	a.epoch++
	timeout := 3 * time.Minute
	if method == "updateCore" {
		timeout = 20 * time.Minute
	}
	run := func() {
		ctx, cancel := context.WithTimeout(a.ctx, timeout)
		defer cancel()
		apply, err := work(ctx)
		finish := func() {
			if a.quitting {
				return
			}
			a.busy, a.progress = false, ""
			if apply != nil {
				apply()
			}
			if err != nil {
				a.errorMessage = err.Error()
				if a.dialog.open {
					a.dialog.err = a.errorMessage
				}
			}
		}
		if a.post == nil {
			finish()
		} else {
			a.post(finish)
		}
	}
	if a.post == nil {
		run()
	} else {
		go run()
	}
}

func (a *App) mutate(method string, params any, after func()) {
	a.run(method, func(ctx context.Context) (func(), error) {
		return a.mutateAfter(ctx, method, params, after)
	})
}

func (a *App) mutateAfter(ctx context.Context, method string, params any, after func()) (func(), error) {
	if err := a.client.Call(ctx, method, params, nil); err != nil {
		return nil, err
	}
	var state Snapshot
	if err := a.client.Call(ctx, "state", nil, &state); err != nil {
		return nil, err
	}
	var proxies Object
	var err error
	if state.Core.Running {
		proxies, err = a.loadProxies(ctx, &state, method == "connect" || method == "settings")
	}
	return func() {
		a.setSnapshot(state)
		if proxies != nil {
			a.proxies = proxies
		}
		if after != nil {
			after()
		}
	}, err
}

func (a *App) saveSettings(next Settings) {
	a.mutate("settings", next, func() {
		if next.Tun && a.interfaces == nil {
			a.loadInterfaces()
		}
	})
}

func (a *App) loadProxies(ctx context.Context, snapshot *Snapshot, selectGlobal bool) (Object, error) {
	var result Object
	if err := a.api(ctx, "GET", "/proxies", nil, &result); err != nil {
		return nil, err
	}
	proxies := object(result["proxies"])
	if !selectGlobal || snapshot.State.Settings.Mode != "global" {
		return proxies, nil
	}
	global := object(proxies["GLOBAL"])
	choices := stringSlice(global["all"])
	target := snapshot.State.Selections["GLOBAL"]
	if !slices.Contains(choices, target) {
		for _, profile := range snapshot.State.Profiles {
			if profile.ID == snapshot.State.ActiveID {
				target = profileTarget(parseDocument(profile.Content))
				break
			}
		}
	}
	if !slices.Contains(choices, target) || str(global["now"]) == target {
		return proxies, nil
	}
	if err := a.api(ctx, "PUT", "/proxies/GLOBAL", Object{"name": target}, nil); err != nil {
		return proxies, err
	}
	global["now"] = target
	if snapshot.State.Selections == nil {
		snapshot.State.Selections = map[string]string{}
	}
	snapshot.State.Selections["GLOBAL"] = target
	return proxies, nil
}
func (a *App) api(ctx context.Context, method, path string, body, output any) error {
	return a.client.Call(ctx, "controller", Object{"method": method, "path": path, "body": body}, output)
}
func (a *App) toggle() {
	if a.active() == nil {
		return
	}
	if a.running() {
		a.mutate("disconnect", nil, nil)
	} else {
		a.mutate("connect", nil, nil)
	}
}

// Toggle is shared by the window and the tray.
func (a *App) Toggle() { a.toggle() }
func (a *App) jump(page pageID) {
	a.page = page
	switch page {
	case applications:
		if a.applications == nil {
			a.loadApplications()
		}
		a.Poll()
	case statistics:
		if a.history == nil {
			a.loadHistory()
		}
	case nodes, connections, logs:
		a.Poll()
	case overview:
		if a.settings().Tun && a.interfaces == nil {
			a.loadInterfaces()
		}
	}
}
func (a *App) selectNode(group, node string) {
	running, mode := a.running(), a.settings().Mode
	prefs := a.snapshot.State.Preferences
	recentKey := "recent:" + a.snapshot.State.ActiveID
	a.run("controller", func(ctx context.Context) (func(), error) {
		selectOne := func(g, n string) error {
			if running {
				return a.api(ctx, "PUT", "/proxies/"+url.PathEscape(g), Object{"name": n}, nil)
			}
			return a.client.Call(ctx, "rememberSelection", Object{"group": g, "name": n}, nil)
		}
		if err := selectOne(group, node); err != nil {
			return nil, err
		}
		if mode == "global" && group != "GLOBAL" {
			if err := selectOne("GLOBAL", group); err != nil {
				return nil, err
			}
		}
		next := Object{}
		for k, v := range prefs {
			next[k] = v
		}
		recent := slices.DeleteFunc(stringSlice(prefs[recentKey]), func(name string) bool { return name == node })
		next[recentKey] = append([]string{node}, recent[:min(len(recent), 19)]...)
		if err := a.client.Call(ctx, "preferences", Object{"preferences": next}, nil); err != nil {
			return nil, err
		}
		var state Snapshot
		if err := a.client.Call(ctx, "state", nil, &state); err != nil {
			return nil, err
		}
		var live Object
		if running {
			_ = a.api(ctx, "GET", "/proxies", nil, &live)
		}
		return func() {
			a.setSnapshot(state)
			if live != nil {
				a.proxies = object(live["proxies"])
			}
		}, nil
	})
}

func (a *App) preferences(changes Object) {
	next := Object{}
	for key, value := range a.snapshot.State.Preferences {
		next[key] = value
	}
	for key, value := range changes {
		next[key] = value
	}
	a.mutate("preferences", Object{"preferences": next}, nil)
}

func (a *App) Poll() {
	if a.client == nil || a.polling || !a.ready || a.busy || a.quitting {
		return
	}
	if a.stateChanged {
		a.stateChanged = false
		a.mutate("state", nil, nil)
		return
	}
	now := time.Now()
	// macOS refreshes go through the GUI's authenticated XPC session.
	// The bridge schedules refreshes on Windows and Linux.
	if runtime.GOOS == "darwin" && a.scheduleRefresh(now) {
		return
	}
	a.polling = true
	page, epoch := a.page, a.epoch
	pauseConnections, pauseLogs := a.pausedConnections, a.pausedLogs
	historyDays := a.days()
	loadHistory := page == statistics && now.After(a.nextHistoryPoll)
	if loadHistory {
		a.nextHistoryPoll = now.Add(10 * time.Second)
	}
	work := func() {
		ctx, cancel := context.WithTimeout(a.ctx, 15*time.Second)
		defer cancel()
		var status Snapshot
		err := a.client.Call(ctx, "status", nil, &status)
		var live, providerData, links, history Object
		var messages []string
		if err == nil && status.Core.Running {
			if page == overview || page == nodes {
				_ = a.api(ctx, "GET", "/proxies", nil, &live)
			}
			if page == nodes || page == applications || page == rules || page == connections || page == advanced {
				_ = a.api(ctx, "GET", "/providers/proxies", nil, &providerData)
			}
			if !pauseConnections {
				_ = a.api(ctx, "GET", "/connections", nil, &links)
			}
		}
		if err == nil && page == logs && !pauseLogs {
			_ = a.client.Call(ctx, "logs", nil, &messages)
		}
		if err == nil && loadHistory {
			_ = a.client.Call(ctx, "trafficHistory", Object{"days": historyDays}, &history)
		}
		finish := func() {
			a.polling = false
			if a.quitting || a.epoch != epoch {
				return
			}
			if err != nil {
				a.errorMessage = err.Error()
				return
			}
			wasRunning := a.running()
			a.snapshot.Core, a.snapshot.Service = status.Core, status.Service
			if !a.running() && wasRunning {
				a.up, a.down = 0, 0
				a.proxies, a.providers, a.connections = nil, nil, nil
				a.trafficAt, a.streamAt = time.Time{}, time.Time{}
				clear(a.nodeDelays)
			}
			if live != nil {
				a.proxies = object(live["proxies"])
			}
			if providerData != nil {
				a.providers = object(providerData["providers"])
			}
			if links != nil && !a.pausedConnections {
				a.updateConnections(links)
			}
			if messages != nil && !a.pausedLogs && !slices.Equal(a.logs, messages) {
				a.logs = messages
			}
			if history != nil {
				a.history = history
			}
		}
		if a.post == nil {
			finish()
		} else {
			a.post(finish)
		}
	}
	if a.post == nil {
		work()
	} else {
		go work()
	}
}

func (a *App) scheduleRefresh(now time.Time) bool {
	if now.Before(a.nextScheduledRefresh) {
		return false
	}
	a.nextScheduledRefresh = now.Add(time.Minute)
	for _, profile := range a.snapshot.State.Profiles {
		hours := a.settings().SubscriptionHours
		if profile.IntervalHours != nil {
			hours = *profile.IntervalHours
		}
		if profile.URL == "" || hours <= 0 || now.Sub(profile.Updated) < time.Duration(hours)*time.Hour || now.Sub(profile.LastAttempt) < 5*time.Minute {
			continue
		}
		a.run("refresh", func(ctx context.Context) (func(), error) {
			apply, err := a.mutateAfter(ctx, "refresh", Object{"id": profile.ID}, nil)
			if err != nil && apply == nil {
				return func() { a.stateChanged = true }, err
			}
			return apply, err
		})
		return true
	}
	return false
}

func (a *App) updateConnections(links Object) {
	now := time.Now()
	up, down := number(links["uploadTotal"]), number(links["downloadTotal"])
	if elapsed := now.Sub(a.trafficAt).Seconds(); !a.trafficAt.IsZero() && elapsed >= .5 {
		if now.Sub(a.streamAt) > 3*time.Second {
			a.up, a.down = max(0, up-a.lastUp)/elapsed, max(0, down-a.lastDown)/elapsed
		}
	}
	if a.trafficAt.IsZero() || now.Sub(a.trafficAt) >= 500*time.Millisecond {
		a.trafficAt, a.lastUp, a.lastDown = now, up, down
	}
	a.connections = links
}

func (a *App) Listen() {
	if a.client == nil {
		return
	}
	for {
		select {
		case <-a.ctx.Done():
			return
		case event, ok := <-a.client.Events():
			if !ok {
				return
			}
			switch event.Name {
			case "traffic", "connections":
				var data Object
				if json.Unmarshal(event.Data, &data) != nil {
					continue
				}
				a.post(func() {
					if !a.running() || a.quitting {
						return
					}
					if event.Name == "traffic" {
						a.up, a.down, a.streamAt = number(data["up"]), number(data["down"]), time.Now()
					} else if !a.pausedConnections {
						a.updateConnections(data)
					}
				})
			case "profilesChanged":
				a.post(func() {
					a.stateChanged = true
					a.Poll()
				})
			case "subscriptionError", "updateProgress":
				var data Object
				var message string
				if json.Unmarshal(event.Data, &data) == nil {
					message = str(data["message"])
				} else {
					_ = json.Unmarshal(event.Data, &message)
				}
				a.post(func() {
					if event.Name == "subscriptionError" {
						a.errorMessage = message
					} else if a.busy {
						a.progress = message
					}
				})
			}
		}
	}
}

func (a *App) Stop() {
	a.quitting = true
	a.cancel()
}

func (a *App) nextTheme() string {
	if a.palette.background == colors(true).background {
		return "light"
	}
	return "dark"
}

func (a *App) selectedProfile(id string) *Profile {
	for i := range a.snapshot.State.Profiles {
		if a.snapshot.State.Profiles[i].ID == id {
			return &a.snapshot.State.Profiles[i]
		}
	}
	return nil
}

func (a *App) checkRequest(ctx context.Context, method, path string, body any) (func(), error) {
	if err := a.api(ctx, method, path, body, nil); err != nil {
		return nil, err
	}
	return func() { a.Poll() }, nil
}
