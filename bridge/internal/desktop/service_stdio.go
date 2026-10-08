package desktop

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"runtime"
)

func ServePrivilegedStdio(ctx context.Context, core *Core, in io.Reader, out io.Writer) error {
	defer core.Stop()
	if err := core.RecoverProxy(); err != nil {
		return err
	}
	r := bufio.NewReader(in)
	for {
		line, err := readBoundedLine(r, MaxConfig+4096)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		var req Request
		if err = json.Unmarshal(line, &req); err != nil {
			return err
		}
		var p struct {
			Content      string
			Port         int
			Settings     Settings
			Method, Path string
			Body         any
		}
		err = decode(req.Params, &p)
		var result any
		if err == nil {
			switch req.Method {
			case "status":
				result = core.Status()
			case "start":
				p.Settings.Tun = true
				p.Settings.SystemProxy = false
				err = core.Start(ctx, p.Content, p.Settings, true)
			case "stop":
				err = core.Stop()
				result = true
			case "apply":
				p.Settings.Tun = true
				p.Settings.SystemProxy = false
				err = core.Apply(ctx, p.Content, p.Settings, true)
			case "controller":
				if !allowedController(p.Method, p.Path) {
					err = errors.New("unsupported controller operation")
				} else {
					result, err = core.Request(ctx, p.Method, p.Path, p.Body)
				}
			case "logs":
				result = core.Logs()
			case "metrics":
				result = serviceMetrics(ctx, core)
			case "proxyStart":
				if runtime.GOOS != "darwin" || p.Port < 1024 || p.Port > 65535 {
					err = errors.New("unsupported desktop proxy operation")
				} else {
					err = core.enableProxy(p.Port, false)
					result = true
				}
			case "proxyStop":
				err = core.restoreProxy()
				result = true
			case "updateCore":
				result, err = UpdateServiceCore(ctx, core, p.Port)
			default:
				err = errors.New("unsupported XPC operation")
			}
		}
		response := Response{ID: req.ID, Result: result}
		if err != nil {
			response.Result = nil
			response.Error = &RPCError{Code: "service", Message: err.Error()}
		}
		if err = json.NewEncoder(out).Encode(response); err != nil {
			return err
		}
	}
}
