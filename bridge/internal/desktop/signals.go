package desktop

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"
)

func signalContext() (context.Context, context.CancelFunc) {
	return signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
}
func unusedPort() int {
	for range 128 {
		packet, err := net.ListenPacket("udp", "127.0.0.1:0")
		if err != nil {
			break
		}
		port := packet.LocalAddr().(*net.UDPAddr).Port
		listener, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		_ = packet.Close()
		if err != nil {
			continue
		}
		_ = listener.Close()
		return port
	}
	return 17890
}
