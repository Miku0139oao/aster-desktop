//go:build android && cmfa

package mobileapi

import (
	"github.com/Miku0139oao/aster-core/dns"
)

// updatePlatformDNS refreshes the core's Android system resolver. The cmfa
// build disables Bionic's system resolver, so the addresses must be pushed.
func updatePlatformDNS(values []string) error {
	dns.UpdateSystemDNS(values)
	return nil
}
