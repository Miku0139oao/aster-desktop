package desktop

import (
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/Miku0139oao/aster-core/adapter"
	"github.com/Miku0139oao/aster-core/common/convert"
	"gopkg.in/yaml.v3"
)

type ImportResult struct {
	Content  string   `json:"content"`
	Warnings []string `json:"warnings"`
	Nodes    int      `json:"nodes"`
}

func Import(data []byte) (ImportResult, error) {
	if len(data) == 0 || len(data) > MaxConfig {
		return ImportResult{}, errors.New("configuration is empty or too large")
	}
	var doc map[string]any
	if yaml.Unmarshal(data, &doc) == nil && doc != nil && (doc["proxies"] != nil || doc["proxy-providers"] != nil || doc["rules"] != nil) {
		if _, err := yaml.Marshal(doc); err != nil {
			return ImportResult{}, err
		}
		n := 0
		if p, ok := doc["proxies"].([]any); ok {
			n = len(p)
		}
		return ImportResult{Content: string(data), Warnings: []string{}, Nodes: n}, nil
	}
	lines := strings.Split(string(convert.DecodeBase64(data)), "\n")
	var nodes []map[string]any
	warnings := []string{}
	names := map[string]bool{"Auto": true, "Proxy": true, "GLOBAL": true, "DIRECT": true, "REJECT": true, "REJECT-DROP": true, "PASS": true, "COMPATIBLE": true}
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		converted, err := convert.ConvertsV2Ray([]byte(line))
		if err != nil || len(converted) == 0 {
			warnings = append(warnings, fmt.Sprintf("Line %d: invalid or unsupported node link", i+1))
			continue
		}
		for _, p := range converted {
			name, _ := p["name"].(string)
			if name == "" {
				name = fmt.Sprintf("Node %d", len(nodes)+1)
			}
			base := name
			for suffix := 2; names[name]; suffix++ {
				name = fmt.Sprintf("%s (%d)", base, suffix)
			}
			p["name"] = name
			proxy, err := adapter.ParseProxy(p)
			if err != nil {
				warnings = append(warnings, fmt.Sprintf("Line %d: %s", i+1, bounded(err.Error(), 300)))
				continue
			}
			_ = proxy.Close()
			names[name] = true
			nodes = append(nodes, p)
		}
	}
	if len(nodes) == 0 {
		return ImportResult{}, errors.New("no usable nodes found; import Clash YAML or supported node links")
	}
	nodeNames := []string{}
	for _, n := range nodes {
		nodeNames = append(nodeNames, n["name"].(string))
	}
	choices := append([]string{"Auto"}, nodeNames...)
	doc = map[string]any{"proxies": nodes, "proxy-groups": []any{map[string]any{"name": "Proxy", "type": "select", "proxies": choices}, map[string]any{"name": "Auto", "type": "url-test", "proxies": nodeNames, "url": "https://www.gstatic.com/generate_204", "interval": 300, "tolerance": 50}}, "dns": map[string]any{"enable": true, "enhanced-mode": "fake-ip", "nameserver": []string{"system"}}, "rules": []string{"IP-CIDR,127.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve", "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve", "MATCH,Proxy"}}
	b, err := yaml.Marshal(doc)
	return ImportResult{Content: string(b), Warnings: warnings, Nodes: len(nodes)}, err
}

