package desktop

import (
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"gopkg.in/yaml.v3"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// A real native executable that can emulate an incompatible/new failing core.
func TestMain(m *testing.M) {
	if mode := os.Getenv("ASTER_SERVICE_PROBE"); mode != "" {
		os.Exit(serviceProbe(mode))
	}
	if mode := os.Getenv("ASTER_CORE_FIXTURE"); mode != "" {
		args := os.Args[1:]
		config := ""
		for i, arg := range args {
			if arg == "-t" {
				os.Exit(0)
			}
			if arg == "-f" && i+1 < len(args) {
				config = args[i+1]
			}
		}
		if mode == "startup-failure" && !strings.Contains(config, "compat-") {
			os.Exit(7)
		}
		if mode == "tun-not-ready" {
			fmt.Println("Start TUN listening error: permission denied")
		}
		data, err := os.ReadFile(config)
		if err != nil {
			os.Exit(8)
		}
		doc := map[string]any{}
		if err = yaml.Unmarshal(data, &doc); err != nil {
			os.Exit(9)
		}
		listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%v", doc["mixed-port"]))
		if err != nil {
			os.Exit(10)
		}
		go func() {
			for {
				connection, err := listener.Accept()
				if err != nil {
					return
				}
				_ = connection.Close()
			}
		}()
		http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			fields := map[string]any{"/version": map[string]any{"version": "fixture"}, "/configs": map[string]any{"mode": "rule"}, "/proxies": map[string]any{"proxies": map[string]any{}}, "/rules": map[string]any{"rules": []any{}}, "/connections": map[string]any{"connections": []any{}}}
			if mode == "incompatible" && r.URL.Path == "/configs" {
				fields[r.URL.Path] = map[string]any{"unsupported": true}
			}
			fields["/providers/proxies"] = map[string]any{"providers": map[string]any{}}
			if mode == "provider-incompatible" && r.URL.Path == "/providers/proxies" {
				fields[r.URL.Path] = map[string]any{"unsupported": true}
			}
			_ = json.NewEncoder(w).Encode(fields[r.URL.Path])
		})
		_ = http.ListenAndServe(doc["external-controller"].(string), nil)
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestTUNRequiresReadyAdapterDespiteWorkingController(t *testing.T) {
	t.Setenv("ASTER_CORE_FIXTURE", "tun-not-ready")
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	c := NewCore(binary, t.TempDir())
	defer c.Stop()
	s := DefaultSettings()
	s.Tun, s.SystemProxy = true, false
	s.MixedPort = unusedPort()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	err = c.Start(ctx, "proxies: []\nrules: ['MATCH,DIRECT']\n", s, true)
	if err == nil || c.Status().Running || !strings.Contains(err.Error(), "TUN adapter") || !strings.Contains(err.Error(), "permission denied") {
		t.Fatalf("controller readiness falsely reported a TUN connection: %v", err)
	}
}

func serviceProbe(mode string) int {
	remote, err := ConnectService()
	if mode == "unauthorized" {
		if err != nil {
			return 0
		}
		defer remote.Close()
		if remote.Call("status", nil, nil) != nil {
			return 0
		}
		return 1
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	defer remote.Close()
	settings := DefaultSettings()
	settings.Tun = true
	settings.SystemProxy = false
	settings.MixedPort = 17901
	content := "proxies: []\nrules:\n - MATCH,DIRECT\ndns:\n enable: true\n enhanced-mode: fake-ip\n nameserver: [1.1.1.1]\ntun:\n device: AsterSvcTest\n stack: gvisor\n"
	if err = remote.Call("start", map[string]any{"content": content, "settings": settings}, nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 3
	}
	var status CoreStatus
	if err = remote.Call("status", nil, &status); err != nil || !status.Running {
		return 4
	}
	if err = remote.Call("controller", map[string]any{"method": "GET", "path": "/version"}, nil); err != nil {
		return 5
	}
	if err = remote.Call("controller", map[string]any{"method": "PUT", "path": "/configs", "body": map[string]any{}}, nil); err == nil {
		return 6
	}
	if err = remote.Call("launchArbitraryBinary", map[string]any{"path": "/bin/sh"}, nil); err == nil {
		return 7
	}
	// Exit without issuing stop: the helper must stop TUN on client EOF.
	return 0
}

type updateTransport struct {
	assets      map[string][]byte
	interrupted bool
}

func (u updateTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if u.interrupted && strings.HasSuffix(r.URL.Path, "fixture.zip") {
		return nil, errors.New("interrupted download")
	}
	if u.interrupted && strings.HasSuffix(r.URL.Path, "fixture.gz") {
		return nil, errors.New("interrupted download")
	}
	data, ok := u.assets[r.URL.String()]
	if !ok {
		return nil, fmt.Errorf("unexpected update URL: %s", r.URL)
	}
	return &http.Response{StatusCode: 200, Header: http.Header{}, Body: io.NopCloser(bytes.NewReader(data)), Request: r}, nil
}
func mockUpdate(t *testing.T, candidate []byte, wrongHash, interrupted bool) {
	t.Helper()
	name := assetPrefix() + "fixture.gz"
	var buf bytes.Buffer
	if runtime.GOOS == "windows" {
		name = assetPrefix() + "fixture.zip"
		writer := zip.NewWriter(&buf)
		f, _ := writer.Create("aster-core-fixture.exe")
		_, _ = f.Write(candidate)
		_ = writer.Close()
	} else {
		writer := gzip.NewWriter(&buf)
		_, _ = writer.Write(candidate)
		_ = writer.Close()
	}
	base := "https://github.com/Miku0139oao/aster-core/releases/download/Prerelease-main/"
	releaseData, _ := json.Marshal(Release{Tag: "Prerelease-main", Assets: []ReleaseAsset{{Name: name, URL: base + name}, {Name: "checksums.txt", URL: base + "checksums.txt"}}})
	sum := sha256.Sum256(buf.Bytes())
	if wrongHash {
		sum = sha256.Sum256([]byte("wrong"))
	}
	previous := http.DefaultClient
	http.DefaultClient = &http.Client{Transport: updateTransport{assets: map[string][]byte{coreReleaseAPI: releaseData, base + name: buf.Bytes(), base + "checksums.txt": []byte(fmt.Sprintf("%x  %s\n", sum, name))}, interrupted: interrupted}}
	t.Cleanup(func() { http.DefaultClient = previous })
}

func TestUpdateFailuresKeepRealRunningCore(t *testing.T) {
	core := os.Getenv("ASTER_TEST_CORE")
	if core == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	fixturePath, _ := os.Executable()
	fixture, err := os.ReadFile(fixturePath)
	if err != nil {
		t.Fatal(err)
	}
	for _, scenario := range []string{"checksum", "architecture", "interrupted", "incompatible", "provider-incompatible", "startup-failure"} {
		t.Run(scenario, func(t *testing.T) {
			candidate := fixture
			if scenario == "architecture" {
				candidate = []byte("not a native executable")
			}
			mockUpdate(t, candidate, scenario == "checksum", scenario == "interrupted")
			if scenario == "incompatible" || scenario == "provider-incompatible" || scenario == "startup-failure" {
				t.Setenv("ASTER_CORE_FIXTURE", scenario)
			}
			dir := t.TempDir()
			a, err := NewApp(dir, core, "")
			if err != nil {
				t.Fatal(err)
			}
			defer a.Close()
			settings := DefaultSettings()
			settings.SystemProxy = false
			settings.MixedPort = unusedPort()
			a.Store.State.Settings = settings
			a.Store.State.ActiveID = "fixture"
			a.Store.State.Profiles = []Profile{{ID: "fixture", Content: "proxies: []\nrules:\n - MATCH,DIRECT\n"}}
			if err = a.Core.Start(context.Background(), a.Store.State.Profiles[0].Content, settings, false); err != nil {
				t.Fatal(err)
			}
			before := a.Core.Status().PID
			ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
			defer cancel()
			if _, err = a.UpdateCore(ctx); err == nil {
				t.Fatal("invalid update accepted")
			}
			if !a.Core.Status().Running || a.Core.Binary != core {
				t.Fatalf("previous core not restored: %v", err)
			}
			if scenario != "startup-failure" && a.Core.Status().PID != before {
				t.Fatal("preflight failure restarted working core")
			}
			if _, err = a.Core.Request(ctx, "GET", "/version", nil); err != nil {
				t.Fatalf("old API not usable: %v", err)
			}
			if _, err = os.Stat(filepath.Join(dir, "cores", "selection.json")); !os.IsNotExist(err) {
				t.Fatal("failed candidate became selected")
			}
		})
	}
}

func TestVerifiedUpdateAndDeferredStartupRollback(t *testing.T) {
	core := os.Getenv("ASTER_TEST_CORE")
	if core == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	for _, deferredFailure := range []bool{false, true} {
		t.Run(fmt.Sprint(deferredFailure), func(t *testing.T) {
			candidatePath := core
			if deferredFailure {
				candidatePath, _ = os.Executable()
				t.Setenv("ASTER_CORE_FIXTURE", "startup-failure")
			}
			candidate, err := os.ReadFile(candidatePath)
			if err != nil {
				t.Fatal(err)
			}
			mockUpdate(t, candidate, false, false)
			a, err := NewApp(t.TempDir(), core, "")
			if err != nil {
				t.Fatal(err)
			}
			defer a.Close()
			s := DefaultSettings()
			s.SystemProxy = false
			s.MixedPort = unusedPort()
			a.Store.State.Settings = s
			content := "proxies: []\nrules:\n - MATCH,DIRECT\n"
			a.Store.State.ActiveID = "fixture"
			a.Store.State.Profiles = []Profile{{ID: "fixture", Content: content}}
			if !deferredFailure {
				if err = a.Core.Start(context.Background(), content, s, false); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
			defer cancel()
			if _, err = a.UpdateCore(ctx); err != nil {
				t.Fatal(err)
			}
			if a.Core.Binary == core {
				t.Fatal("verified candidate not selected")
			}
			if deferredFailure {
				if err = a.Core.Start(ctx, content, s, false); err != nil {
					t.Fatal(err)
				}
				if a.Core.Binary != core {
					t.Fatal("next-start failure did not restore bundled core")
				}
			}
			if !a.Core.Status().Running {
				t.Fatal("no working core after update/start")
			}
			if _, err = a.Core.Request(ctx, "GET", "/version", nil); err != nil {
				t.Fatal(err)
			}
		})
	}
}
