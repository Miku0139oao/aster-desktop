//go:build !windows

package instance

import (
	"errors"
	"golang.org/x/sys/unix"
	"os"
)

func tryLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	// Dart's RandomAccessFile.lock uses fcntl byte-range locks on Unix.
	err = unix.FcntlFlock(f.Fd(), unix.F_SETLK, &unix.Flock_t{Type: unix.F_WRLCK, Whence: 0, Start: 0, Len: 1})
	if err != nil {
		f.Close()
		if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EACCES) {
			return nil, errLeaseBusy
		}
		return nil, err
	}
	return f, nil
}
func replaceEndpoint(from, to string) error { return os.Rename(from, to) }
func grantForeground(pid int)               {}
