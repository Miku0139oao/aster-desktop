package desktop

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The test denies every direct dial. HTTPS, redirects and API calls can reach
// the local fixture only through the chosen CONNECT proxy, never the internet.
func TestUpdateUsesManagedProxyIncludingHTTPSRedirects(t *testing.T) {
	var tunnels atomic.Int32
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/asset":
			http.Redirect(w, r, "https://release-assets.githubusercontent.com/final", http.StatusFound)
		case "/final":
			_, _ = w.Write([]byte("downloaded"))
		default:
			_ = json.NewEncoder(w).Encode(Release{Tag: "fixture"})
		}
	}))
	defer upstream.Close()
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "CONNECT" {
			t.Error("HTTPS download did not use CONNECT")
			w.WriteHeader(400)
			return
		}
		tunnels.Add(1)
		target, err := net.Dial("tcp", upstream.Listener.Addr().String())
		if err != nil {
			t.Error(err)
			return
		}
		defer target.Close()
		conn, buffered, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close()
		_, _ = buffered.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		_ = buffered.Flush()
		go func() { _, _ = io.Copy(target, buffered); _ = target.Close() }()
		_, _ = io.Copy(conn, target)
	}))
	defer proxy.Close()
	previous := http.DefaultClient
	transport := &http.Transport{
		// This isolated fixture substitutes its certificate for GitHub's name.
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			if address != proxy.Listener.Addr().String() {
				return nil, errors.New("direct network forbidden")
			}
			return (&net.Dialer{}).DialContext(ctx, network, address)
		},
	}
	http.DefaultClient = &http.Client{Transport: transport}
	t.Cleanup(func() { transport.CloseIdleConnections(); http.DefaultClient = previous })
	_, rawPort, _ := net.SplitHostPort(proxy.Listener.Addr().String())
	port, _ := strconv.Atoi(rawPort)
	ctx, closeClient := updateContext(context.Background(), port)
	defer closeClient()
	if _, err := CheckUpdates(ctx); err != nil {
		t.Fatal(err)
	}
	if data, err := fetch(ctx, "https://github.com/asset", 64<<20); err != nil || string(data) != "downloaded" {
		t.Fatalf("proxied download/redirect: %q %v", data, err)
	}
	if tunnels.Load() < 3 {
		t.Fatal("API, asset and redirected host were not proxied")
	}
	if transport.Proxy != nil {
		t.Fatal("global HTTP transport was mutated")
	}
	if _, err := fetch(context.Background(), coreReleaseAPI, 1<<20); err == nil {
		t.Fatal("fixture unexpectedly allowed direct access")
	}
	proxy.Close()
	client := ctx.Value(updateClientKey{}).(*http.Client)
	client.CloseIdleConnections()
	if _, err := fetch(ctx, coreReleaseAPI, 1<<20); err == nil {
		t.Fatal("failed proxy silently fell back to direct")
	}
}

type checkedUpdateTransport struct {
	base http.RoundTripper
	core *Core
	pid  int
	t    *testing.T
}

func (c checkedUpdateTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if status := c.core.Status(); !status.Running || status.PID != c.pid {
		c.t.Error("working core stopped before download completed")
	}
	return c.base.RoundTrip(req)
}

