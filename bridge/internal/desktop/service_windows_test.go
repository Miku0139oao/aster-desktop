package desktop

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// This installs a LocalSystem service and enables TUN. Never opt in on a user
// workstation: the workflow enables it only on a disposable GitHub runner.
func TestWindowsServiceTUNLifecycle(t *testing.T) {
	if os.Getenv("ASTER_TEST_WINDOWS_SERVICE") != "disposable-runner" {
		t.Skip("requires a disposable elevated Windows runner")
	}
	if ServiceStatus()["installed"] == true {
		t.Fatal("refusing to replace an existing Aster Desktop service")
	}
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Fatal("ASTER_TEST_CORE is required")
	}
	sid, err := currentSID()
	if err != nil {
		t.Fatal(err)
	}
	bridge := filepath.Join(filepath.Dir(binary), "aster-bridge.exe")
	cmd := exec.Command(bridge, "--install-service", "--owner", sid)
	hideCommand(cmd)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("install service: %s %v", output, err)
	}
	defer func() {
		if err := RemoveWindowsService(); err != nil {
			t.Errorf("uninstall service: %v", err)
		}
	}()
	var client *ServiceClient
	for limit := time.Now().Add(10 * time.Second); time.Now().Before(limit); {
		client, err = ConnectService()
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	s := DefaultSettings()
	s.Tun, s.SystemProxy = true, false
	s.AllowLAN = true
	s.MixedPort = unusedPort()
	interfaces, err := ListNetworkInterfaces()
	if err != nil || len(interfaces) == 0 {
		t.Fatalf("runner has no available outbound network: %v", err)
	}
	s.TunInterface = interfaces[0].Name
	bad := map[string]any{"content": "tls: {certificate: /private/file}", "settings": s}
	if err = client.Call("start", bad, nil); err == nil || !strings.Contains(err.Error(), "inline certificate") {
		t.Fatalf("file resource validation: %v", err)
	}
	var status CoreStatus
	if err = client.Call("status", nil, &status); err != nil || status.Running || status.Error == "" {
		t.Fatalf("failed startup cause was lost: %+v %v", status, err)
	}
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
			return
		case <-time.After(17 * time.Second):
		}
		fmt.Fprint(w, "payload: ['DOMAIN,slow.example']\n")
	}))
	defer provider.Close()
	content := fmt.Sprintf(`template: &ws
  type: vmess
  server: example.com
  port: 443
  uuid: 00000000-0000-4000-8000-000000000001
  alterId: 0
  cipher: auto
  network: ws
  ws-opts: {path: /websocket}
proxies: [{<<: *ws, name: WS}]
log-level: warning
rule-providers:
  slow: {type: http, behavior: classical, url: %q, interval: 3600}
rules: ['RULE-SET,slow,DIRECT', 'MATCH,DIRECT']
dns: {enable: true, respect-rules: true, enhanced-mode: redir-host, nameserver: [system], proxy-server-nameserver: [system]}
tun: {device: AsterSvcTest}
`, provider.URL)
	params := map[string]any{"content": content, "settings": s}
	if err = client.Call("start", params, nil); err != nil {
		t.Fatal(err)
	}
	status = CoreStatus{} // Healthy responses omit the optional error field.
	if err = client.Call("status", nil, &status); err != nil || !status.Running || status.Error != "" {
		t.Fatalf("core not ready: %+v %v", status, err)
	}
	var version json.RawMessage
	if err = client.Call("controller", map[string]string{"method": "GET", "path": "/version"}, &version); err != nil {
		t.Fatal(err)
	}
	var config struct {
		Interface string `json:"interface-name"`
		Tun       struct {
			Enable     bool `json:"enable"`
			AutoDetect bool `json:"auto-detect-interface"`
		} `json:"tun"`
	}
	if err = client.Call("controller", map[string]string{"method": "GET", "path": "/configs"}, &config); err != nil || !config.Tun.Enable {
		t.Fatalf("TUN did not initialize with a cold provider: %+v %v", config, err)
	}
	if config.Interface != s.TunInterface || config.Tun.AutoDetect {
		t.Fatalf("service did not bind to the chosen uplink: %+v", config)
	}
	if err = client.Call("controller", map[string]string{"method": "POST", "path": "/restart"}, nil); err == nil {
		t.Fatal("unsupported privileged controller operation accepted")
	}
	if err = client.Call("stop", nil, nil); err != nil {
		t.Fatal(err)
	}
	if err = client.Call("status", nil, &status); err != nil || status.Running || status.Error != "" {
		t.Fatalf("normal stop became an error: %+v %v", status, err)
	}
	if err = client.Call("start", params, nil); err != nil {
		t.Fatal("reconnect:", err)
	}
	client.Close() // EOF must stop the service-owned core.
	for limit := time.Now().Add(15 * time.Second); time.Now().Before(limit); {
		next, e := ConnectService()
		if e == nil {
			e = next.Call("status", nil, &status)
			next.Close()
			if e == nil && !status.Running {
				return
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("core remained after the desktop session closed")
}
