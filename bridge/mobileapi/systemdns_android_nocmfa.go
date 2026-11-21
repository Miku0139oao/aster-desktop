//go:build android && !cmfa

package mobileapi

// The stock core build resolves system DNS through Bionic, so nothing needs to
// be pushed into the global resolver. The gomobile build uses the cmfa tag (see
// scripts/build-android.py) and implements this in systemdns_android.go.
func updatePlatformDNS([]string) error { return nil }
