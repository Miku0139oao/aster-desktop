//go:build !android

package mobileapi

// The desktop-hosted tests do not run the Android GUI build of the core.
func setSystemDNS(string) error { return nil }