// A native process fixture advertises TUN readiness without creating any OS
// adapter or modifying the user's proxy. Real OS TUN remains a separate CI test.
func TestConnectedServiceUpdatePreservesTUNAndRollsBack(t *testing.T) {
	for _, scenario := range []string{"success", "checksum", "startup-failure"} {
		t.Run(scenario, func(t *testing.T) {
			t.Setenv("ASTER_CORE_FIXTURE", "update-ready")
			if scenario == "startup-failure" {
				t.Setenv("ASTER_FAIL_CANDIDATE", "1")
			}
			binary, _ := os.Executable()
			candidate, err := os.ReadFile(binary)
			if err != nil {
				t.Fatal(err)
			}
			mockUpdate(t, candidate, scenario == "checksum", false)
			core := NewCore(binary, filepath.Join(t.TempDir(), "runtime"))
			defer core.Stop()
			settings := DefaultSettings()
			settings.Tun, settings.SystemProxy, settings.AllowLAN, settings.Mode = true, false, false, "global"
			settings.MixedPort = unusedPort()
			content := "proxies: []\nrules: ['MATCH,DIRECT']\n"
			ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
			defer cancel()
			if err = core.Start(ctx, content, settings, true); err != nil {
				t.Fatal(err)
			}
			if _, err = core.Request(ctx, "PUT", "/proxies/Proxy", map[string]string{"name": "Backup"}); err != nil {
				t.Fatal(err)
			}
			before := core.Status().PID
			http.DefaultClient.Transport = checkedUpdateTransport{base: http.DefaultClient.Transport, core: core, pid: before, t: t}
			_, err = UpdateServiceCore(ctx, core, 0)
			if (err == nil) != (scenario == "success") {
				t.Fatalf("unexpected update result: %v", err)
			}
			if !core.Status().Running {
				t.Fatal("service stopped its core when update returned")
			}
			if scenario == "checksum" && core.Status().PID != before {
				t.Fatal("checksum failure interrupted TUN")
			}
			if scenario != "success" && core.Binary != binary {
				t.Fatal("failed update did not retain/restore old binary")
			}
			if scenario == "success" && core.Binary == binary {
				t.Fatal("new binary was not selected")
			}
			body, err := core.Request(ctx, "GET", "/configs", nil)
			if err != nil || !bytes.Contains(body, []byte(`"enable":true`)) || !bytes.Contains(body, []byte(`"mode":"global"`)) || !bytes.Contains(body, []byte(strconv.Itoa(settings.MixedPort))) {
				t.Fatalf("TUN, mode or port not restored: %s %v", body, err)
			}
			body, err = core.Request(ctx, "GET", "/proxies", nil)
			if err != nil || !bytes.Contains(body, []byte(`"now":"Backup"`)) {
				t.Fatalf("selected node lost: %s %v", body, err)
			}
			data, err := os.ReadFile(filepath.Join(core.Dir, "runtime.yaml"))
			if err != nil || !strings.Contains(string(data), "enable: true") {
				t.Fatal("effective TUN runtime lost")
			}
		})
	}
}

func TestUpdateRenewsExistingServiceLease(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	remote := &ServiceClient{conn: client, reader: bufio.NewReader(client)}
	renewed := make(chan struct{})
	go func() {
		var req Request
		if json.NewDecoder(server).Decode(&req) == nil && req.Method == "status" {
			_ = json.NewEncoder(server).Encode(Response{ID: req.ID, Result: CoreStatus{Running: true}})
			close(renewed)
		}
	}()
	stop := remote.keepUpdateLease()
	defer stop()
	select {
	case <-renewed:
	case <-time.After(25 * time.Second):
		t.Fatal("update did not renew the existing session")
	}
}

