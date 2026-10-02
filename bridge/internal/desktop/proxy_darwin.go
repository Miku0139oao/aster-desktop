package desktop

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

func macProxyInfo(service, kind string) (map[string]string, error) {
	out, err := command("/usr/sbin/networksetup", "-get"+kind, service)
	if err != nil {
		return nil, fmt.Errorf("cannot read network proxy: %s", out)
	}
	m := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(line, ": ")
		if ok {
			m[k] = v
		}
	}
	return m, nil
}
func CaptureProxy(port int) (ProxySnapshot, error) {
	out, err := command("/usr/sbin/networksetup", "-listallnetworkservices")
	if err != nil {
		return ProxySnapshot{}, err
	}
	p := ProxySnapshot{Backend: "macos"}
	for i, name := range strings.Split(out, "\n") {
		if i == 0 || name == "" || strings.HasPrefix(name, "*") {
			continue
		}
		b := map[string]string{}
		installed := map[string]string{}
		for _, kind := range []string{"webproxy", "securewebproxy", "socksfirewallproxy"} {
			m, err := macProxyInfo(name, kind)
			if err != nil {
				return p, err
			}
			for k, v := range m {
				if strings.ReplaceAll(k, " ", "") == "AuthenticatedProxyEnabled" && v != "0" && v != "No" {
					return p, errors.New("an existing authenticated macOS proxy cannot be replaced safely; use all-applications mode")
				}
				b[kind+"/"+k] = v
			}
			installed[kind+"/Enabled"] = "Yes"
			installed[kind+"/Server"] = "127.0.0.1"
			installed[kind+"/Port"] = strconv.Itoa(port)
		}
		auto, err := command("/usr/sbin/networksetup", "-getautoproxyurl", name)
		if err != nil {
			return p, err
		}
		b["auto"] = auto
		installed["auto"] = strings.ReplaceAll(auto, "Enabled: Yes", "Enabled: No")
		p.Targets = append(p.Targets, ProxyTarget{Name: name, Before: b, Installed: installed})
	}
	if len(p.Targets) == 0 {
		return p, errors.New("no active network service found")
	}
	return p, nil
}
func macSet(p ProxySnapshot, restore bool) error {
	for _, t := range p.Targets {
		values := t.Installed
		if restore {
			values = t.Before
		}
		for _, kind := range []string{"webproxy", "securewebproxy", "socksfirewallproxy"} {
			if err := macWriteProxy(t.Name, kind, values); err != nil {
				return err
			}
		}
		state := "off"
		if restore && strings.Contains(t.Before["auto"], "Enabled: Yes") {
			state = "on"
		}
		if out, err := command("/usr/sbin/networksetup", "-setautoproxystate", t.Name, state); err != nil {
			return fmt.Errorf("proxy change requires permission: %s", out)
		}
	}
	return nil
}
func SetProxy(p ProxySnapshot) error { return macSet(p, false) }
func macWriteProxy(name, kind string, values map[string]string) error {
	server, port := values[kind+"/Server"], values[kind+"/Port"]
	if port == "" {
		port = "0"
	}
	if out, err := command("/usr/sbin/networksetup", "-set"+kind, name, server, port); err != nil {
		return fmt.Errorf("proxy change requires permission: %s", out)
	}
	state := "off"
	if values[kind+"/Enabled"] == "Yes" {
		state = "on"
	}
	if out, err := command("/usr/sbin/networksetup", "-set"+kind+"state", name, state); err != nil {
		return fmt.Errorf("proxy change requires permission: %s", out)
	}
	return nil
}
func RestoreProxy(p ProxySnapshot) error {
	if p.Backend != "macos" {
		return errors.New("invalid proxy backup")
	}
	for _, t := range p.Targets {
		for _, kind := range []string{"webproxy", "securewebproxy", "socksfirewallproxy"} {
			m, err := macProxyInfo(t.Name, kind)
			if err != nil {
				return err
			}
			owned := m["Server"] == t.Installed[kind+"/Server"] && m["Port"] == t.Installed[kind+"/Port"]
			if owned {
				values := map[string]string{}
				for k, v := range t.Before {
					values[k] = v
				}
				if m["Enabled"] != t.Installed[kind+"/Enabled"] {
					values[kind+"/Enabled"] = m["Enabled"]
				}
				if err := macWriteProxy(t.Name, kind, values); err != nil {
					return err
				}
			}
		}
		auto, err := command("/usr/sbin/networksetup", "-getautoproxyurl", t.Name)
		if err != nil {
			return err
		}
		if auto == t.Installed["auto"] {
			state := "off"
			if strings.Contains(t.Before["auto"], "Enabled: Yes") {
				state = "on"
			}
			if _, err = command("/usr/sbin/networksetup", "-setautoproxystate", t.Name, state); err != nil {
				return err
			}
		}
	}
	return nil
}
