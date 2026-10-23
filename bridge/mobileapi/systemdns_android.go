//go:build android && cmfa

package mobileapi

import (
	"errors"
	"net/netip"
	"strings"

	"github.com/Miku0139oao/aster-core/dns"
)

func setSystemDNS(servers string) error {
	values := make([]string, 0, 4)
	for _, value := range strings.Split(servers, ",") {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		// LinkProperties exposes bare addresses on current Android releases.
		// Ignore anything else instead of passing user-controlled strings on.
		if _, err := netip.ParseAddr(value); err != nil {
			continue
		}
		values = append(values, value)
	}
	if len(values) == 0 {
		return errors.New("Android did not report a usable DNS server")
	}
	dns.UpdateSystemDNS(values)
	return nil
}
