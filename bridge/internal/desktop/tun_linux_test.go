package desktop

import (
	"bytes"
	"context"
	"net"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// Run only inside a disposable Linux network namespace (see TESTING.md).
func TestRealTunDNSAndCleanup(t *testing.T) {
	if os.Getenv("ASTER_TEST_TUN") != "isolated-netns" {
		t.Skip("requires an isolated network namespace")
	}
	core := os.Getenv("ASTER_TEST_CORE")
	if core == "" {
		t.Fatal("ASTER_TEST_CORE is required")
	}
	before, err := exec.Command("ip", "-j", "route", "show", "table", "all").Output()
	if err != nil {
		t.Fatal(err)
	}
	c := NewCore(core, t.TempDir())
	defer c.Stop()
	settings := DefaultSettings()
	settings.Tun = true
	settings.SystemProxy = false
	settings.MixedPort = unusedPort()
	content := "proxies: []\nrules:\n - MATCH,DIRECT\ndns:\n enable: true\n enhanced-mode: fake-ip\n nameserver: [1.1.1.1]\ntun:\n device: AsterTest\n stack: gvisor\n"
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err = c.Start(ctx, content, settings, true); err != nil {
		t.Fatal(err)
	}
	if _, err = net.InterfaceByName("AsterTest"); err != nil {
		t.Fatalf("TUN interface missing: %v", err)
	}
	// This destination is unreachable on the dummy default route. A successful
	// fake-IP response therefore exercises the core's TUN DNS interception.
	conn, err := net.Dial("udp", "1.1.1.1:53")
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
	packet := []byte{0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 10, 'a', 's', 't', 'e', 'r', '-', 't', 'e', 's', 't', 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0, 0, 1, 0, 1}
	if _, err = conn.Write(packet); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 1500)
	n, err := conn.Read(reply)
	if err != nil {
		t.Fatalf("TUN DNS interception failed: %v\n%v", err, c.Logs())
	}
	if n < 16 || reply[0] != 0x12 || reply[1] != 0x34 || reply[3]&15 != 0 || reply[7] == 0 {
		t.Fatalf("invalid DNS reply: %x", reply[:n])
	}
	if err = c.Stop(); err != nil {
		t.Fatal(err)
	}
	if _, err = net.InterfaceByName("AsterTest"); err == nil {
		t.Fatal("TUN interface remained after shutdown")
	}
	after, err := exec.Command("ip", "-j", "route", "show", "table", "all").Output()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, after) {
		t.Fatalf("routes not restored\nbefore:%s\nafter:%s", before, after)
	}
}

func TestRealPrivilegedServicePeerAndCleanup(t *testing.T) {
	if os.Getenv("ASTER_TEST_TUN") != "isolated-netns" {
		t.Skip("requires a private mount/network namespace")
	}
	bridge := exec.Command("/usr/lib/aster-desktop/aster-bridge", "--service")
	if err := bridge.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = bridge.Process.Signal(syscall.SIGTERM); _ = bridge.Wait() }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(linuxSocket); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("service socket not created")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := os.Chmod(linuxSocket, 0666); err != nil {
		t.Fatal(err)
	}
	binary, _ := os.Executable()
	probe := func(uid, mode string) {
		t.Helper()
		command := exec.Command("setpriv", "--reuid", uid, "--regid", uid, "--clear-groups", binary)
		command.Env = append(os.Environ(), "ASTER_SERVICE_PROBE="+mode)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("%s probe: %s %v", mode, output, err)
		}
	}
	probe("1001", "unauthorized")
	if err := os.Chmod(linuxSocket, 0600); err != nil {
		t.Fatal(err)
	}
	probe("1000", "authorized")
	deadline = time.Now().Add(15 * time.Second)
	for {
		if _, err := net.InterfaceByName("AsterSvcTest"); err != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("service left TUN after client EOF")
		}
		time.Sleep(50 * time.Millisecond)
	}
}
