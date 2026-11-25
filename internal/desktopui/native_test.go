package desktopui

import (
	"context"
	"encoding/json"
	"errors"
	"image/png"
	"math/rand/v2"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Miku0139oao/aster-desktop/internal/backend"
	"github.com/egoist/mygo/ui"
)

const sampleConfig = `proxy-groups:
  - name: Test group
    type: select
    proxies: [DIRECT, REJECT]
rules:
  - MATCH,Test group
`

type fixtureClient struct {
	state   Snapshot
	methods []string
}

type stalledReadClient struct {
	*fixtureClient
	mu                           sync.Mutex
	connectOnce                  sync.Once
	readCalls                    atomic.Int32
	readMethod                   string
	discovering, finishDiscovery chan struct{}
	connecting, finishConnect    chan struct{}
}

func (f *stalledReadClient) Call(ctx context.Context, method string, params, out any) error {
	switch method {
	case f.readMethod:
		if f.readCalls.Add(1) == 1 {
			close(f.discovering)
			select {
			case <-f.finishDiscovery:
				return context.DeadlineExceeded
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	case "connect":
		f.connectOnce.Do(func() { close(f.connecting) })
		select {
		case <-f.finishConnect:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.fixtureClient.Call(ctx, method, params, out)
}

func (f *fixtureClient) Call(_ context.Context, method string, params, out any) error {
	f.methods = append(f.methods, method)
	var result any
	switch method {
	case "state", "status":
		result = f.state
	case "settings":
		f.state.State.Settings = params.(Settings)
	case "listNetworkInterfaces":
		result = []Object{{"name": "Fixture Ethernet"}}
	case "listApplications":
		result = []Object{{"name": "Fixture app", "path": "/fixture/app", "running": true}}
	case "trafficHistory":
		result = Object{"days": []Object{{"date": "2026-11-25", "upload": 42, "download": 2050}}}
	case "logs":
		result = []string{`time="10:00" level=info msg="Sample log"`}
	case "diagnose":
		result = []Object{{"kind": "dns", "status": "pass", "detail": "Fixture DNS"}}
	}
	if out != nil {
		data, err := json.Marshal(result)
		if err != nil {
			return err
		}
		return json.Unmarshal(data, out)
	}
	return nil
}
func (f *fixtureClient) Events() <-chan backend.Event { return nil }
func (f *fixtureClient) Close() error                 { return nil }
func (f *fixtureClient) Shutdown(ctx context.Context) error {
	return f.Call(ctx, "disconnect", nil, nil)
}

type retryShutdownClient struct {
	fixtureClient
	attempts int
}

func (f *retryShutdownClient) Shutdown(context.Context) error {
	f.attempts++
	if f.attempts == 1 {
		return errors.New("could not restore system proxy settings")
	}
	return nil
}

func newView(t *testing.T, client backend.Client, locale string) (*App, *ui.Tester) {
	t.Helper()
	if err := Setup(); err != nil {
		t.Fatal(err)
	}
	a := New(client, nil, Platform{}, locale)
	a.Initialize(false, nil)
	t.Cleanup(a.Stop)
	return a, ui.NewTester(a.View, 1180, 800)
}

func click(t *testing.T, tester *ui.Tester, label string) {
	t.Helper()
	if err := tester.Click(label); err != nil {
		t.Fatalf("click %q: %v (visible text: %q)", label, err, tester.Texts())
	}
}

func TestQuitWaitsForTheActiveOperationAndAllowsRetry(t *testing.T) {
	client := &retryShutdownClient{}
	a, tester := newView(t, client, "en")
	var finished, quit bool
	complete := func(err error) { quit = err == nil }
	a.run("connect", func(context.Context) (func(), error) {
		a.RequestQuit(complete)
		if client.attempts != 0 {
			t.Fatal("shutdown started before the foreground request completed")
		}
		return func() { finished = true }, nil
	})
	if !finished || quit || client.attempts != 1 {
		t.Fatalf("expected the failed shutdown after the active operation, finished=%v quit=%v attempts=%d", finished, quit, client.attempts)
	}
	tester.Frame()
	if !tester.HasText("Could not stop the proxy. Try quitting again. could not restore system proxy settings") {
		t.Fatalf("quit failure is missing from the window: %q", tester.Texts())
	}
	a.RequestQuit(complete)
	if !quit || client.attempts != 2 || a.quitError != "" {
		t.Fatalf("shutdown retry did not clear the error and allow quit, quit=%v attempts=%d error=%q", quit, client.attempts, a.quitError)
	}
}

func TestTUNCanConnectWhileNetworkListIsLoading(t *testing.T) {
	if err := Setup(); err != nil {
		t.Fatal(err)
	}
	settings := defaultSettings()
	settings.Tun = true
	client := &stalledReadClient{
		fixtureClient: &fixtureClient{state: Snapshot{State: State{
			Settings: settings,
			ActiveID: "tun",
			Profiles: []Profile{{ID: "tun", Name: "TUN configuration", Content: sampleConfig}},
		}}},
		readMethod:      "listNetworkInterfaces",
		discovering:     make(chan struct{}),
		finishDiscovery: make(chan struct{}),
		connecting:      make(chan struct{}),
		finishConnect:   make(chan struct{}),
	}
	updates := make(chan func(), 4)
	a := New(client, func(update func()) { updates <- update }, Platform{}, "en")
	t.Cleanup(a.Stop)
	applyUntil := func(message string, done func() bool) {
		t.Helper()
		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		for !done() {
			select {
			case apply := <-updates:
				apply()
			case <-deadline.C:
				t.Fatal(message)
			}
		}
	}
	a.Initialize(false, nil)
	applyUntil("desktop state did not load", func() bool { return a.ready })
	select {
	case <-client.discovering:
	case <-time.After(5 * time.Second):
		t.Fatal("network list discovery did not start")
	}
	tester := ui.NewTester(a.View, 1180, 1000)
	if !tester.HasText("Loading network interfaces…") {
		t.Fatal("missing network list loading status")
	}
	click(t, tester, "Connect")
	select {
	case <-client.connecting:
	case <-time.After(5 * time.Second):
		t.Fatal("network discovery blocked connection")
	}
	close(client.finishDiscovery)
	applyUntil("network list failure did not reach the UI", func() bool { return !a.interfacesLoading })
	tester.Frame()
	if !tester.HasText("Starting proxy…") || !tester.HasText("Could not load network interfaces. Refresh the list or follow system routes.") ||
		!tester.HasText(context.DeadlineExceeded.Error()) {
		t.Fatal(tester.Texts())
	}
	close(client.finishConnect)
	applyUntil("connection result did not reach the UI", func() bool { return !a.busy })
	tester.Frame()
	if a.busyOperation != "" || a.errorMessage != "" || tester.HasText("Starting proxy…") {
		t.Fatal("connection progress did not reset after completion")
	}
	a.jump(overview)
	if a.interfacesLoading || client.readCalls.Load() != 1 {
		t.Fatal("returning to Home retried a failed network lookup")
	}
	click(t, tester, "Refresh network list")
	applyUntil("manual network refresh did not finish", func() bool { return !a.interfacesLoading })
	if a.interfacesError != nil || client.readCalls.Load() != 2 {
		t.Fatalf("manual retry failed: calls=%d, err=%v", client.readCalls.Load(), a.interfacesError)
	}
	tester.Frame()
	click(t, tester, "Follow system routes")
	if !tester.HasText("Fixture Ethernet") {
		t.Fatal("network option missing after manual retry")
	}
}

func TestNativeOverviewAndJump(t *testing.T) {
	client := &fixtureClient{state: Snapshot{State: State{Settings: defaultSettings()}, DesktopVersion: "0.4.0"}}
	a, tester := newView(t, client, "en-US")
	if !tester.HasText("Start with a subscription") {
		t.Fatal(tester.Texts())
	}
	saveFrame(t, tester, "overview-light")
	click(t, tester, "Switch to dark mode")
	if client.state.State.Settings.Theme != "dark" {
		t.Fatal("theme was not saved")
	}
	saveFrame(t, tester, "overview-dark")
	a.snapshot.State.Settings.Theme = "system"
	a.snapshot.State.Settings.Language = "zh_TW"
	tester.Frame()
	if !tester.HasText("從一份訂閱開始") {
		t.Fatal(tester.Texts())
	}
	saveFrame(t, tester, "overview-zh")
	a.snapshot.State.Settings.Language = "en"
	tester.SetSize(760, 580)
	mod := ui.Ctrl
	if runtime.GOOS == "darwin" {
		mod = ui.Cmd
	}
	tester.Key(mod, ui.KeyK)
	if !tester.HasText("Jump to a page") {
		t.Fatal(tester.Texts())
	}
	tester.Type("Statistics")
	tester.Key(0, ui.KeyEnter)
	if a.page != statistics || !tester.HasText("Daily traffic") {
		t.Fatal(tester.Texts())
	}
	if !slices.Contains(client.methods, "trafficHistory") {
		t.Fatal(client.methods)
	}
}

func TestPageReadsDoNotBlockConnect(t *testing.T) {
	for _, tc := range []struct {
		method string
		page   pageID
	}{
		{"listApplications", applications},
		{"trafficHistory", statistics},
	} {
		t.Run(tc.method, func(t *testing.T) {
			if err := Setup(); err != nil {
				t.Fatal(err)
			}
			client := &stalledReadClient{
				fixtureClient: &fixtureClient{state: Snapshot{State: State{
					Settings: defaultSettings(),
					ActiveID: "test",
					Profiles: []Profile{{ID: "test", Name: "Test configuration", Content: sampleConfig}},
				}}},
				readMethod:  tc.method,
				discovering: make(chan struct{}, 1),
				connecting:  make(chan struct{}),
			}
			updates := make(chan func(), 4)
			a := New(client, func(update func()) { updates <- update }, Platform{}, "en")
			t.Cleanup(a.Stop)
			a.Initialize(false, nil)
			select {
			case update := <-updates:
				update()
			case <-time.After(5 * time.Second):
				t.Fatal("desktop state did not load")
			}
			a.errorMessage = "Previous connection failed"
			a.jump(tc.page)
			select {
			case <-client.discovering:
			case <-time.After(5 * time.Second):
				t.Fatal("page read did not start")
			}
			a.jump(overview)
			if a.errorMessage != "Previous connection failed" {
				t.Fatal("page read cleared the connection error")
			}
			click(t, ui.NewTester(a.View, 1180, 800), "Connect")
			select {
			case <-client.connecting:
			case <-time.After(5 * time.Second):
				t.Fatal("page read blocked connection")
			}
		})
	}
}

func TestImportDialogActionsAtLargeTextSize(t *testing.T) {
	client := &fixtureClient{state: Snapshot{State: State{Settings: defaultSettings()}}}
	a, tester := newView(t, client, "en")
	a.showImport()
	// The Windows minimum includes the native title bar, leaving about 549 DIP of content.
	tester.SetSize(760, 549)
	tester.SetPreferences(ui.Preferences{TextScale: 1.5})
	click(t, tester, "Paste content")
	a.dialog.err = "The configuration could not be imported.\nThe first provider is missing its URL.\nA group references an unknown node.\nReview the configuration and try again."
	tester.Frame()
	if !tester.HasText("The first provider is missing its URL.") {
		t.Fatal("missing validation error in the import dialog")
	}

	click(t, tester, "Import and validate")
	if !tester.HasText("Enter a subscription URL or choose a configuration.") {
		t.Fatal("validation did not update the dialog error")
	}
	click(t, tester, "YAML or node links")
	tester.Type(sampleConfig)
	if a.dialog.source != sampleConfig {
		t.Fatal("the pasted-content field did not receive input")
	}
	click(t, tester, "Cancel")
	if a.dialog.open {
		t.Fatal("cancel did not close the import dialog")
	}
}

func TestNativeConfiguredPages(t *testing.T) {
	client := &fixtureClient{state: Snapshot{State: State{Settings: defaultSettings(), ActiveID: "fixture", Profiles: []Profile{{ID: "fixture", Name: "Fixture profile", Content: sampleConfig}}}}}
	a, tester := newView(t, client, "en")
	for _, page := range []struct {
		id   pageID
		text string
	}{
		{nodes, "REJECT"}, {profiles, "Fixture profile"}, {applications, "Fixture app"},
		{connections, "Connections appear here after the proxy starts."},
		{statistics, "Daily traffic"}, {rules, "MATCH · Test group"},
		{diagnostics, "DNS lookup"}, {logs, "Sample log"}, {advanced, "Appearance and general"},
	} {
		t.Run(destinations[page.id].en, func(t *testing.T) {
			a.jump(page.id)
			tester.Frame()
			if !tester.HasText(page.text) {
				t.Fatal(tester.Texts())
			}
		})
	}
	a.jump(profiles)
	tester.Frame()
	click(t, tester, "Edit YAML")
	if !tester.HasText("Edit YAML · Fixture profile") {
		t.Fatal(tester.Texts())
	}
	click(t, tester, "Cancel")
}

func TestNativeBridgeWorkflow(t *testing.T) {
	bridge, core := os.Getenv("ASTER_TEST_BRIDGE"), os.Getenv("ASTER_TEST_CORE")
	if bridge == "" || core == "" {
		t.Skip("set ASTER_TEST_BRIDGE and ASTER_TEST_CORE to exercise the packaged engine")
	}
	client, err := backend.Start(bridge, core, t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := client.Close(); err != nil {
			t.Error(err)
		}
	})
	a, tester := newView(t, client, "en")
	click(t, tester, "Import a subscription")
	click(t, tester, "Paste content")
	tester.Type(sampleConfig)
	click(t, tester, "Import and validate")
	if a.active() == nil || !tester.HasText("Ready to connect") {
		t.Fatalf("profile not imported: %q", tester.Texts())
	}
	a.jump(nodes)
	tester.Frame()
	click(t, tester, "REJECT")
	if got := a.snapshot.State.Selections["Test group"]; got != "REJECT" {
		t.Fatalf("offline selection = %q", got)
	}

	settings := a.settings()
	settings.SystemProxy, settings.MixedPort = false, freeMixedPort(t)
	a.saveSettings(settings)
	a.jump(overview)
	tester.Frame()
	click(t, tester, "Connect")
	if !a.running() || !tester.HasText("Connected") {
		t.Fatalf("core did not start: %q", tester.Texts())
	}
	var result Object
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := a.api(ctx, "GET", "/proxies/Test%20group", nil, &result); err != nil || result["now"] != "REJECT" {
		t.Fatalf("core selection = %v, %v", result, err)
	}
	settings.Mode = "global"
	a.saveSettings(settings)
	if err := a.api(ctx, "GET", "/proxies/GLOBAL", nil, &result); err != nil || result["now"] != "Test group" {
		t.Fatalf("global mode did not retain the group: %v, %v", result, err)
	}
	click(t, tester, "Disconnect")
	if a.running() {
		t.Fatal("stop did not stop the core")
	}
	closed := false
	a.RequestQuit(func(err error) {
		if err != nil {
			t.Fatal(err)
		}
		closed = true
	})
	if !closed {
		t.Fatal("quit did not close the packaged engine")
	}
}

func freeMixedPort(t *testing.T) int {
	t.Helper()
	loopback := net.IPv4(127, 0, 0, 1)
	for range 32 {
		// Windows can reserve different ephemeral ranges for TCP and UDP.
		// Try the same candidate outside the default Windows ephemeral range.
		port := 24000 + rand.IntN(10000)
		udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: loopback, Port: port})
		if err != nil {
			continue
		}
		tcp, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: loopback, Port: port})
		udp.Close()
		if err == nil {
			tcp.Close()
			return port
		}
	}
	t.Fatal("no available TCP and UDP port for the test core")
	return 0
}

func saveFrame(t *testing.T, tester *ui.Tester, name string) {
	t.Helper()
	dir := os.Getenv("ASTER_TEST_ARTIFACTS")
	if dir == "" {
		return
	}
	if err := os.MkdirAll(dir, 0755); err != nil {
		t.Fatal(err)
	}
	file, err := os.Create(filepath.Join(dir, name+".png"))
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := png.Encode(file, tester.Image()); err != nil {
		t.Fatal(err)
	}
}
