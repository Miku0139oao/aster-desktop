//go:build !windows

package desktop

import (
	"context"
	"testing"

	"golang.org/x/sys/unix"
)

func TestStartWithFDReleasesAFailedDescriptor(t *testing.T) {
	// The VPN hands the core the only handle to this descriptor, so a start
	// that never reaches a running core must release it itself.
	fd, err := unix.Open("/dev/null", unix.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	core := NewCore("", t.TempDir())
	core.InProcess = true
	if err := core.StartWithFD(context.Background(), "not: [valid", DefaultSettings(), fd); err == nil {
		t.Fatal("expected the invalid configuration to fail")
	}
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err == nil {
		t.Fatal("a failed start left the TUN descriptor open")
	}
}
