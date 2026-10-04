package desktop

import (
	"context"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

func applicationPaths(ctx context.Context) ([]string, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	// ps supplies identities only. Resolve each executable through the same
	// kernel PROC_PIDPATHINFO interface used by the pinned core, not argv[0].
	output, err := exec.CommandContext(ctx, "/bin/ps", "-ax", "-o", "pid=").Output()
	if err != nil {
		return nil, err
	}
	paths := []string{}
	for _, value := range strings.Fields(string(output)) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		pid, err := strconv.ParseUint(value, 10, 32)
		if err != nil || pid == 0 {
			continue
		}
		buffer := make([]byte, 4096)
		_, _, errno := syscall.Syscall6(syscall.SYS_PROC_INFO,
			2, uintptr(pid), 11, 0, uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
		if errno == 0 {
			paths = append(paths, unix.ByteSliceToString(buffer))
		}
	}
	return paths, nil
}
