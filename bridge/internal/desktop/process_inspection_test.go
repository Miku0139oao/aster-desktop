package desktop

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// A real socket from this independent client must be attributed to this test
// executable, never the core. No global proxy, service or TUN changes are made.
func TestRealCoreConnectionProcessInspection(t *testing.T) {
	binary := os.Getenv("ASTER_TEST_CORE")
	if binary == "" {
		t.Skip("requires ASTER_TEST_CORE")
	}
	executable := currentApplicationExecutable(t)
	for _, mode := range []string{"rule", "global", "direct"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
			defer cancel()
			core := NewCore(binary, t.TempDir())
			settings := DefaultSettings()
			settings.Mode, settings.SystemProxy, settings.MixedPort = mode, false, unusedPort()
			if err := core.Start(ctx, "find-process-mode: off\nproxies: []\nrules: ['MATCH,DIRECT']\n", settings, false); err != nil {
				t.Fatal(err)
			}
			defer core.Stop()
			release := make(chan struct{})
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				select {
				case <-release:
				case <-r.Context().Done():
				}
			}))
			defer upstream.Close()
			defer close(release)
			proxy, _ := url.Parse("http://127.0.0.1:" + strconv.Itoa(settings.MixedPort))
			transport := &http.Transport{Proxy: http.ProxyURL(proxy)}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: 25 * time.Second}
			go func() {
				request, _ := http.NewRequestWithContext(ctx, "GET", upstream.URL, nil)
				response, _ := client.Do(request)
				if response != nil {
					response.Body.Close()
				}
			}()
			deadline := time.Now().Add(10 * time.Second)
			var last []byte
			for time.Now().Before(deadline) {
				body, err := core.Request(ctx, "GET", "/connections", nil)
				if err != nil {
					t.Fatal(err)
				}
				last = body
				var result struct {
					Connections []struct {
						Metadata struct {
							Process string `json:"process"`
							Path    string `json:"processPath"`
						} `json:"metadata"`
					} `json:"connections"`
				}
				if err := json.Unmarshal(body, &result); err != nil {
					t.Fatal(err)
				}
				for _, connection := range result.Connections {
					if strings.EqualFold(connection.Metadata.Path, executable) && strings.EqualFold(connection.Metadata.Process, filepath.Base(executable)) {
						return
					}
				}
				time.Sleep(50 * time.Millisecond)
			}
			t.Fatalf("client executable not identified: %s", last)
		})
	}
}
