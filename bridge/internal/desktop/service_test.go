package desktop

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestServiceStartupFailureReturnsDiagnosticsAndAllowsRetry(t *testing.T) {
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	core := NewCore(binary, t.TempDir())
	core.appendLog("privileged startup diagnostic")
	client, conn := net.Pipe()
	defer client.Close()
	go serveServiceSession(context.Background(), conn, core)
	remote := &ServiceClient{conn: client, reader: bufio.NewReader(client)}
	bad := map[string]any{"settings": DefaultSettings(), "content": "tls: {certificate: /private/file}"}
	var response *RPCError
	err = remote.Call("start", bad, nil)
	if !errors.As(err, &response) || !strings.Contains(response.Message, "inline certificate") {
		t.Fatalf("expected a configuration error, got %v", err)
	}
	if len(response.Logs) == 0 || response.Logs[0] != "privileged startup diagnostic" {
		t.Fatalf("expected startup logs in the failure response, got %q", response.Logs)
	}
	var status CoreStatus
	if err := remote.Call("status", nil, &status); err != nil || status.Running {
		t.Fatalf("service session not usable after a configuration error: %+v %v", status, err)
	}
}

func TestServiceClientClosesMismatchedSession(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	remote := &ServiceClient{conn: client, reader: bufio.NewReader(client)}
	_ = server.SetDeadline(time.Now().Add(5 * time.Second))
	go func() {
		var request Request
		if json.NewDecoder(server).Decode(&request) == nil {
			_ = json.NewEncoder(server).Encode(Response{ID: request.ID + 1})
		}
	}()
	if err := remote.Call("start", nil, nil); err == nil || !strings.Contains(err.Error(), "did not match request") {
		t.Fatalf("expected a protocol error, got %v", err)
	}
	if err := client.SetWriteDeadline(time.Now()); err == nil {
		t.Fatal("invalid session was not closed")
	}
}

func TestServiceSessionCloseCancelsGeoSiteRetry(t *testing.T) {
	t.Setenv("ASTER_CORE_FIXTURE", "geosite-retry")
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	core := NewCore(binary, t.TempDir())
	if err := os.WriteFile(filepath.Join(core.Dir, "GeoSite.dat"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	client, server := net.Pipe()
	defer client.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		serveServiceSession(ctx, server, core)
	}()
	remote := &ServiceClient{conn: client, reader: bufio.NewReader(client)}
	callDone := make(chan error, 1)
	go func() {
		callDone <- remote.Call("start", map[string]any{
			"settings": DefaultSettings(), "content": "proxies: []\nrules: ['MATCH,DIRECT']\n",
		}, nil)
	}()
	readyPath := filepath.Join(core.Dir, "retry-ready")
	deadline := time.NewTimer(12 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for {
		if _, err := os.Stat(readyPath); err == nil {
			break
		}
		select {
		case err := <-callDone:
			t.Fatalf("service returned before retrying GeoSite validation: %v", err)
		case <-deadline.C:
			t.Fatal("service did not retry GeoSite validation")
		case <-ticker.C:
		}
	}
	remote.Close()
	select {
	case <-done:
	case <-time.After(7 * time.Second):
		t.Fatal("service did not stop after desktop disconnected during GeoSite retry")
	}
	if status := core.Status(); status.Running || !strings.Contains(status.Error, context.Canceled.Error()) {
		t.Fatalf("startup cancellation was not recorded: %+v", status)
	}
}

func TestDisconnectRetainsFailedProxyRecovery(t *testing.T) {
	if runtime.GOOS != "windows" && runtime.GOOS != "linux" && runtime.GOOS != "darwin" {
		t.Skip("requires a system proxy backend")
	}
	dir := t.TempDir()
	runtimeDir := filepath.Join(dir, "runtime")
	if err := os.Mkdir(runtimeDir, 0700); err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(runtimeDir, "proxy-backup.json")
	if err := os.WriteFile(backup, []byte(`{"backend":"invalid"}`), 0600); err != nil {
		t.Fatal(err)
	}
	app, err := NewApp(dir, "unused-core", "")
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	for range 2 {
		if _, err := app.Dispatch(context.Background(), Request{Method: "disconnect"}); err == nil || !strings.Contains(err.Error(), "invalid proxy backup") {
			t.Fatalf("expected disconnect to report the unrecovered proxy snapshot: %v", err)
		}
	}
	if _, err := os.Stat(backup); err != nil {
		t.Fatalf("unrestored backup was lost: %v", err)
	}
}

func TestDisconnectCanRetryServiceStop(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	if err := server.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	remote := &ServiceClient{conn: client, reader: bufio.NewReader(client)}
	app := &App{Core: NewCore("", t.TempDir()), remote: remote}
	go func() {
		decoder, encoder := json.NewDecoder(server), json.NewEncoder(server)
		for i := range 2 {
			var req Request
			if decoder.Decode(&req) != nil || req.Method != "stop" {
				server.Close()
				return
			}
			response := Response{ID: req.ID}
			if i == 0 {
				response.Error = &RPCError{Code: "service", Message: "core shutdown did not complete"}
			}
			if encoder.Encode(response) != nil {
				return
			}
		}
	}()
	if err := app.stop(); err == nil || !strings.Contains(err.Error(), "core shutdown did not complete") || app.remote != remote {
		t.Fatalf("first stop did not preserve the service session: %v", err)
	}
	if err := app.stop(); err != nil || app.remote != nil {
		t.Fatalf("second stop did not release the service session: %v", err)
	}
}
