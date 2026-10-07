package desktop

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestTunOutboundNetworkRuntime(t *testing.T) {
	for _, test := range []struct {
		name, selected, original, want string
		tun, auto                      bool
	}{
		{"wifi-overrides-profile", "Wi-Fi", "Unusable Ethernet", "Wi-Fi", true, false},
		{"unicode-interface", "無線網路", "", "無線網路", true, false},
		{"automatic", "", "", "", true, true},
		{"automatic-preserves-yaml", "", "Custom uplink", "Custom uplink", true, true},
		{"system-proxy-not-bound", "Wi-Fi", "", "", false, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := DefaultSettings()
			s.Tun, s.TunInterface = test.tun, test.selected
			input := "proxies: []\nrules: [MATCH,DIRECT]\ndns: {enable: true, nameserver: [system]}\n"
			if test.original != "" {
				input += "interface-name: " + test.original + "\n"
			}
			output, err := Runtime(input, s, "127.0.0.1:0", "secret", t.TempDir(), true)
			if err != nil {
				t.Fatal(err)
			}
			var doc map[string]any
			if err = yaml.Unmarshal(output, &doc); err != nil {
				t.Fatal(err)
			}
			selected, _ := doc["interface-name"].(string)
			tun := doc["tun"].(map[string]any)
			if selected != test.want || tun["auto-detect-interface"] != test.auto || tun["auto-route"] != true {
				t.Fatalf("wrong outbound binding: interface=%q tun=%v", selected, tun)
			}
			if doc["dns"].(map[string]any)["nameserver"].([]any)[0] != "system" {
				t.Fatal("DNS configuration changed")
			}
			if binary := os.Getenv("ASTER_TEST_CORE"); binary != "" {
				core := NewCore(binary, t.TempDir())
				if _, err = core.Validate(context.Background(), input, s, true); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestTunOutboundNetworkUnavailable(t *testing.T) {
	if err := validateTunInterface("Aster-missing-uplink-243718"); err == nil || !strings.Contains(err.Error(), "choose another network") {
		t.Fatalf("missing network: %v", err)
	}
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagLoopback != 0 {
			if err := validateTunInterface(iface.Name); err == nil {
				t.Fatal("loopback selected as TUN uplink")
			}
		}
	}
	for _, name := range []string{"bad\nname", "bad\x00name", strings.Repeat("a", 257)} {
		s := DefaultSettings()
		s.TunInterface = name
		if s.Validate() == nil {
			t.Fatal("invalid interface accepted")
		}
	}
}

func TestTunNetworkChangeRequiresDisconnectAndPersists(t *testing.T) {
	t.Setenv("ASTER_CORE_FIXTURE", "healthy")
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	app, err := NewApp(t.TempDir(), binary, "")
	if err != nil {
		t.Fatal(err)
	}
	defer app.Close()
	s := DefaultSettings()
	s.SystemProxy = false
	s.MixedPort = unusedPort()
	app.Store.State.Settings = s
	if err = app.Core.Start(context.Background(), "proxies: []\nrules: [MATCH,DIRECT]\n", s, false); err != nil {
		t.Fatal(err)
	}
	s.TunInterface = "Wi-Fi"
	params, _ := json.Marshal(s)
	if _, err = app.Dispatch(context.Background(), Request{Method: "settings", Params: params}); err == nil || !strings.Contains(err.Error(), "disconnect") {
		t.Fatalf("running change: %v", err)
	}
	if app.Store.State.Settings.TunInterface != "" {
		t.Fatal("failed operation changed saved selection")
	}
	if err = app.Core.Stop(); err != nil {
		t.Fatal(err)
	}
	if _, err = app.Dispatch(context.Background(), Request{Method: "settings", Params: params}); err != nil {
		t.Fatal(err)
	}
	stored, err := OpenStore(app.Store.Dir)
	if err != nil || stored.State.Settings.TunInterface != "Wi-Fi" {
		t.Fatalf("selection did not persist: %v", err)
	}
}
