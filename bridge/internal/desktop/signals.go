package desktop

import (
	"context"
	"net"
	"os"
	"os/signal"
	"syscall"
)

func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
}
func unusedPort() int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 17890
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