func TestDesktopCanUpdateWhileOwningServiceConnection(t *testing.T) {
	testDesktopServiceUpdate(t, false)
}
func TestDesktopServiceRollbackRestoresAutomaticSelection(t *testing.T) {
	testDesktopServiceUpdate(t, true)
}
func testDesktopServiceUpdate(t *testing.T, rollback bool) {
	t.Setenv("ASTER_CORE_FIXTURE", "update-ready")
	t.Setenv("ASTER_AUTOMATIC_GROUP_FIXTURE", "1")
	binary, _ := os.Executable()
	data, err := os.ReadFile(binary)
	if err != nil {
		t.Fatal(err)
	}
	mockUpdate(t, data, false, false)
	root := NewCore(binary, filepath.Join(t.TempDir(), "runtime"))
	settings := DefaultSettings()
	settings.Tun, settings.SystemProxy, settings.MixedPort = true, false, unusedPort()
	content := "proxies: []\nrules: ['MATCH,DIRECT']\n"
	if err = root.Start(context.Background(), content, settings, true); err != nil {
		t.Fatal(err)
	}
	defer root.Stop()
	if _, err = root.Request(context.Background(), "PUT", "/proxies/Proxy", map[string]string{"name": "Backup"}); err != nil {
		t.Fatal(err)
	}
	if rollback {
		t.Setenv("ASTER_FAIL_CANDIDATE", "1")
	}
	client, server := net.Pipe()
	defer server.Close()
	var updates atomic.Int32
	go func() {
		defer root.Stop()
		decoder := json.NewDecoder(server)
		for {
			var req Request
			if decoder.Decode(&req) != nil {
				return
			}
			var result any
			var callErr error
			switch req.Method {
			case "updateCore":
				result, callErr = UpdateServiceCore(context.Background(), root, 0)
				updates.Add(1)
			case "status":
				result = root.Status()
			case "stop":
				callErr = root.Stop()
			case "controller":
				var p struct {
					Method, Path string
					Body         any
				}
				_ = json.Unmarshal(req.Params, &p)
				result, callErr = root.Request(context.Background(), p.Method, p.Path, p.Body)
			default:
				callErr = errors.New("unexpected service call")
			}
			reply := Response{ID: req.ID, Result: result}
			if callErr != nil {
				reply.Error = &RPCError{Message: callErr.Error()}
			}
			if json.NewEncoder(server).Encode(reply) != nil {
				return
			}
		}
	}()
	app, err := NewApp(t.TempDir(), binary, "")
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	app.Store.State.Settings, app.Store.State.ActiveID = settings, "fixture"
	app.Store.State.Profiles = []Profile{{ID: "fixture", Content: content}}
	app.Store.State.Selections = map[string]string{"Proxy": "Backup"}
	remote := &ServiceClient{conn: client, reader: bufio.NewReader(client)}
	app.remote = remote
	if _, err = app.Dispatch(context.Background(), Request{Method: "updateCore"}); (err != nil) != rollback {
		t.Fatalf("unexpected update result: %v", err)
	}
	if app.remote != remote || !root.Status().Running || updates.Load() != 1 {
		t.Fatal("update lost service ownership or did not update the running service")
	}
	if app.Core.Status().Running || app.Core.Binary == binary || (root.Binary == binary) != rollback {
		t.Fatal("user and service copies were not independently updated")
	}
	body, err := app.dispatchCore(context.Background(), "GET", "/proxies", nil)
	if err != nil || !bytes.Contains(body, []byte(`"now":"Backup"`)) {
		t.Fatalf("desktop selection not restored: %s %v", body, err)
	}
}

func TestStoppedHelperUpdateRetainsNormalCoreProxyOwnership(t *testing.T) {
	for _, failure := range []bool{false, true} {
		t.Run(strconv.FormatBool(failure), func(t *testing.T) {
			t.Setenv("ASTER_CORE_FIXTURE", "update-ready")
			binary, _ := os.Executable()
			data, err := os.ReadFile(binary)
			if err != nil {
				t.Fatal(err)
			}
			mockUpdate(t, data, failure, false)
			core := NewCore(binary, filepath.Join(t.TempDir(), "runtime"))
			// An inert snapshot detects accidental Stop/Close without changing OS
			// settings. The helper owns a separate, normal core's proxy on macOS.
			snapshot := &ProxySnapshot{}
			core.proxy = snapshot
			_, err = UpdateServiceCore(context.Background(), core, unusedPort())
			if (err != nil) != failure {
				t.Fatalf("unexpected update result: %v", err)
			}
			if core.proxy != snapshot || core.Status().Running {
				t.Fatal("helper update changed normal proxy ownership")
			}
			core.proxy = nil
		})
	}
	core := NewCore("unused", t.TempDir())
	if _, err := UpdateServiceCore(context.Background(), core, 65536); err == nil {
		t.Fatal("invalid caller proxy port accepted")
	}
}
