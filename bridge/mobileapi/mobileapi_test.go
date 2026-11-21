package mobileapi

import (
	"strings"
	"testing"
)

// A closed host must reject further work instead of reaching a nil App, and a
// close must be safe to repeat.
func TestHostCloseRejectsLaterCalls(t *testing.T) {
	dir := t.TempDir()
	host, err := NewHost(dir)
	if err != nil {
		t.Fatalf("NewHost: %v", err)
	}
	if _, err := host.Call(`{"id":1,"method":"state"}`); err != nil {
		t.Fatalf("Call before close: %v", err)
	}
	if err := host.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := host.Close(); err != nil {
		t.Fatalf("second Close: %v", err)
	}
	if _, err := host.Call(`{"id":2,"method":"state"}`); err == nil ||
		!strings.Contains(err.Error(), "not ready") {
		t.Fatalf("Call after close = %v, want a not-ready error", err)
	}
	if _, err := host.StartVPN(3, `{}`); err == nil {
		t.Fatalf("StartVPN after close must fail")
	}
}

func TestHostNilIsSafe(t *testing.T) {
	var host *Host
	if err := host.Close(); err != nil {
		t.Fatalf("nil Close: %v", err)
	}
	if _, err := host.Call(`{}`); err == nil {
		t.Fatalf("nil Call must fail")
	}
	if err := host.SetSystemDNS("1.1.1.1"); err == nil {
		t.Fatalf("nil SetSystemDNS must fail")
	}
}
