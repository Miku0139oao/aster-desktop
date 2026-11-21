//go:build !windows

package desktop

import (
	"errors"

	"golang.org/x/sys/unix"
)

// closeIfOpen closes fd unless it is already closed. A VPN hand-off detaches
// the descriptor, so a start that never reaches a running core has to release
// it; but the core's TUN listener owns and closes the same descriptor once it
// is built, and a later parse failure must not close a reused number.
func closeIfOpen(fd int) error {
	if _, err := unix.FcntlInt(uintptr(fd), unix.F_GETFD, 0); err != nil {
		if errors.Is(err, unix.EBADF) {
			return nil
		}
		return err
	}
	return unix.Close(fd)
}
