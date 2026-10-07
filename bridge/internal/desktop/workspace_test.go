package desktop

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

func TestYAMLEditsFollowExistingDesktopOverlays(t *testing.T) {
	p := Profile{
		DesktopObjects:  map[string]map[string]map[string]any{"proxies": {"Custom": {"name": "Custom", "port": 1080}, "Gone": {"name": "Gone"}}},
		DesktopSettings: map[string]any{"dns": map[string]any{"enable": true}},
		DisabledRules:   []string{"DOMAIN,example.com,DIRECT"}, RuleOrder: []string{"MATCH,DIRECT"},
	}
	content := "proxies: [{name: Custom, type: socks5, server: 192.0.2.1, port: 2080}]\ndns: {enable: false}\nrules: ['DOMAIN,example.com,DIRECT','MATCH,DIRECT']\n"
	if err := reconcileWorkspace(content, &p); err != nil {
		t.Fatal(err)
	}
	if p.DesktopObjects["proxies"]["Custom"]["port"] != 2080 || len(p.DisabledRules) != 0 || p.RuleOrder[0] != "DOMAIN,example.com,DIRECT" {
		t.Fatal("explicit YAML changes were lost")
	}
	if p.DesktopSettings["dns"].(map[string]any)["enable"] != false || len(p.DesktopRemoved["proxies"]) != 1 {
		t.Fatal("settings or removed object not reconciled")
	}
	merged, err := mergeWorkspace("proxies: [{name: Gone}]\ndns: {enable: true}\nrules: ['MATCH,DIRECT']", p)
	if err != nil || strings.Contains(merged, "Gone") || !strings.Contains(merged, "2080") || !strings.Contains(merged, "enable: false") {
		t.Fatal("refresh resurrected old overlay", merged, err)
	}
}

func TestWorkspaceOverlayTransactionsWithRealCore(t *testing.T) {
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	app, err := NewApp(t.TempDir(), binary, "")
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	app.Store.State.Settings.SystemProxy = false
	app.Store.State.Settings.MixedPort = unusedPort()
	var generation atomic.Int32
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if generation.Load() == 2 {
			http.Error(w, "offline", 503)
			return
		}
		fmt.Fprintf(w, "proxies: [{name: Original, type: socks5, server: 192.0.2.1, port: %d}]\nproxy-groups: [{name: Choose, type: select, proxies: [Original,DIRECT]}]\nrules: ['DOMAIN,example.com,DIRECT','MATCH,Choose']\n", 1080+generation.Load())
	}))
	defer source.Close()
	call := func(method string, params any) (json.RawMessage, error) {
		b, _ := json.Marshal(params)
		result, err := app.Dispatch(context.Background(), Request{Method: method, Params: b})
		if err != nil {
			return nil, err
		}
		return result.(json.RawMessage), nil
	}
	must := func(method string, params any) json.RawMessage {
		t.Helper()
		b, err := call(method, params)
		if err != nil {
			t.Fatal(method, err)
		}
		return b
	}
	var p Profile
	_ = json.Unmarshal(must("import", map[string]any{"url": source.URL, "name": "Demo"}), &p)
	id := p.ID
	must("manageObject", map[string]any{"id": id, "field": "proxies", "oldName": "Custom", "action": "create", "object": map[string]any{"name": "Custom", "type": "http", "server": "192.0.2.3", "port": 8080}})
	must("manageObject", map[string]any{"id": id, "field": "proxy-groups", "oldName": "Choose", "object": map[string]any{"name": "Choose", "type": "select", "proxies": []string{"Custom", "Original", "DIRECT"}}})
	originalDate := app.Store.State.Profiles[0].Updated
	if !originalDate.Equal(p.Updated) {
		t.Fatal("editing a desktop object postponed subscription refresh")
	}
	generation.Store(1)
	var preview SubscriptionPreview
	_ = json.Unmarshal(must("previewRefresh", map[string]string{"id": id}), &preview)
	if len(preview.Changed) == 0 {
		t.Fatal("download change was not detected")
	}
	before := app.Store.State.Profiles[0].Content
	if !strings.Contains(before, "port: 1080") {
		t.Fatal("preview changed active configuration")
	}
	must("applyRefresh", map[string]string{"id": id, "token": preview.Token})
	var doc map[string]any
	_ = yaml.Unmarshal([]byte(app.Store.State.Profiles[0].Content), &doc)
	nodes := doc["proxies"].([]any)
	if len(nodes) != 2 || !strings.Contains(app.Store.State.Profiles[0].Content, "Custom") || !strings.Contains(app.Store.State.Profiles[0].Content, "port: 1081") {
		t.Fatal("desktop overlay or remote update lost")
	}
	before = app.Store.State.Profiles[0].Content
	if _, err := call("manageObject", map[string]any{"id": id, "field": "proxies", "oldName": "Custom", "action": "delete"}); err == nil {
		t.Fatal("deleted a referenced node")
	}
	if app.Store.State.Profiles[0].Content != before {
		t.Fatal("failed deletion modified profile")
	}
	if _, err := call("manageObject", map[string]any{"id": id, "field": "proxies", "oldName": "Custom", "action": "create", "object": map[string]any{"name": "Custom", "type": "http", "server": "192.0.2.8", "port": 8080}}); err == nil {
		t.Fatal("duplicate name silently replaced a node")
	}
	must("manageRules", map[string]any{"id": id, "rule": "DOMAIN,example.com,DIRECT", "action": "disable"})
	must("patchProfile", map[string]any{"id": id, "rule": "PROCESS-NAME,fixture,DIRECT"})
	if strings.Contains(app.Store.State.Profiles[0].Content, "DOMAIN,example.com,DIRECT") {
		t.Fatal("adding a rule re-enabled a disabled rule")
	}
	must("refresh", map[string]string{"id": id})
	if strings.Contains(app.Store.State.Profiles[0].Content, "DOMAIN,example.com,DIRECT") {
		t.Fatal("refresh re-enabled a disabled rule")
	}
	must("manageRules", map[string]any{"id": id, "rule": "DOMAIN,example.com,DIRECT", "action": "enable"})
	must("batchApplicationRules", map[string]any{"id": id, "paths": []string{"/fixture/browser", "/fixture/helper"}, "target": "REJECT"})
	if !strings.Contains(app.Store.State.Profiles[0].Content, "PROCESS-PATH,/fixture/helper,REJECT") {
		t.Fatal("batch application routing not applied")
	}
	before = app.Store.State.Profiles[0].Content
	if _, err := call("batchApplicationRules", map[string]any{"id": id, "paths": []string{"/fixture/valid", "/fixture/invalid,path"}, "target": "DIRECT"}); err == nil {
		t.Fatal("invalid path accepted")
	}
	if app.Store.State.Profiles[0].Content != before {
		t.Fatal("batch failure partially applied")
	}
	_ = json.Unmarshal(must("previewRefresh", map[string]string{"id": id}), &preview)
	must("profileMetadata", map[string]any{"id": id, "name": "Renamed", "intervalHours": 0})
	if _, err := call("applyRefresh", map[string]string{"id": id, "token": preview.Token}); err == nil {
		t.Fatal("stale preview applied")
	}
	generation.Store(2)
	if _, err := call("refresh", map[string]string{"id": id}); err == nil {
		t.Fatal("failed source accepted")
	}
	if app.Store.State.Profiles[0].Content != before || app.Store.State.Profiles[0].LastError == "" {
		t.Fatal("refresh failure lost content or recovery status")
	}
	must("duplicateProfile", map[string]string{"id": id})
	if len(app.Store.State.Profiles) != 2 || app.Store.State.Profiles[1].URL != "" || len(app.Store.State.Profiles[1].DesktopObjects) == 0 {
		t.Fatal("local duplicate lost overlays")
	}
	must("preferences", map[string]any{"preferences": map[string]any{"favorites:" + id: []string{"Custom"}}})
	reopened, err := OpenStore(app.Store.Dir)
	if err != nil || reopened.State.Preferences == nil || *reopened.State.Profiles[0].IntervalHours != 0 {
		t.Fatal("workspace preferences did not persist", err)
	}
}

