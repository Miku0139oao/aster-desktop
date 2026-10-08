package desktop

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"runtime"
	"sync"
	"time"
)

type ServiceClient struct {
	conn   net.Conn
	mu     sync.Mutex
	reader *bufio.Reader
	id     int
}

func ConnectService() (*ServiceClient, error) {
	conn, err := dialService()
	if err != nil {
		return nil, err
	}
	return &ServiceClient{conn: conn, reader: bufio.NewReader(conn)}, nil
}
func (s *ServiceClient) Close() { s.conn.Close() }
func (s *ServiceClient) Call(method string, params, result any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.id++
	p, err := json.Marshal(params)
	if err != nil {
		return err
	}
	timeout := 2 * time.Minute
	if method == "updateCore" {
		timeout = 10 * time.Minute
	}
	_ = s.conn.SetDeadline(time.Now().Add(timeout))
	if err = json.NewEncoder(s.conn).Encode(Request{ID: s.id, Method: method, Params: p}); err != nil {
		return err
	}
	var response struct {
		ID     int             `json:"id"`
		Result json.RawMessage `json:"result"`
		Error  *RPCError       `json:"error"`
	}
	if err = json.NewDecoder(s.reader).Decode(&response); err != nil {
		return err
	}
	if response.Error != nil {
		return errors.New(response.Error.Message)
	}
	if response.ID != s.id {
		return errors.New("service response did not match request")
	}
	if result != nil {
		return json.Unmarshal(response.Result, result)
	}
	return nil
}
func ServePrivileged(ctx context.Context, listener net.Listener, core *Core) error {
	defer listener.Close()
	go func() { <-ctx.Done(); listener.Close() }()
	var owner sync.Mutex
	for {
		conn, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		if err = verifyServicePeer(conn); err != nil {
			conn.Close()
			continue
		}
		if !owner.TryLock() {
			_ = json.NewEncoder(conn).Encode(Response{Error: &RPCError{Code: "busy", Message: "another desktop session owns the background service"}})
			conn.Close()
			continue
		}
		go func() {
			defer owner.Unlock()
			defer conn.Close()
			defer core.Stop()
			reader := bufio.NewReaderSize(conn, 64<<10)
			for {
				_ = conn.SetReadDeadline(time.Now().Add(60 * time.Second))
				line, err := readBoundedLine(reader, MaxConfig+4096)
				if err != nil {
					return
				}
				var req Request
				if json.Unmarshal(line, &req) != nil {
					return
				}
				var result any
				var input struct {
					Port         int
					Content      string
					Settings     Settings
					Method, Path string
					Body         any
				}
				err = decode(req.Params, &input)
				if err == nil {
					switch req.Method {
					case "status":
						result = core.Status()
					case "start":
						input.Settings.Tun = true
						input.Settings.SystemProxy = false
						err = core.Start(ctx, input.Content, input.Settings, true)
					case "stop":
						err = core.Stop()
						result = true
					case "apply":
						input.Settings.Tun = true
						input.Settings.SystemProxy = false
						err = core.Apply(ctx, input.Content, input.Settings, true)
					case "controller":
						if !allowedController(input.Method, input.Path) {
							err = errors.New("unsupported controller operation")
						} else {
							result, err = core.Request(ctx, input.Method, input.Path, input.Body)
						}
					case "logs":
						result = core.Logs()
					case "metrics":
						result = serviceMetrics(ctx, core)
					case "updateCore":
						result, err = UpdateServiceCore(ctx, core, input.Port)
					default:
						err = errors.New("unsupported privileged operation")
					}
				}
				response := Response{ID: req.ID, Result: result}
				if err != nil {
					response.Result = nil
					response.Error = &RPCError{Code: "service", Message: err.Error()}
				}
				if json.NewEncoder(conn).Encode(response) != nil {
					return
				}
			}
		}()
	}
}
func serviceMetrics(ctx context.Context, c *Core) any {
	connections, _ := c.Request(ctx, "GET", "/connections", nil)
	return map[string]any{"connections": connections, "core": c.Status()}
}
func readBoundedLine(r *bufio.Reader, max int) ([]byte, error) {
	var b []byte
	for {
		part, more, err := r.ReadLine()
		if err != nil {
			return nil, err
		}
		if len(b)+len(part) > max {
			return nil, fmt.Errorf("request exceeds size limit")
		}
		b = append(b, part...)
		if !more {
			return b, nil
		}
	}
}
func ServeStdio(ctx context.Context, a *App, in io.Reader, out io.Writer) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var outMu sync.Mutex
	send := func(value any) { outMu.Lock(); defer outMu.Unlock(); _ = json.NewEncoder(out).Encode(value) }
	a.Emit = func(name string, value any) { send(map[string]any{"event": name, "data": value}) }
	go a.trafficLoop(ctx)
	if runtime.GOOS != "darwin" {
		go a.Schedule(ctx)
	}
	r := bufio.NewReaderSize(in, 64<<10)
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
			send(Response{Error: &RPCError{Code: "invalid", Message: "invalid desktop request"}})
			continue
		}
		go func(req Request) {
			defer func() {
				if recover() != nil {
					send(Response{ID: req.ID, Error: &RPCError{Code: "internal", Message: "operation failed; reconnect and try again"}})
				}
			}()
			result, err := a.Dispatch(ctx, req)
			response := Response{ID: req.ID, Result: result}
			if err != nil {
				response.Error = &RPCError{Code: "operation", Message: err.Error()}
				response.Result = nil
			}
			send(response)
		}(req)
	}
}
