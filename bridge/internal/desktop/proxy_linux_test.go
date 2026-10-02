package desktop

import (
	"os"
	"testing"
)

func TestIsolatedGnomeProxyRestoration(t *testing.T) {
	if os.Getenv("ASTER_TEST_GNOME") != "isolated-dbus" {
		t.Skip("requires isolated D-Bus and XDG_CONFIG_HOME")
	}
	t.Setenv("XDG_CURRENT_DESKTOP", "GNOME")
	initial, err := CaptureProxy(17891)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = writeLinuxProxy("gnome", initial.Targets[0].Before) }()
	if err = SetProxy(initial); err != nil {
		t.Fatal(err)
	}
	current, err := CaptureProxy(17891)
	if err != nil {
		t.Fatal(err)
	}
	if current.Targets[0].Before["org.gnome.system.proxy/mode"] != "'manual'" {
		t.Fatal("GNOME mode not set")
	}
	if err = RestoreProxy(initial); err != nil {
		t.Fatal(err)
	}
	restored, err := CaptureProxy(17891)
	if err != nil {
		t.Fatal(err)
	}
	for key, before := range initial.Targets[0].Before {
		if restored.Targets[0].Before[key] != before {
			t.Fatalf("not restored: %s", key)
		}
	}
	if err = SetProxy(initial); err != nil {
		t.Fatal(err)
	}
	if _, err = command("gsettings", "set", "org.gnome.system.proxy.https", "host", "'external.example'"); err != nil {
		t.Fatal(err)
	}
	if err = RestoreProxy(initial); err != nil {
		t.Fatal(err)
	}
	preserved, err := CaptureProxy(17891)
	if err != nil {
		t.Fatal(err)
	}
	if preserved.Targets[0].Before["org.gnome.system.proxy.https/host"] != "'external.example'" || preserved.Targets[0].Before["org.gnome.system.proxy.https/port"] != "17891" {
		t.Fatal("external proxy endpoint was changed")
	}
}
