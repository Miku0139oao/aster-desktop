package desktop

import "testing"

func TestProxyRestorePreservesExternalChanges(t *testing.T) {
	snapshot := ProxyTarget{Before: map[string]string{"mode": "none", "host": "old", "bypass": "old-bypass"}, Installed: map[string]string{"mode": "manual", "host": "127.0.0.1", "bypass": "local"}}
	restored := ownedProxyValues(snapshot, map[string]string{"mode": "manual", "host": "127.0.0.1", "bypass": "external-bypass"}, "mode", []string{"host"})
	if restored["mode"] != "none" || restored["host"] != "old" || restored["bypass"] != "external-bypass" {
		t.Fatalf("wrong restoration: %v", restored)
	}
	restored = ownedProxyValues(snapshot, map[string]string{"mode": "manual", "host": "external-host", "bypass": "local"}, "mode", []string{"host"})
	if restored["mode"] != "manual" || restored["host"] != "external-host" || restored["bypass"] != "old-bypass" {
		t.Fatalf("external proxy overwritten: %v", restored)
	}
}
