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
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// This exercises the core's actual process lookup and matching using loopback
// proxy traffic. It never changes the workstation's proxy, TUN or routes.
func TestRealCoreApplicationRules(t *testing.T) {
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	executable := currentApplicationExecutable(t)
	for _, match := range []struct{ kind, value string }{
		{"PROCESS-NAME", filepath.Base(executable)},
		{"PROCESS-PATH", executable},
	} {
		t.Run(match.kind, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			a, err := NewApp(t.TempDir(), binary, "")
			if err != nil {
				t.Fatal(err)
			}
			defer a.Close()
			s := DefaultSettings()
			s.SystemProxy = false
			s.MixedPort = unusedPort()
			a.Store.State.Settings = s
			call := func(method string, params any) json.RawMessage {
				t.Helper()
				b, _ := json.Marshal(params)
				result, err := a.Dispatch(ctx, Request{Method: method, Params: b})
				if err != nil {
					t.Fatal(method, ": ", err)
				}
				return result.(json.RawMessage)
			}
			var profile Profile
			base := "proxies: []\nfind-process-mode: off\nrules: ['PROCESS-NAME,another-app,DIRECT', 'MATCH,DIRECT']\n"
			subscription := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				fmt.Fprint(w, base)
			}))
			defer subscription.Close()
			if err = json.Unmarshal(call("import", map[string]any{
				"name": "Process routing", "url": subscription.URL,
			}), &profile); err != nil {
				t.Fatal(err)
			}
			call("connect", nil)
			var hits atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				hits.Add(1)
				fmt.Fprint(w, "reachable")
			}))
			defer server.Close()
			proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", s.MixedPort))
			transport := &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
			response, err := client.Get(server.URL)
			if err != nil {
				t.Fatal("baseline proxy: ", err)
			}
			response.Body.Close()
			if response.StatusCode != http.StatusOK || hits.Load() != 1 {
				t.Fatal("baseline did not reach upstream")
			}
			call("patchProfile", map[string]any{
				"id": profile.ID, "rule": match.kind + "," + match.value + ",REJECT",
			})
			response, err = client.Get(server.URL)
			if response != nil {
				response.Body.Close()
			}
			if err == nil && response.StatusCode < 400 {
				t.Fatal("application REJECT rule did not match")
			}
			if hits.Load() != 1 {
				t.Fatal("application rule allowed traffic to upstream")
			}
			// The backend prepends the rule without losing the catch-all route.
			if !strings.Contains(a.Store.State.Profiles[0].Content, "MATCH,DIRECT") {
				t.Fatal("existing route lost")
			}
			blocked := func() {
				t.Helper()
				before := hits.Load()
				response, err := client.Get(server.URL)
				if response != nil {
					response.Body.Close()
				}
				if err == nil && response.StatusCode < 400 || hits.Load() != before {
					t.Fatal("stored application rule did not block traffic")
				}
			}
			// GUI target changes replace a rule atomically instead of adding a
			// stale lower-priority copy that could reappear during refresh.
			call("patchProfile", map[string]any{"id": profile.ID, "removeRule": match.kind + "," + match.value + ",REJECT", "rule": match.kind + "," + match.value + ",DIRECT"})
			response, err = client.Get(server.URL)
			if err != nil {
				t.Fatal("changed application route: ", err)
			}
			response.Body.Close()
			if response.StatusCode != http.StatusOK {
				t.Fatal("DIRECT target change did not take effect")
			}
			call("patchProfile", map[string]any{"id": profile.ID, "removeRule": match.kind + "," + match.value + ",DIRECT", "rule": match.kind + "," + match.value + ",REJECT"})
			blocked()
			call("refresh", map[string]string{"id": profile.ID})
			blocked()
			if len(a.Store.State.Profiles[0].DesktopRules) != 1 {
				t.Fatal("GUI override not tracked")
			}
			// Editing YAML removes the override; undo restores its metadata too.
			call("edit", map[string]string{"id": profile.ID, "content": base})
			if len(a.Store.State.Profiles[0].DesktopRules) != 0 {
				t.Fatal("deleted override remained tracked")
			}
			call("restore", map[string]string{"id": profile.ID})
			call("refresh", map[string]string{"id": profile.ID})
			blocked()
			call("patchProfile", map[string]string{"id": profile.ID, "removeRule": match.kind + "," + match.value + ",REJECT"})
			call("refresh", map[string]string{"id": profile.ID})
			response, err = client.Get(server.URL)
			if err != nil {
				t.Fatal("removed application rule: ", err)
			}
			response.Body.Close()
			if response.StatusCode != http.StatusOK || hits.Load() != 3 {
				t.Fatal("deleted override was reinserted by subscription refresh")
			}
			// Imported process rules can also be removed through the GUI;
			// fetching the same subscription must not silently restore them.
			call("patchProfile", map[string]string{"id": profile.ID, "removeRule": "PROCESS-NAME,another-app,DIRECT"})
			call("refresh", map[string]string{"id": profile.ID})
			if strings.Contains(a.Store.State.Profiles[0].Content, "PROCESS-NAME,another-app,DIRECT") {
				t.Fatal("deleted imported application rule reappeared after refresh")
			}
		})
	}
}