// Runtime owns controller and process-related settings. Imported profiles never
// supply a management endpoint or a path from which privileged code executes.
func Runtime(content string, s Settings, controller, secret, dir string, privileged bool) ([]byte, error) {
	if err := s.Validate(); err != nil {
		return nil, err
	}
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(content), &doc); err != nil {
		return nil, err
	}
	if doc == nil {
		return nil, errors.New("configuration must be a YAML mapping")
	}
	for _, k := range []string{"external-controller", "external-controller-tls", "external-controller-unix", "external-controller-pipe", "external-ui", "external-ui-url", "external-ui-name", "external-doh-server", "secret", "authentication", "skip-auth-prefixes", "lan-allowed-ips", "lan-disallowed-ips", "listeners", "port", "socks-port", "redir-port", "tproxy-port", "tunnels", "aster", "profile"} {
		delete(doc, k)
	}
	doc["external-controller"] = controller
	doc["secret"] = secret
	doc["allow-lan"] = s.AllowLAN
	doc["bind-address"] = "*"
	doc["mixed-port"] = s.MixedPort
	doc["mode"] = s.Mode
	doc["external-controller-cors"] = map[string]any{"allow-origins": []any{}, "allow-private-network": false}
	doc["profile"] = map[string]any{"store-selected": true, "store-fake-ip": true}
	tun, _ := doc["tun"].(map[string]any)
	if tun == nil {
		tun = map[string]any{}
	}
	tun["enable"] = s.Tun
	tun["auto-route"] = true
	tun["auto-detect-interface"] = true
	tun["dns-hijack"] = []string{"any:53"}
	if tun["stack"] == nil {
		tun["stack"] = "mixed"
	}
	delete(tun, "file-descriptor")
	doc["tun"] = tun
	for _, key := range []string{"proxy-providers", "rule-providers"} {
		if providers, ok := doc[key].(map[string]any); ok {
			for name, v := range providers {
				if p, ok := v.(map[string]any); ok {
					if p["type"] == "file" {
						return nil, fmt.Errorf("local provider %s must be imported as inline nodes/rules before use", name)
					}
					p["path"] = filepath.Join(dir, "providers", safeName(key+"-"+name)+".yaml")
				}
			}
		}
	}
	if privileged {
		if err := checkPrivilegedResources(doc, ""); err != nil {
			return nil, err
		}
	}
	return yaml.Marshal(doc)
}
func safeName(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteRune('_')
		}
	}
	return b.String()
}
func checkPrivilegedResources(v any, key string) error {
	switch x := v.(type) {
	case map[string]any:
		for k, val := range x {
			if k == "path" && strings.Contains(key, "providers") {
				continue
			}
			if err := checkPrivilegedResources(val, key+"."+k); err != nil {
				return err
			}
		}
	case []any:
		for _, val := range x {
			if err := checkPrivilegedResources(val, key); err != nil {
				return err
			}
		}
	case string:
		last := key[strings.LastIndex(key, ".")+1:]
		if last == "certificate" || last == "private-key" || last == "ca" || last == "client-auth-cert" {
			if x != "" && !strings.Contains(x, "-----BEGIN ") {
				return fmt.Errorf("%s: use inline certificate/key material for TUN", key)
			}
		}
		if last == "path" || last == "file" || last == "mmdb" || last == "geosite" || last == "geoip" {
			if x != "" && !strings.HasPrefix(x, "http://") && !strings.HasPrefix(x, "https://") {
				return fmt.Errorf("%s: local file access is unavailable in TUN mode", key)
			}
		}
	}
	return nil
}
func ValidateURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "https" && u.Scheme != "http") {
		return errors.New("use an HTTP or HTTPS subscription URL")
	}
	return nil
}

func InlineLocalProviders(content, file string) (string, error) {
	var doc map[string]any
	if err := yaml.Unmarshal([]byte(content), &doc); err != nil {
		return "", err
	}
	changed := false
	for _, key := range []string{"proxy-providers", "rule-providers"} {
		providers, _ := doc[key].(map[string]any)
		for name, val := range providers {
			p, ok := val.(map[string]any)
			if !ok || p["type"] != "file" {
				continue
			}
			path, _ := p["path"].(string)
			if file == "" {
				return "", fmt.Errorf("%s uses a local file; import the YAML file instead of pasting its contents", name)
			}
			if !filepath.IsAbs(path) {
				path = filepath.Join(filepath.Dir(file), path)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return "", fmt.Errorf("cannot read local provider %s: %w", name, err)
			}
			if len(data) > MaxConfig {
				return "", errors.New("local provider is too large")
			}
			if key == "rule-providers" && p["format"] == "text" {
				payload := []string{}
				for _, line := range strings.Split(string(data), "\n") {
					line = strings.TrimSpace(line)
					if line != "" && !strings.HasPrefix(line, "#") {
						payload = append(payload, line)
					}
				}
				p["payload"] = payload
				p["format"] = "yaml"
			} else {
				var payload map[string]any
				if err = yaml.Unmarshal(data, &payload); err != nil {
					return "", fmt.Errorf("local provider %s is not YAML/text; use an HTTP provider or inline YAML: %w", name, err)
				}
				if key == "proxy-providers" {
					p["payload"] = payload["proxies"]
				} else {
					p["payload"] = payload["payload"]
				}
			}
			p["type"] = "inline"
			delete(p, "path")
			changed = true
		}
	}
	if !changed {
		return content, nil
	}
	b, err := yaml.Marshal(doc)
	return string(b), err
}
