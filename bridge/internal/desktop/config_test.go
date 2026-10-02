package desktop

import (
	"encoding/base64"
	"gopkg.in/yaml.v3"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestImportProtocolsAndDuplicates(t *testing.T) {
	links := []string{
		"ss://" + base64.RawURLEncoding.EncodeToString([]byte("aes-128-gcm:password")) + "@example.com:443#Same",
		"vmess://" + base64.RawStdEncoding.EncodeToString([]byte(`{"v":"2","ps":"VMess","add":"example.com","port":"443","id":"00000000-0000-4000-8000-000000000001","aid":"0","scy":"auto","net":"tcp","tls":"tls"}`)),
		"vless://00000000-0000-4000-8000-000000000001@example.com:443?security=reality&sni=example.com&pbk=ppQ9FwLrLIa0AOrp1WvcyiaQ37vg2WSy_CD4bIdiTUw&sid=0123456789abcdef#Same",
		"trojan://password@example.com:443?sni=example.com#Trojan",
		"hysteria2://password@example.com:443?sni=example.com#HY2",
		"tuic://00000000-0000-4000-8000-000000000001:password@example.com:443?sni=example.com#TUIC",
		"anytls://password@example.com:443?security=reality&sni=example.com&pbk=ppQ9FwLrLIa0AOrp1WvcyiaQ37vg2WSy_CD4bIdiTUw&sid=0123456789abcdef#AnyTLS",
		"invalid://ignored", "not a node"}
	result, err := Import([]byte(strings.Join(links, "\n")))
	if err != nil {
		t.Fatal(err)
	}
	if result.Nodes != 7 || len(result.Warnings) != 2 {
		t.Fatalf("got %d nodes and %d warnings", result.Nodes, len(result.Warnings))
	}
	var doc map[string]any
	_ = yaml.Unmarshal([]byte(result.Content), &doc)
	names := map[string]bool{}
	for _, value := range doc["proxies"].([]any) {
		node := value.(map[string]any)
		name := node["name"].(string)
		if names[name] {
			t.Fatal("duplicate node name")
		}
		names[name] = true
		if node["type"] == "anytls" {
			if node["reality-opts"] == nil {
				t.Fatal("AnyTLS REALITY lost")
			}
		}
	}
	encoded := base64.StdEncoding.EncodeToString([]byte(strings.Join(links[:7], "\n")))
	again, err := Import([]byte(encoded))
	if err != nil || again.Nodes != 7 {
		t.Fatalf("base64 import: %v", err)
	}
}
func TestClashProfilePreserved(t *testing.T) {
	original := "# custom comment\nproxies: []\ndns:\n  nameserver: [https://dns.example.com/dns-query]\nrules: [MATCH,DIRECT]\n"
	result, err := Import([]byte(original))
	if err != nil || result.Content != original {
		t.Fatalf("profile changed: %v", err)
	}
}
func TestRuntimeManagementIsolation(t *testing.T) {
	input := "proxies: []\nrules: [MATCH,DIRECT]\nexternal-controller: 0.0.0.0:9090\nsecret: stolen\nexternal-ui-url: https://attacker.example\ntun:\n  file-descriptor: 99\n"
	b, err := Runtime(input, DefaultSettings(), "127.0.0.1:9000", "managed-token", t.TempDir(), true)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	_ = yaml.Unmarshal(b, &m)
	if m["secret"] != "managed-token" || m["external-controller"] != "127.0.0.1:9000" || m["external-ui-url"] != nil {
		t.Fatal("profile controls management")
	}
	tun := m["tun"].(map[string]any)
	if tun["file-descriptor"] != nil || tun["enable"] != false {
		t.Fatal("profile controls TUN")
	}
}
func TestPrivilegedFilesRejected(t *testing.T) {
	_, err := Runtime("proxies:\n - name: bad\n   type: socks5\n   server: example.com\n   port: 443\n   certificate: /etc/shadow\nrules: [MATCH,DIRECT]\n", DefaultSettings(), "127.0.0.1:9000", "secret", t.TempDir(), true)
	if err == nil {
		t.Fatal("privileged local file allowed")
	}
}
func TestInlineLocalProviders(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "nodes.yaml"), []byte("proxies:\n - name: local\n   type: socks5\n   server: localhost\n   port: 1080\n"), 0600)
	profile := "proxy-providers:\n  local:\n    type: file\n    path: nodes.yaml\nrules: [MATCH,DIRECT]\n"
	out, err := InlineLocalProviders(profile, filepath.Join(dir, "config.yaml"))
	if err != nil || !strings.Contains(out, "type: inline") {
		t.Fatalf("inline: %v", err)
	}
	if _, err = InlineLocalProviders(profile, ""); err == nil {
		t.Fatal("local file with no source allowed")
	}
}
func TestControllerAllowlist(t *testing.T) {
	for _, path := range []string{"/upgrade", "/restart", "/configs?force=true", "/api/admin/users", "/proxies/../upgrade", "http://attacker.example/proxies", "/proxies/%2e%2e/upgrade"} {
		if allowedController("PUT", path) {
			t.Errorf("allowed %s", path)
		}
	}
	if !allowedController("PUT", "/proxies/Example%20Node") || !allowedController("PATCH", "/rules/disable") {
		t.Fatal("supported operation blocked")
	}
}
func TestSettingsValidation(t *testing.T) {
	s := DefaultSettings()
	s.MixedPort = 80
	if s.Validate() == nil {
		t.Fatal("privileged port allowed")
	}
	s = DefaultSettings()
	s.Mode = "invalid"
	if s.Validate() == nil {
		t.Fatal("invalid mode allowed")
	}
}

func TestSemanticallyInvalidLinksDoNotDiscardGoodNodes(t *testing.T) {
	data := "trojan://good@example.com:443#Auto\nss://" + base64.RawStdEncoding.EncodeToString([]byte("not-a-cipher:password")) + "@example.com:443#bad\n"
	result, err := Import([]byte(data))
	if err != nil {
		t.Fatal(err)
	}
	if result.Nodes != 1 || len(result.Warnings) != 1 || !strings.Contains(result.Content, "Auto (2)") {
		t.Fatalf("bad partial import: %+v", result)
	}
}