func TestRealCoreApplicationProviderRoutes(t *testing.T) {
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	a, err := NewApp(t.TempDir(), binary, "")
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	s := DefaultSettings()
	s.SystemProxy = false
	s.MixedPort = unusedPort()
	a.Store.State.Settings = s
	call := func(method string, params any) json.RawMessage {
		t.Helper()
		b, _ := json.Marshal(params)
		result, err := a.Dispatch(ctx, Request{Method: method, Params: b})
		if err != nil {
			t.Fatal(method, ": ", err)
		}
		return result.(json.RawMessage)
	}
	// HTTP provider proxies really are absent from the global /proxies catalog.
	var available atomic.Bool
	available.Store(true)
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if available.Load() {
			fmt.Fprint(w, "proxies: [{name: 'allow[1]`+', type: direct}, {name: deny, type: reject}]\n")
		} else {
			fmt.Fprint(w, "proxies: [{name: deny, type: reject}]\n")
		}
	}))
	defer provider.Close()
	base := fmt.Sprintf("proxy-providers:\n  remote:\n    type: http\n    url: %s\n    interval: 3600\nproxy-groups: [{name: Shared, type: select, use: [remote]}]\nrules: ['MATCH,DIRECT']\n", provider.URL)
	sub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, base) }))
	defer sub.Close()
	var profile Profile
	if err = json.Unmarshal(call("import", map[string]any{"name": "Provider app routes", "url": sub.URL}), &profile); err != nil {
		t.Fatal(err)
	}
	call("connect", nil)
	var catalog map[string]any
	if err = json.Unmarshal(call("controller", map[string]any{"method": "GET", "path": "/proxies"}), &catalog); err != nil {
		t.Fatal(err)
	}
	if _, exists := catalog["proxies"].(map[string]any)["deny"]; exists {
		t.Fatal("fixture unexpectedly has a global provider node")
	}
	exe := currentApplicationExecutable(t)
	setRoute := func(node, remove string) string {
		t.Helper()
		call("patchProfile", map[string]any{"id": profile.ID, "removeRule": remove, "providerRoute": ApplicationRoute{Kind: "PROCESS-PATH", Match: exe, Provider: "remote", Node: node}})
		return a.Store.State.Profiles[0].DesktopRules[0]
	}
	var hits atomic.Int32
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1); fmt.Fprint(w, "ok") }))
	defer upstream.Close()
	proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", s.MixedPort))
	transport := &http.Transport{Proxy: http.ProxyURL(proxy), DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
	check := func(allowed bool) {
		t.Helper()
		before := hits.Load()
		response, err := client.Get(upstream.URL)
		if response != nil {
			response.Body.Close()
		}
		if allowed && (err != nil || response.StatusCode != 200 || hits.Load() != before+1) {
			t.Fatal("provider application route should allow traffic: ", err)
		}
		if !allowed && (hits.Load() != before || (err == nil && response.StatusCode < 400)) {
			t.Fatal("provider application route should block traffic")
		}
	}
	rule := setRoute("deny", "")
	check(false)
	var shared map[string]any
	if err = json.Unmarshal(call("controller", map[string]any{"method": "GET", "path": "/proxies/Shared"}), &shared); err != nil {
		t.Fatal(err)
	}
	if shared["now"] != "allow[1]`+" {
		t.Fatal("application choice changed the shared group's selected node")
	}
	rule = setRoute("allow[1]`+", rule)
	check(true)
	call("refresh", map[string]string{"id": profile.ID})
	check(true)
	if len(a.Store.State.Profiles[0].DesktopProviderRoutes) != 1 {
		t.Fatal("obsolete managed group retained")
	}
	var group map[string]any
	if err = json.Unmarshal(call("controller", map[string]any{"method": "GET", "path": "/proxies/" + a.Store.State.Profiles[0].DesktopProviderRoutes[0].Group}), &group); err != nil {
		t.Fatal(err)
	}
	if all := group["all"].([]any); len(all) != 1 || all[0] != "allow[1]`+" {
		t.Fatal("filter did not select precisely one provider node: ", all)
	}
	// A vanished node must block, never silently fall back to direct traffic.
	available.Store(false)
	call("controller", map[string]any{"method": "PUT", "path": "/providers/proxies/remote"})
	check(false)
	call("patchProfile", map[string]string{"id": profile.ID, "removeRule": rule})
	if len(a.Store.State.Profiles[0].DesktopProviderRoutes) != 0 || strings.Contains(a.Store.State.Profiles[0].Content, "Aster-App-") {
		t.Fatal("deleted managed group remained")
	}
	call("refresh", map[string]string{"id": profile.ID})
	check(true)
}