func TestTrafficHistoryDeltasResetClearPersistenceAndSamples(t *testing.T) {
	dir := t.TempDir()
	h := NewTrafficHistory(dir)
	now := time.Now()
	h.record("one", 100, 200, now)
	h.record("one", 100, 200, now)
	h.record("one", 130, 250, now)
	c := TrafficConnection{ID: "id", Upload: 30, Download: 50, Chains: []string{"Node", "Group"}}
	c.Metadata.Process = "Browser"
	h.recordConnections([]TrafficConnection{c}, now)
	h.recordConnections([]TrafficConnection{c}, now)
	if h.days[0].Upload != 130 || h.days[0].Download != 250 || h.days[0].Applications["Browser"].Download != 50 {
		t.Fatal("duplicate counting")
	}
	h.record("one", 10, 20, now) // Explicit counter reset in the same core session.
	h.record("two", 5, 7, now)
	if h.days[0].Upload != 145 || h.days[0].Download != 277 {
		t.Fatal("session/reset deltas wrong")
	}
	if err := h.Flush(); err != nil {
		t.Fatal(err)
	}
	reloaded := NewTrafficHistory(dir)
	if reloaded.days[0].Download != 277 {
		t.Fatal("history was not persisted")
	}
	if err := h.Clear(); err != nil {
		t.Fatal(err)
	}
	h.record("two", 5, 7, now)
	if len(h.days) != 0 {
		t.Fatal("clearing history recounted the core session")
	}
	h.record("two", 8, 12, now)
	if h.days[0].Upload != 3 || h.days[0].Download != 5 {
		t.Fatal("clear lost baseline")
	}
	snapshot := h.Snapshot()
	days := snapshot["days"].([]TrafficDay)
	days[0].Download = 999
	if h.days[0].Download == 999 {
		t.Fatal("snapshot aliases live history")
	}
	h.path = dir + "/missing/history.json"
	if err := h.Clear(); err == nil || len(h.days) == 0 {
		t.Fatal("failed clear discarded data")
	}
}

func TestBoundedDNSControllerOperations(t *testing.T) {
	for _, test := range []struct {
		method, path string
		ok           bool
	}{
		{"GET", "/dns/query?name=example.com&type=A", true}, {"GET", "/dns/query?name=example.com&type=TXT", true},
		{"GET", "/dns/query?name=&type=A", false}, {"GET", "/dns/query?name=example.com&type=INVALID", false},
		{"POST", "/cache/dns/flush", true}, {"POST", "/cache/fakeip/flush", false}, {"POST", "/cache/dns/flush?unsafe=1", false},
		{"GET", "https://example.com/dns/query?name=example.com&type=A", false},
	} {
		if allowedController(test.method, test.path) != test.ok {
			t.Error(test)
		}
	}
}
