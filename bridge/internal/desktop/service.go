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

const (
	serviceIdleTimeout = time.Minute
	serviceReplyGrace  = 15 * time.Second
)

func serviceOperationTimeout(method string) time.Duration {
	switch method {
	case "start":
		// Allow validation, one GeoSite cache refresh, cold providers, and a
		// fallback to the previous core to finish under a single budget.
		return 6 * time.Minute
	case "apply":
		return 4 * time.Minute
	case "stop":
		return 15 * time.Second
	case "updateCore":
		return 10 * time.Minute
	default:
		return 2 * time.Minute
	}
}

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
	if err = s.conn.SetDeadline(time.Now().Add(serviceOperationTimeout(method) + serviceReplyGrace)); err != nil {
		return s.transportError(method, err)
	}
	if err = json.NewEncoder(s.conn).Encode(Request{ID: s.id, Method: method, Params: p}); err != nil {
		return s.transportError(method, err)
	}
	var response struct {
		ID     int             `json:"id"`
		Result json.RawMessage `json:"result"`
		Error  *RPCError       `json:"error"`
	}
	if err = json.NewDecoder(s.reader).Decode(&response); err != nil {
		return s.transportError(method, err)
	}
	if response.ID != s.id {
		if response.ID == 0 && response.Error != nil && response.Error.Code == "busy" {
			s.Close()
			return response.Error
		}
		return s.transportError(method, errors.New("service response did not match request"))
	}
	if response.Error != nil {
		return response.Error
	}
	if result != nil {
		return json.Unmarshal(response.Result, result)
	}
	return nil
}

func (s *ServiceClient) transportError(method string, err error) error {
	// A late or partial response makes this session unsafe to reuse.
	s.Close()
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() {
		return fmt.Errorf("background service did not respond to %s before the deadline: %w", method, err)
	}
	return fmt.Errorf("background service communication failed during %s: %w", method, err)
}

func ServePrivileged(ctx context.Context, listener net.Listener, core *Core) error {
	defer listener.Close()
	stopListening := context.AfterFunc(ctx, func() { listener.Close() })
	defer stopListening()
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
			_ = conn.SetWriteDeadline(time.Now().Add(serviceReplyGrace))
			_ = json.NewEncoder(conn).Encode(Response{Error: &RPCError{Code: "busy", Message: "another desktop session owns the background service"}})
			conn.Close()
			continue
		}
		go func() {
			defer owner.Unlock()
			serveServiceSession(ctx, conn, core)
		}()
	}
}

func serveServiceSession(ctx context.Context, conn net.Conn, core *Core) {
	ctx, cancel := context.WithCancel(ctx)
	defer core.Stop()
	defer conn.Close()
	defer cancel()
	// Detect EOF during startup, when the idle lease is suspended. A desktop
	// that loses its transport must release the core and its TUN routes.
	requests := make(chan Request)
	go func() {
		defer cancel()
		reader := bufio.NewReaderSize(conn, 64<<10)
		for {
			line, err := readBoundedLine(reader, MaxConfig+4096)
			if err != nil {
				return
			}
			var req Request
			if json.Unmarshal(line, &req) != nil {
				return
			}
			select {
			case requests <- req:
			case <-ctx.Done():
				return
			}
		}
	}()
	for {
		if conn.SetReadDeadline(time.Now().Add(serviceIdleTimeout)) != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		case req := <-requests:
			if conn.SetReadDeadline(time.Time{}) != nil {
				return
			}
			response := serviceResponse(ctx, core, req)
			if conn.SetWriteDeadline(time.Now().Add(serviceReplyGrace)) != nil || json.NewEncoder(conn).Encode(response) != nil {
				return
			}
		}
	}
}

func serviceResponse(ctx context.Context, core *Core, req Request) Response {
	ctx, cancel := context.WithTimeout(ctx, serviceOperationTimeout(req.Method))
	defer cancel()
	response := Response{ID: req.ID}
	result, err := handleServiceRequest(ctx, core, req)
	if err == nil {
		response.Result = result
		return response
	}
	response.Error = &RPCError{Code: "service", Message: err.Error()}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		response.Error.Message = fmt.Sprintf("background service %s timed out: %v", req.Method, err)
	}
	if req.Method == "start" {
		logs := core.Logs()
		if len(logs) > 24 {
			logs = logs[len(logs)-24:]
		}
		for i := range logs {
			logs[i] = bounded(logs[i], 750)
		}
		response.Error.Logs = logs
	}
	return response
}

func handleServiceRequest(ctx context.Context, core *Core, req Request) (any, error) {
	var input struct {
		Port         int
		Content      string
		Settings     Settings
		Method, Path string
		Body         any
	}
	if err := decode(req.Params, &input); err != nil {
		return nil, err
	}
	switch req.Method {
	case "status":
		return core.Status(), nil
	case "start":
		input.Settings.Tun = true
		input.Settings.SystemProxy = false
		return nil, core.Start(ctx, input.Content, input.Settings, true)
	case "stop":
		return true, core.Stop()
	case "apply":
		input.Settings.Tun = true
		input.Settings.SystemProxy = false
		return nil, core.Apply(ctx, input.Content, input.Settings, true)
	case "controller":
		if !allowedController(input.Method, input.Path) {
			return nil, errors.New("unsupported controller operation")
		}
		return core.Request(ctx, input.Method, input.Path, input.Body)
	case "logs":
		return core.Logs(), nil
	case "metrics":
		return serviceMetrics(ctx, core), nil
	case "updateCore":
		return UpdateServiceCore(ctx, core, input.Port)
	default:
		return nil, errors.New("unsupported privileged operation")
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