func TestRealCoreWaitsForSlowRuleProvider(t *testing.T) {
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		select {
		case <-r.Context().Done():
			return
		case <-time.After(17 * time.Second):
		}
		fmt.Fprint(w, "payload: ['DOMAIN,slow.example']\n")
	}))
	defer server.Close()
	c := NewCore(binary, t.TempDir())
	defer c.Stop()
	s := DefaultSettings()
	s.MixedPort = unusedPort()
	s.SystemProxy = false
	content := fmt.Sprintf("log-level: warning\nproxies: []\nrule-providers:\n slow: {type: http, behavior: classical, url: %q, interval: 3600}\nrules: ['RULE-SET,slow,DIRECT', 'MATCH,DIRECT']\n", server.URL)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := c.Start(ctx, content, s, false); err != nil {
		t.Fatal(err)
	}
	if !c.Status().Running || requests.Load() != 1 {
		t.Fatal("cold provider did not finish loading")
	}
	var data struct {
		Providers map[string]struct {
			RuleCount int `json:"ruleCount"`
		} `json:"providers"`
	}
	body, err := c.Request(ctx, "GET", "/providers/rules", nil)
	if err != nil || json.Unmarshal(body, &data) != nil || data.Providers["slow"].RuleCount != 1 {
		t.Fatalf("rule provider not applied: %s %v", body, err)
	}
	if err = c.Stop(); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	if err = c.Start(ctx, content, s, false); err != nil {
		t.Fatal(err)
	}
	if time.Since(started) > 5*time.Second || requests.Load() != 1 {
		t.Fatal("reconnect failed to reuse the valid provider cache")
	}
}

func TestRealCoreRejectsOccupiedUDPPort(t *testing.T) {
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	packet, err := net.ListenPacket("udp", listener.Addr().String())
	_ = listener.Close()
	if err != nil {
		t.Fatal(err)
	}
	defer packet.Close()
	settings := DefaultSettings()
	settings.SystemProxy = false
	settings.MixedPort = packet.LocalAddr().(*net.UDPAddr).Port
	core := NewCore(binary, t.TempDir())
	defer core.Stop()
	if err = core.Start(context.Background(), "proxies: []\nrules: ['MATCH,DIRECT']\n", settings, false); err == nil || core.Status().Running || !strings.Contains(err.Error(), "UDP port") {
		t.Fatalf("occupied UDP port should not become a connected status: %v", err)
	}
}

func TestRealCoreFailedTUNValidationKeepsCause(t *testing.T) {
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	c := NewCore(binary, t.TempDir())
	s := DefaultSettings()
	s.Tun = true
	s.SystemProxy = false
	err := c.Start(context.Background(), "proxies: [{name: bad, type: socks5, certificate: /etc/shadow}]", s, true)
	if err == nil || c.Status().Running || c.Status().Error != err.Error() || !strings.Contains(strings.Join(c.Logs(), "\n"), "inline certificate") {
		t.Fatal("startup failure is missing from stopped status or diagnostic logs")
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
