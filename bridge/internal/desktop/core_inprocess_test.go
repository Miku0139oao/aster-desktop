package desktop

import (
	"context"
	"net"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestInProcessStopReleasesProxyAndController(t *testing.T) {
	if os.Getenv("ASTER_INPROCESS_STOP_HELPER") != "1" {
		command := exec.Command(
			os.Args[0],
			"-test.run=^TestInProcessStopReleasesProxyAndController$",
			"-test.v",
		)
		command.Env = append(os.Environ(), "ASTER_INPROCESS_STOP_HELPER=1")
		output, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("isolated embedded-core lifecycle failed: %v\n%s", err, output)
		}
		return
	}
	dir, err := os.MkdirTemp("", "aster-inprocess-stop-*")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	core := NewCore("", dir)
	core.InProcess = true
	settings := DefaultSettings()
	settings.SystemProxy = false
	settings.Tun = false
	settings.MixedPort = unusedPort()
	content := "proxies: []\nrules: ['MATCH,DIRECT']\n"

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err = core.Start(ctx, content, settings, false); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = core.Stop() })
	controller := core.Address
	if err := checkPortAvailable(settings.MixedPort); err == nil {
		t.Fatal("mixed proxy did not bind while running")
	}
	connection, err := net.DialTimeout("tcp", controller, time.Second)
	if err != nil {
		t.Fatalf("controller did not bind while running: %v", err)
	}
	_ = connection.Close()

	if err = core.Stop(); err != nil {
		t.Fatalf("stop embedded core: %v", err)
	}
	if err = checkPortAvailable(settings.MixedPort); err != nil {
		t.Fatalf("proxy listener survived embedded core stop: %v", err)
	}
	if connection, err = net.DialTimeout("tcp", controller, 200*time.Millisecond); err == nil {
		_ = connection.Close()
		t.Fatalf("controller %s survived embedded core stop", controller)
	}

	// Reusing the same port immediately reproduces the notification-disconnect
	// path that previously reported "port 7890 is in use".
	if err = core.Start(ctx, content, settings, false); err != nil {
		t.Fatalf("reconnect after embedded core stop failed: %v", err)
	}
	if !core.Status().Running {
		t.Fatal("core did not report running after reconnect")
	}
	if err = core.Stop(); err != nil {
		t.Fatal(err)
	}
	if err = checkPortAvailable(settings.MixedPort); err != nil {
		t.Fatalf("proxy listener survived second stop: %v", err)
	}
}
