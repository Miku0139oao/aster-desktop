// Package mobileapi exposes the Aster management layer to the Android VPN
// service. The core runs in the service process so its TUN descriptor and
// protected outbound sockets remain owned by Android's VpnService.
package mobileapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

func (h *Host) StartVPN(fd int32) (string, error) {
	if h == nil || h.app == nil {
		return "", errors.New("mobile host is not ready")
	}
	if fd <= 0 {
		return "", errors.New("Android VPN descriptor is not available")
	}
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
	return encode(result, err)
}

func (h *Host) StopVPN() (string, error) {
	if h == nil || h.app == nil {
		return "", errors.New("mobile host is not ready")
	}
	result, err := h.app.Dispatch(h.ctx, desktop.Request{Method: "disconnect"})
	return encode(result, err)
}

func (h *Host) Close() error {
	if h == nil || h.app == nil {
		return nil
	}
	err := h.app.Close()
	h.app = nil
	return err
}

func encode(result any, err error) (string, error) {
	if err != nil {
		return "", err
	}
	b, err := json.Marshal(result)
	if err != nil {
		return "", err
	}
	return string(b), nil
}
