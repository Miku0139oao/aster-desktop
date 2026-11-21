package mobileapi

import (
	"errors"
	"net/netip"
	"strings"

	"github.com/Miku0139oao/aster-desktop/bridge/internal/desktop"
)

// setSystemDNS validates resolver addresses supplied by the mobile app and
// hands them to the in-process core. Mobile VPNs route traffic inside their
// own tunnel, so the core cannot discover the device resolvers itself:
// Android reads them from VpnService LinkProperties and iOS from the active
// network before the tunnel starts.
func setSystemDNS(servers string, core *desktop.Core) error {
	if core == nil {
		return errors.New("mobile host is not ready")
	}
	values := make([]string, 0, 4)
	for _, value := range strings.Split(servers, ",") {
		value = strings.TrimSpace(value)
		// Ignore anything that is not a bare address instead of passing
		// user-controlled strings into the resolver configuration.
		addr, err := netip.ParseAddr(value)
		if err != nil {
			continue
		}
		values = append(values, addr.String())
	}
	if len(values) == 0 {
		return errors.New("the device did not report a usable DNS server")
	}
	core.SetSystemDNS(values)
	return updatePlatformDNS(values)
}
