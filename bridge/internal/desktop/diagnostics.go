package desktop

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"time"
)

type DiagnosticCheck struct {
	Kind         string `json:"kind"`
	Status       string `json:"status"`
	Detail       string `json:"detail"`
	Milliseconds int64  `json:"milliseconds"`
}

// Tests use fixed destinations and never change routes, proxy settings, or
// service state. A successful mixed-port test does not prove TUN routing works.
func (a *App) Diagnose(ctx context.Context, external *CoreStatus, externalService map[string]any) []DiagnosticCheck {
	a.mu.Lock()
	s := a.Store.State.Settings
	status := a.status()
	a.mu.Unlock()
	if external != nil {
		status = *external
	}
	checks := []DiagnosticCheck{}
	add := func(kind, state, detail string, elapsed time.Duration) {
		checks = append(checks, DiagnosticCheck{kind, state, detail, elapsed.Milliseconds()})
	}
	if status.Running {
		add("core", "pass", status.Version, 0)
	} else {
		add("core", "fail", "Connect before testing the proxy. "+status.Error, 0)
	}
	service := ServiceStatus()
	if externalService != nil {
		service = externalService
	}
	if !s.Tun {
		add("service", "skip", "Background service is only required for all-applications mode.", 0)
	} else if service["installed"] == true {
		add("service", "pass", "Background service is installed; authorization and routing are tested separately.", 0)
	} else {
		add("service", "fail", "Install and approve the background service in Settings.", 0)
	}
	interfaces, err := ListNetworkInterfaces()
	if err != nil {
		add("network", "fail", err.Error(), 0)
	} else {
		found := s.TunInterface == ""
		names := []string{}
		for _, iface := range interfaces {
			names = append(names, iface.Name)
			if iface.Name == s.TunInterface {
				found = true
			}
		}
		if found {
			add("network", "pass", fmt.Sprintf("Available: %v; selected: %q (empty = system routes)", names, s.TunInterface), 0)
		} else {
			add("network", "fail", "Selected outbound interface is unavailable; select a connected network on Home.", 0)
		}
	}
	start := time.Now()
	dnsCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	addresses, err := net.DefaultResolver.LookupHost(dnsCtx, "www.gstatic.com")
	cancel()
	if err != nil {
		add("dns", "fail", err.Error(), time.Since(start))
	} else {
		add("dns", "pass", fmt.Sprintf("System resolver returned %d addresses.", len(addresses)), time.Since(start))
	}
	for _, test := range []struct {
		kind  string
		proxy bool
	}{{"systemRequest", false}, {"proxyRequest", true}} {
		if test.proxy && !status.Running {
			add(test.kind, "skip", "Connect first.", 0)
			continue
		}
		start = time.Now()
		transport := &http.Transport{Proxy: nil}
		if test.proxy {
			proxy, _ := url.Parse(fmt.Sprintf("http://127.0.0.1:%d", s.MixedPort))
			transport.Proxy = http.ProxyURL(proxy)
		}
		client := &http.Client{Transport: transport, Timeout: 8 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
		request, _ := http.NewRequestWithContext(ctx, "GET", "https://www.gstatic.com/generate_204", nil)
		response, err := client.Do(request)
		transport.CloseIdleConnections()
		if err != nil {
			add(test.kind, "fail", err.Error(), time.Since(start))
		} else {
			response.Body.Close()
			state := "pass"
			if response.StatusCode != 204 {
				state = "fail"
			}
			add(test.kind, state, fmt.Sprintf("HTTPS response %d", response.StatusCode), time.Since(start))
		}
	}
	return checks
}
