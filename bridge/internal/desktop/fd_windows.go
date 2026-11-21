//go:build windows

package desktop

// closeIfOpen is a no-op on Windows: the in-process core never receives a VPN
// descriptor there.
func closeIfOpen(int) error { return nil }
