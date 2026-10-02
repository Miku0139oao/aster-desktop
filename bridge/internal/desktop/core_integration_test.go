package desktop

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

func TestRealCoreRejectsOccupiedUDPPort(t *testing.T) {
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	packet, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer packet.Close()
	settings := DefaultSettings()
	settings.SystemProxy = false
	settings.MixedPort = packet.LocalAddr().(*net.UDPAddr).Port
	core := NewCore(binary, t.TempDir())
	defer core.Stop()
	if err = core.Start(context.Background(), "proxies: []\nrules: [MATCH,DIRECT]\n", settings, false); err == nil || core.Status().Running {
		t.Fatal("occupied UDP port should not become a connected status")
	}
}

func TestRealCoreClientLifecycle(t *testing.T) {
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Skip("set ASTER_TEST_CORE to the pinned with_gvisor executable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	dir := t.TempDir()
	a, err := NewApp(dir, binary, "")
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	settings := DefaultSettings()
	settings.SystemProxy = false
	settings.MixedPort = unusedPort()
	a.Store.State.Settings = settings
	events := make(chan string, 100)
	a.Emit = func(name string, _ any) {
		select {
		case events <- name:
		default:
		}
	}
	call := func(method string, params any) (json.RawMessage, error) {
		t.Helper()
		b, _ := json.Marshal(params)
		result, err := a.Dispatch(ctx, Request{Method: method, Params: b})
		if err != nil {
			return nil, err
		}
		return result.(json.RawMessage), nil
	}
	var subscriptionFailed atomic.Bool
	subscription := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subscriptionFailed.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		fmt.Fprint(w, "proxies:\n - {name: Local A, type: direct}\n - {name: Local B, type: direct}\nproxy-groups:\n - {name: Test Group, type: select, proxies: [Local A, Local B]}\nrules:\n - MATCH,Test Group\n")
	}))
	defer subscription.Close()
	profileJSON, err := call("import", map[string]any{"name": "Integration", "url": subscription.URL})
	if err != nil {
		t.Fatal(err)
	}
	var profile Profile
	_ = json.Unmarshal(profileJSON, &profile)
	if _, err = call("rememberSelection", map[string]string{"group": "Test Group", "name": "Local B"}); err != nil {
		t.Fatal(err)
	}
	if _, err = call("connect", nil); err != nil {
		t.Fatal(err)
	}
	offlineSelected, err := call("controller", map[string]any{"method": "GET", "path": "/proxies/Test%20Group"})
	var restoredSelection map[string]any
	_ = json.Unmarshal(offlineSelected, &restoredSelection)
	if err != nil || restoredSelection["now"] != "Local B" {
		t.Fatalf("offline selection was not applied at startup: %s %v", offlineSelected, err)
	}
	pid := a.Core.Status().PID
	if pid == 0 {
		t.Fatal("core not running")
	}
	if _, err = call("controller", map[string]any{"method": "GET", "path": "/version"}); err != nil {
		t.Fatal(err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/held" {
			fmt.Fprint(w, "open")
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		// The core reports a zero-millisecond delay as a failed test.
		time.Sleep(20 * time.Millisecond)
		fmt.Fprint(w, "aster-proxy-integration")
	}))
	defer upstream.Close()
	proxyURL, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", settings.MixedPort))
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL)}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
	response, err := client.Get(upstream.URL)
	if err != nil {
		t.Fatalf("real HTTP proxy failed: %v", err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if string(body) != "aster-proxy-integration" {
		t.Fatalf("unexpected proxy response: %s", body)
	}
	if _, err = call("controller", map[string]any{"method": "PUT", "path": "/proxies/Test%20Group", "body": map[string]string{"name": "Local B"}}); err != nil {
		t.Fatal(err)
	}
	group, err := call("controller", map[string]any{"method": "GET", "path": "/proxies/Test%20Group"})
	var selection map[string]any
	_ = json.Unmarshal(group, &selection)
	if err != nil || selection["now"] != "Local B" || a.Store.State.Selections["Test Group"] != "Local B" {
		t.Fatalf("selection was not applied and saved: %s %v", group, err)
	}
	delay, err := call("controller", map[string]any{"method": "GET", "path": "/proxies/Local%20B/delay?timeout=2000&url=" + url.QueryEscape(upstream.URL) + "&expected=200"})
	var measured map[string]float64
	_ = json.Unmarshal(delay, &measured)
	if err != nil || measured["delay"] <= 0 {
		t.Fatalf("real delay failed: %s %v", delay, err)
	}
	held, err := client.Get(upstream.URL + "/held")
	if err != nil {
		t.Fatal(err)
	}
	defer held.Body.Close()
	connections, err := call("controller", map[string]any{"method": "GET", "path": "/connections"})
	var tracked struct {
		Connections []struct {
			ID string `json:"id"`
		} `json:"connections"`
	}
	_ = json.Unmarshal(connections, &tracked)
	if err != nil || len(tracked.Connections) == 0 {
		t.Fatalf("real connection missing: %s %v", connections, err)
	}
	for _, connection := range tracked.Connections {
		if _, err = call("controller", map[string]any{"method": "DELETE", "path": "/connections/" + connection.ID}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = io.ReadAll(held.Body); err == nil {
		t.Fatal("interrupted streaming connection completed without an error")
	}
	seen := map[string]bool{}
	deadline := time.After(5 * time.Second)
	for !seen["traffic"] || !seen["connections"] {
		select {
		case event := <-events:
			seen[event] = true
		case <-deadline:
			t.Fatalf("real event streams missing: %v", seen)
		}
	}
	if len(a.Core.Logs()) == 0 {
		t.Fatal("real core logs missing")
	}
	subscriptionFailed.Store(true)
	if _, err = call("refresh", map[string]string{"id": profile.ID}); err == nil {
		t.Fatal("failed subscription refresh succeeded")
	}
	if a.Store.State.Profiles[0].Content != profile.Content || !a.Core.Status().Running {
		t.Fatal("failed subscription refresh damaged the active core")
	}
	for _, mode := range []string{"global", "direct", "rule"} {
		settings.Mode = mode
		if _, err = call("settings", settings); err != nil {
			t.Fatal(err)
		}
		config, err := call("controller", map[string]any{"method": "GET", "path": "/configs"})
		if err != nil {
			t.Fatal(err)
		}
		var value map[string]any
		_ = json.Unmarshal(config, &value)
		if value["mode"] != mode {
			t.Fatalf("mode not applied: %s", mode)
		}
	}
	settings.Theme = "dark"
	if _, err = call("settings", settings); err != nil {
		t.Fatal(err)
	}
	if a.Core.Status().PID != pid {
		t.Fatal("appearance change restarted core")
	}
	before := a.Store.State.Profiles[0].Content
	if _, err = call("edit", map[string]string{"id": profile.ID, "content": "rules: [BADRULE]\n"}); err == nil {
		t.Fatal("invalid configuration accepted")
	}
	if a.Store.State.Profiles[0].Content != before || !a.Core.Status().Running {
		t.Fatal("invalid configuration damaged running profile")
	}
	if _, err = call("patchProfile", map[string]any{"id": profile.ID, "rule": "DOMAIN,example.com,DIRECT"}); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(filepath.Join(dir, "backup-"+profile.ID+".yaml")); err != nil {
		t.Fatal("backup missing")
	}
	if _, err = call("restore", map[string]string{"id": profile.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err = call("disconnect", nil); err != nil {
		t.Fatal(err)
	}
	if a.Core.Status().Running {
		t.Fatal("core remained after disconnect")
	}
	if _, err = call("connect", nil); err != nil {
		t.Fatal(err)
	}
	a.Core.mu.Lock()
	process := a.Core.cmd.Process
	a.Core.mu.Unlock()
	if err = process.Kill(); err != nil {
		t.Fatal(err)
	}
	for limit := time.Now().Add(5 * time.Second); a.Core.Status().Running && time.Now().Before(limit); {
		time.Sleep(20 * time.Millisecond)
	}
	if a.Core.Status().Running || a.Core.Status().Error == "" {
		t.Fatal("crash did not become an actionable stopped status")
	}
	if _, err = call("connect", nil); err != nil {
		t.Fatal("could not reconnect after a crash:", err)
	}
	if _, err = call("disconnect", nil); err != nil {
		t.Fatal(err)
	}
}
