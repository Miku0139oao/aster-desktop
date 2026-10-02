package desktop

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

var gnomeKeys = [][2]string{{"org.gnome.system.proxy", "mode"}, {"org.gnome.system.proxy", "autoconfig-url"}, {"org.gnome.system.proxy", "ignore-hosts"}, {"org.gnome.system.proxy.http", "host"}, {"org.gnome.system.proxy.http", "port"}, {"org.gnome.system.proxy.https", "host"}, {"org.gnome.system.proxy.https", "port"}, {"org.gnome.system.proxy.socks", "host"}, {"org.gnome.system.proxy.socks", "port"}}

func CaptureProxy(port int) (ProxySnapshot, error) {
	desktop := strings.ToLower(os.Getenv("XDG_CURRENT_DESKTOP"))
	before := map[string]string{}
	installed := map[string]string{}
	if strings.Contains(desktop, "gnome") || strings.Contains(desktop, "ubuntu") {
		for _, k := range gnomeKeys {
			v, err := command("gsettings", "get", k[0], k[1])
			if err != nil {
				return ProxySnapshot{}, fmt.Errorf("cannot read GNOME proxy: %s", v)
			}
			before[k[0]+"/"+k[1]] = v
		}
		for _, k := range gnomeKeys {
			id := k[0] + "/" + k[1]
			switch k[1] {
			case "mode":
				installed[id] = "'manual'"
			case "autoconfig-url":
				installed[id] = "''"
			case "ignore-hosts":
				installed[id] = "['localhost', '127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']"
			case "host":
				installed[id] = "'127.0.0.1'"
			case "port":
				installed[id] = strconv.Itoa(port)
			}
		}
		return ProxySnapshot{Backend: "gnome", Targets: []ProxyTarget{{Before: before, Installed: installed}}}, nil
	}
	if strings.Contains(desktop, "kde") {
		version := "6"
		if _, err := exec.LookPath("kreadconfig6"); err != nil {
			version = "5"
		}
		for _, k := range []string{"ProxyType", "httpProxy", "httpsProxy", "socksProxy", "NoProxyFor"} {
			v, err := command("kreadconfig"+version, "--file", "kioslaverc", "--group", "Proxy Settings", "--key", k)
			if err != nil {
				return ProxySnapshot{}, err
			}
			before[k] = v
		}
		installed = map[string]string{"ProxyType": "1", "httpProxy": fmt.Sprintf("http://127.0.0.1 %d", port), "httpsProxy": fmt.Sprintf("http://127.0.0.1 %d", port), "socksProxy": fmt.Sprintf("socks://127.0.0.1 %d", port), "NoProxyFor": "localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"}
		return ProxySnapshot{Backend: "kde" + version, Targets: []ProxyTarget{{Before: before, Installed: installed}}}, nil
	}
	return ProxySnapshot{}, errors.New("this desktop does not expose supported proxy settings; use TUN or set your application proxy to 127.0.0.1")
}
func writeLinuxProxy(backend string, values map[string]string) error {
	for k, v := range values {
		if backend == "gnome" {
			parts := strings.SplitN(k, "/", 2)
			if len(parts) != 2 {
				return errors.New("invalid GNOME proxy backup")
			}
			if out, err := command("gsettings", "set", parts[0], parts[1], v); err != nil {
				return fmt.Errorf("cannot set proxy: %s", out)
			}
		} else {
			if out, err := command("kwriteconfig"+strings.TrimPrefix(backend, "kde"), "--file", "kioslaverc", "--group", "Proxy Settings", "--key", k, v); err != nil {
				return fmt.Errorf("cannot set proxy: %s", out)
			}
		}
	}
	if strings.HasPrefix(backend, "kde") {
		_, _ = command("dbus-send", "--session", "--type=signal", "/KIO/Scheduler", "org.kde.KIO.Scheduler.reparseSlaveConfiguration", "string:")
	}
	return nil
}
func SetProxy(p ProxySnapshot) error { return writeLinuxProxy(p.Backend, p.Targets[0].Installed) }
func RestoreProxy(p ProxySnapshot) error {
	if len(p.Targets) != 1 {
		return errors.New("invalid proxy backup")
	}
	current, err := CaptureProxy(7890)
	if err != nil {
		return err
	}
	if current.Backend != p.Backend {
		return errors.New("desktop changed; restore the original desktop proxy first")
	}
	flag := "ProxyType"
	endpoints := []string{"httpProxy", "httpsProxy", "socksProxy"}
	if p.Backend == "gnome" {
		flag = "org.gnome.system.proxy/mode"
		endpoints = []string{"org.gnome.system.proxy.http/host", "org.gnome.system.proxy.http/port", "org.gnome.system.proxy.https/host", "org.gnome.system.proxy.https/port", "org.gnome.system.proxy.socks/host", "org.gnome.system.proxy.socks/port", "org.gnome.system.proxy/autoconfig-url"}
	}
	groups := [][]string{}
	if p.Backend == "gnome" {
		for _, kind := range []string{"http", "https", "socks"} {
			groups = append(groups, []string{"org.gnome.system.proxy." + kind + "/host", "org.gnome.system.proxy." + kind + "/port"})
		}
	}
	return writeLinuxProxy(p.Backend, ownedProxyValues(p.Targets[0], current.Targets[0].Before, flag, endpoints, groups...))
}
