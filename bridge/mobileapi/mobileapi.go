// Package mobileapi exposes the Aster management layer to Android VpnService
// and the iOS NetworkExtension. The core runs in the mobile service process so
// its TUN descriptor remains owned by the mobile VPN implementation.
package mobileapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"syscall"

	"github.com/Miku0139oao/aster-core/component/dialer"
	"github.com/Miku0139oao/aster-desktop/bridge/internal/desktop"
	_ "golang.org/x/mobile/bind"
)

// SocketProtector is implemented by Android's VpnService. Every outbound core
// socket must be protected before dialing or it would re-enter the VPN.
type SocketProtector interface {
	Protect(fd int32) bool
}

type Host struct {
	app *desktop.App
	ctx context.Context
}

var processHost struct {
	sync.Mutex
	host *Host
}

func NewHost(dataDir string) (*Host, error) {
	if dataDir == "" {
		return nil, errors.New("data directory is required")
	}
	app, err := desktop.NewMobileApp(dataDir)
	if err != nil {
		return nil, err
	}
	return &Host{app: app, ctx: context.Background()}, nil
}

func OpenHost(dataDir string) error {
	processHost.Lock()
	defer processHost.Unlock()
	if processHost.host != nil {
		return errors.New("mobile host is already open")
	}
	host, err := NewHost(dataDir)
	if err != nil {
		return err
	}
	processHost.host = host
	return nil
}

func CloseHost() error {
	processHost.Lock()
	host := processHost.host
	processHost.host = nil
	processHost.Unlock()
	if host == nil {
		return nil
	}
	return host.Close()
}

func currentHost() (*Host, error) {
	processHost.Lock()
	defer processHost.Unlock()
	if processHost.host == nil {
		return nil, errors.New("mobile host is not open")
	}
	return processHost.host, nil
}

func CallHost(request string) (string, error) {
	host, err := currentHost()
	if err != nil {
		return "", err
	}
	return host.Call(request)
}

func StartHostVPN(fd int32, options string) (string, error) {
	host, err := currentHost()
	if err != nil {
		return "", err
	}
	return host.StartVPN(fd, options)
}

func StopHostVPN() (string, error) {
	host, err := currentHost()
	if err != nil {
		return "", err
	}
	return host.StopVPN()
}

func SetHostProtector(protector SocketProtector) error {
	host, err := currentHost()
	if err != nil {
		return err
	}
	return host.SetProtector(protector)
}

func SetHostSystemDNS(servers string) error {
	host, err := currentHost()
	if err != nil {
		return err
	}
	return host.SetSystemDNS(servers)
}

func (h *Host) SetProtector(protector SocketProtector) error {
	if h == nil || h.app == nil {
		return errors.New("mobile host is not ready")
	}
	if protector == nil {
		return errors.New("socket protector is required")
	}
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		var protectErr error
		controlErr := conn.Control(func(fd uintptr) {
			if !protector.Protect(int32(fd)) {
				protectErr = fmt.Errorf("Android refused to protect %s socket to %s", network, address)
			}
		})
		if controlErr != nil {
			return controlErr
		}
		return protectErr
	}
	return nil
}

func (h *Host) Call(request string) (string, error) {
	if h == nil || h.app == nil {
		return "", errors.New("mobile host is not ready")
	}
	var req desktop.Request
	if err := json.Unmarshal([]byte(request), &req); err != nil {
		return "", errors.New("invalid mobile request")
	}
	result, err := h.app.Dispatch(h.ctx, req)
	response := desktop.Response{ID: req.ID, Result: result}
	if err != nil {
		response.Result = nil
		response.Error = &desktop.RPCError{Code: "operation", Message: err.Error()}
	}
	encoded, err := json.Marshal(response)
	if err != nil {
		return "", err
	}
	return string(encoded), nil
}

func (h *Host) StartVPN(fd int32, options string) (string, error) {
	if h == nil || h.app == nil {
		return "", errors.New("mobile host is not ready")
	}
	if fd <= 0 {
		return "", errors.New("VPN TUN descriptor is not available")
	}
	var tunOptions struct {
		IncludePackages []string `json:"includePackages"`
		ExcludePackages []string `json:"excludePackages"`
	}
	if options != "" {
		if err := json.Unmarshal([]byte(options), &tunOptions); err != nil {
			return "", errors.New("invalid mobile package routing options")
		}
	}
	h.app.Core.SetTunPackages(tunOptions.IncludePackages, tunOptions.ExcludePackages)
	h.app.Store.State.Settings.Tun = true
	h.app.Store.State.Settings.SystemProxy = false
	if err := h.app.Store.Save(); err != nil {
		return "", err
	}
	params, _ := json.Marshal(map[string]any{
		"fd":              int(fd),
		"skipSystemProxy": true,
	})
	result, err := h.app.Dispatch(h.ctx, desktop.Request{Method: "connect", Params: params})
	return encodeResponse(result, err)
}

func (h *Host) StopVPN() (string, error) {
	if h == nil || h.app == nil {
		return "", errors.New("mobile host is not ready")
	}
	result, err := h.app.Dispatch(h.ctx, desktop.Request{Method: "disconnect"})
	return encodeResponse(result, err)
}

// SetSystemDNS passes the active Android network resolvers to the embedded
// core. Android builds use the GUI DNS mode, which cannot read /etc/resolv.conf.
func (h *Host) SetSystemDNS(servers string) error {
	if h == nil || h.app == nil {
		return errors.New("mobile host is not ready")
	}
	return setSystemDNS(servers)
}

func (h *Host) Close() error {
	if h == nil || h.app == nil {
		return nil
	}
	err := h.app.Close()
	h.app = nil
	return err
}

func encodeResponse(result any, err error) (string, error) {
	response := desktop.Response{Result: result}
	if err != nil {
		response.Result = nil
		response.Error = &desktop.RPCError{Code: "operation", Message: err.Error()}
	}
	b, marshalErr := json.Marshal(response)
	if marshalErr != nil {
		return "", marshalErr
	}
	return string(b), nil
}
