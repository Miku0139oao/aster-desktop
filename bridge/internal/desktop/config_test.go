package desktop

import (
	"context"
	"encoding/base64"
	"gopkg.in/yaml.v3"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNodeOnlyYAMLGeneratesUsableProfile(t *testing.T) {
	cases := []struct {
		name, content string
		nodes         int
	}{
		{"nodes", "proxies: [{name: Proxy, type: direct}, {name: Proxy, type: direct}]\ndns: {enable: true, nameserver: [1.1.1.1]}\n", 2},
		{"inline-provider", "proxy-providers: {Local: {type: inline, payload: [{name: Auto, type: direct}]}}\n", 1},
		{"http-provider", "proxy-providers: {Remote: {type: http, url: 'https://example.com/nodes.yaml', interval: 3600}}\n", 0},
	}
	for _, fixture := range cases {
		t.Run(fixture.name, func(t *testing.T) {
			result, err := Import([]byte(fixture.content))
			if err != nil || result.Nodes != fixture.nodes {
				t.Fatalf("import: %v, nodes: %d", err, result.Nodes)
			}
			var doc map[string]any
			if err = yaml.Unmarshal([]byte(result.Content), &doc); err != nil {
				t.Fatal(err)
			}
			groups := doc["proxy-groups"].([]any)
			if len(groups) != 2 || groups[0].(map[string]any)["name"] != "Proxy" || doc["rules"].([]any)[4] != "MATCH,Proxy" {
				t.Fatal("missing basic groups or routing")
			}
			if fixture.name == "nodes" {
				nodes := doc["proxies"].([]any)
				if nodes[0].(map[string]any)["name"] != "Proxy (2)" || nodes[1].(map[string]any)["name"] != "Proxy (3)" || doc["dns"].(map[string]any)["nameserver"].([]any)[0] != "1.1.1.1" {
					t.Fatal("duplicate names or original DNS lost")
				}
			} else if len(groups[0].(map[string]any)["use"].([]any)) != 1 {
				t.Fatal("provider subscription is not connected to the group")
			}
			if binary := os.Getenv("ASTER_TEST_CORE"); binary != "" {
				core := NewCore(binary, t.TempDir())
				if _, err = core.Validate(context.Background(), result.Content, DefaultSettings(), false); err != nil {
					t.Fatal(err)
				}
			}
		})
	}
}

func TestNodeOnlyLocalProviderImportedBeforeGroupGeneration(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "nodes.yaml"), []byte("proxies: [{name: Auto, type: direct}]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	input := "proxy-providers: {Local: {type: file, path: nodes.yaml}}\n"
	result, err := Import([]byte(input), filepath.Join(dir, "profile.yaml"))
	if err != nil || result.Nodes != 1 || !strings.Contains(result.Content, "Auto (2)") || !strings.Contains(result.Content, "type: inline") {
		t.Fatalf("local provider import: %v, %s", err, result.Content)
	}
	if _, err = Import([]byte(input), ""); err == nil {
		t.Fatal("pasted file provider accepted without a source file")
	}
}

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

func TestTUNSubscriptionTransportPathsAndAnchors(t *testing.T) {
	input := `provider-template: &provider
  type: http
  path: ./subscription-cache.yaml
  interval: 3600
node-template: &node
  type: vmess
  server: example.com
  port: 443
  uuid: 00000000-0000-4000-8000-000000000001
  alterId: 0
  cipher: auto
proxies:
  - {<<: *node, name: WS, network: ws, ws-opts: {path: /ws}}
  - {<<: *node, name: HTTP, network: http, http-opts: {path: [/connect]}}
  - {<<: *node, name: H2, network: h2, h2-opts: {path: /h2}}
proxy-providers:
  Remote: {<<: *provider, url: 'https://example.com/nodes.yaml'}
  Inline:
    type: inline
    payload:
      - {<<: *node, name: ProviderWS, network: ws, ws-opts: {path: /provider}}
dns:
  enable: true
  nameserver: [system]
  fallback-filter: {geoip: true, geosite: [gfw]}
rules: ['MATCH,DIRECT']
`
	s := DefaultSettings()
	s.Tun = true
	dir := t.TempDir()
	b, err := Runtime(input, s, "127.0.0.1:9000", "managed", dir, true)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err = yaml.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	nodes := doc["proxies"].([]any)
	if nodes[0].(map[string]any)["ws-opts"].(map[string]any)["path"] != "/ws" || doc["dns"].(map[string]any)["fallback-filter"].(map[string]any)["geosite"].([]any)[0] != "gfw" {
		t.Fatal("transport or DNS settings changed")
	}
	providers := doc["proxy-providers"].(map[string]any)
	if !strings.HasPrefix(providers["Remote"].(map[string]any)["path"].(string), filepath.Join(dir, "providers")) {
		t.Fatal("provider cache escaped the managed directory")
	}
	// Exercise the real core's configuration parser without enabling TUN or
	// fetching remote providers/geodata, including paths copied into a provider.
	if binary := os.Getenv("ASTER_TEST_CORE"); binary != "" {
		delete(doc, "dns")
		delete(providers, "Remote")
		content, _ := yaml.Marshal(doc)
		if _, err = NewCore(binary, dir).Validate(context.Background(), string(content), s, true); err != nil {
			t.Fatal(err)
		}
	}
}

func TestTUNRejectsActualFileResources(t *testing.T) {
	for _, fragment := range []string{
		"tls: {certificate: /etc/shadow}",
		"tls: {custom-certifactes: [/etc/shadow]}",
		"proxy-providers: {P: {type: inline, payload: [{name: bad, type: socks5, certificate: /etc/shadow}]}}",
		"proxy-providers: {private-key: {type: inline, payload: [{name: bad, type: ssh, private-key: /etc/shadow}]}}",
		"proxies: [{name: bad, type: tailscale, state-dir: /etc}]",
		"geox-url: {mmdb: 'file:///etc/shadow'}",
		"geox-url: {asn: /etc/shadow}",
		"traffic-control: {store: /etc/shadow}",
	} {
		t.Run(fragment, func(t *testing.T) {
			if _, err := Runtime(fragment, DefaultSettings(), "127.0.0.1:0", "managed", t.TempDir(), true); err == nil {
				t.Fatal("local privileged resource accepted")
			}
		})
	}
}

func TestTUNInlineProtocolKeys(t *testing.T) {
	for _, protocol := range []string{"wireguard", "masque"} {
		if _, err := Runtime("proxies: [{name: inline, type: "+protocol+", private-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=}]", DefaultSettings(), "127.0.0.1:0", "managed", t.TempDir(), true); err != nil {
			t.Fatal(err)
		}
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

func TestApplicationOverridesAndDeletedSubscriptionRules(t *testing.T) {
	const remote = "PROCESS-NAME,browser.exe,Proxy"
	const local = "PROCESS-NAME,browser.exe,DIRECT"
	content := "rules: ['" + remote + "', 'MATCH,DIRECT']\n"
	merged, err := mergeDesktopRules(content, []string{local})
	if err != nil || strings.Contains(merged, remote) || !strings.Contains(merged, local) || !strings.Contains(merged, "MATCH,DIRECT") {
		t.Fatal("duplicate application route after refresh: ", err, merged)
	}
	deleted, err := suppressDesktopRules(content, []string{remote})
	if err != nil || strings.Contains(deleted, remote) || !strings.Contains(deleted, "MATCH,DIRECT") {
		t.Fatal("deleted subscription rule resurrected: ", err, deleted)
	}
	if len(retainedSuppressedRules(content, []string{remote})) != 0 {
		t.Fatal("explicit YAML rule reinsertion remained suppressed")
	}
	if len(retainedSuppressedRules(deleted, []string{remote, remote})) != 1 {
		t.Fatal("rule deletion metadata not retained/deduplicated")
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
