package desktopui

import (
	"context"
	"encoding/json"
	"image/png"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"slices"
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

func (f *fixtureClient) Call(_ context.Context, method string, params, out any) error {
	f.methods = append(f.methods, method)
	var result any
	switch method {
	case "state", "status":
		result = f.state
	case "settings":
		f.state.State.Settings = params.(Settings)
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
}

func freeMixedPort(t *testing.T) int {
	t.Helper()
	for range 32 {
		tcp, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		port := tcp.Addr().(*net.TCPAddr).Port
		// The mixed listener needs both transports. Some Windows UDP ports
		// are reserved even when TCP can bind the same number.
		udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: port})
		tcp.Close()
		if err == nil {
			udp.Close()
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
