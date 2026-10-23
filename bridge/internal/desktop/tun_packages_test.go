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
	}
	applyMobileTunOptions(tun, 42, []string{"com.example.app"}, []string{"org.test"})
	if tun["auto-route"] != false {
		t.Fatalf("auto-route = %#v", tun["auto-route"])
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
	if tun["auto-detect-interface"] != true {
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
