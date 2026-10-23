//go:build android && !cmfa

package mobileapi

// The stock core build resolves system DNS through Bionic, so there is
// nothing to inject. The gomobile build uses the cmfa tag (see
// scripts/build-android.py) and implements this in systemdns_android.go.
func setSystemDNS(string) error { return nil }
