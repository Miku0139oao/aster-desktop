package desktop

import (
	"reflect"
	"testing"
)

func TestNormalizeTunPackages(t *testing.T) {
	include, exclude := NormalizeTunPackages(
		[]string{"com.example.app", "com.example.app", " org.test ", "bad package", "evil\npackage", ""},
		[]string{"org.test", "org.test", "com.bad;id"},
	)
	if want := []string{"com.example.app"}; !reflect.DeepEqual(include, want) {
		t.Fatalf("include = %#v, want %#v", include, want)
	}
	if want := []string{"org.test"}; !reflect.DeepEqual(exclude, want) {
		t.Fatalf("exclude = %#v, want %#v", exclude, want)
	}
}

func TestNormalizeTunPackagesLimitsCount(t *testing.T) {
	values := make([]string, maxTunPackages+10)
	for index := range values {
		values[index] = "com.example.app" + string(rune('a'+index%26)) + string(rune('a'+index/26))
	}
	include, _ := NormalizeTunPackages(values, nil)
	if len(include) > maxTunPackages {
		t.Fatalf("kept %d packages, limit is %d", len(include), maxTunPackages)
	}
}

func TestApplyMobileTunOptions(t *testing.T) {
	tun := map[string]any{
		"enable":                true,
		"auto-route":            true,
		"file-descriptor":       3,
		"include-package":       []any{"stale.example"},
		"exclude-package":       []any{"stale.example"},
		"auto-detect-interface": true,
		"mtu":                   9000,
	}
	applyMobileTunOptions(tun, 42, []string{"com.example.app"}, []string{"org.test"})
	if tun["auto-route"] != false {
		t.Fatalf("auto-route = %#v", tun["auto-route"])
	}
	if tun["auto-detect-interface"] != false {
		t.Fatalf("auto-detect-interface = %#v", tun["auto-detect-interface"])
	}
	if tun["file-descriptor"] != 42 {
		t.Fatalf("file-descriptor = %#v", tun["file-descriptor"])
	}
	if want := []any{"com.example.app"}; !reflect.DeepEqual(tun["include-package"], want) {
		t.Fatalf("include-package = %#v, want %#v", tun["include-package"], want)
	}
	if want := []any{"org.test"}; !reflect.DeepEqual(tun["exclude-package"], want) {
		t.Fatalf("exclude-package = %#v, want %#v", tun["exclude-package"], want)
	}
	if tun["mtu"] != 9000 {
		t.Fatalf("unrelated TUN settings were changed")
	}

	applyMobileTunOptions(tun, 0, nil, nil)
	for _, key := range []string{"file-descriptor", "include-package", "exclude-package"} {
		if _, exists := tun[key]; exists {
			t.Fatalf("%s should be removed when empty", key)
		}
	}
}

func TestCoreTunPackages(t *testing.T) {
	core := NewCore("", t.TempDir())
	core.SetTunPackages(
		[]string{"com.example.app", "com.example.app", "bad name"},
		[]string{"org.test"},
	)
	include, exclude := core.tunPackages()
	if want := []string{"com.example.app"}; !reflect.DeepEqual(include, want) {
		t.Fatalf("include = %#v, want %#v", include, want)
	}
	if want := []string{"org.test"}; !reflect.DeepEqual(exclude, want) {
		t.Fatalf("exclude = %#v, want %#v", exclude, want)
	}
}

func TestWithSystemDNSReplacesDefaultResolver(t *testing.T) {
	doc := map[string]any{
		"dns": map[string]any{"enable": true, "nameserver": []any{"system"}},
	}
	withSystemDNS(doc, []string{"192.168.1.1", "fd00::1"})
	nameserver := doc["dns"].(map[string]any)["nameserver"]
	if want := []any{"192.168.1.1", "fd00::1"}; !reflect.DeepEqual(nameserver, want) {
		t.Fatalf("nameserver = %#v, want %#v", nameserver, want)
	}
}

func TestWithSystemDNSKeepsExplicitProfileDNS(t *testing.T) {
	cases := map[string][]any{
		"custom": {"1.1.1.1", "8.8.8.8"},
		"mixed":  {"system", "1.1.1.1"},
		"empty":  {},
	}
	for name, nameserver := range cases {
		doc := map[string]any{"dns": map[string]any{"enable": true, "nameserver": nameserver}}
		withSystemDNS(doc, []string{"192.168.1.1"})
		if got := doc["dns"].(map[string]any)["nameserver"]; !reflect.DeepEqual(got, nameserver) {
			t.Fatalf("%s: nameserver = %#v, want %#v", name, got, nameserver)
		}
	}
}

func TestWithSystemDNSIgnoresMissingDNS(t *testing.T) {
	doc := map[string]any{"proxies": []any{}}
	withSystemDNS(doc, []string{"192.168.1.1"})
	if _, exists := doc["dns"]; exists {
		t.Fatalf("withSystemDNS must not create a dns section")
	}
	withSystemDNS(map[string]any{"dns": map[string]any{"nameserver": []any{"system"}}}, nil)
}

func TestNormalizeDNSAddresses(t *testing.T) {
	got := normalizeDNSAddresses([]string{
		"192.168.1.1", " 192.168.1.1 ", "fe80::1", "0.0.0.0", "224.0.0.1",
		"not-an-address", "1.1.1.1", "8.8.8.8", "9.9.9.9", "2606:4700::1111",
	})
	if want := []string{"192.168.1.1", "fe80::1", "1.1.1.1", "8.8.8.8"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("addresses = %#v, want %#v", got, want)
	}
}
