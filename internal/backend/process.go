// Package backend connects the native desktop to the existing, unprivileged
// engine. The same bounded NDJSON protocol is used by the mobile/legacy client.
package backend

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

const (
	maxRequestBytes  = (16 << 20) + 4096 // bridge request limit
	maxResponseBytes = 64 << 20
)

type Event struct {
	Name string          `json:"event"`
	Data json.RawMessage `json:"data"`
}

type Client interface {
	Call(context.Context, string, any, any) error
	Events() <-chan Event
	Close() error
}

type reply struct {
	ID     uint64          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
}

type Process struct {
	cmd       *exec.Cmd
	in        io.WriteCloser
	mu        sync.Mutex
	writeMu   sync.Mutex
	seq       uint64
	pending   map[uint64]chan reply
	events    chan Event
	done      chan struct{}
	closeOnce sync.Once
	closeErr  error
	exitErr   error
}

func Start(bridge, core, data, gui string) (*Process, error) {
	if _, err := os.Stat(bridge); err != nil {
		return nil, fmt.Errorf("the desktop engine is missing: %w", err)
	}
	cmd := exec.Command(bridge, "--data", data, "--core", core, "--gui", gui)
	configureProcess(cmd)
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		in.Close()
		return nil, err
	}
	cmd.Stderr = os.Stderr
	p := &Process{cmd: cmd, in: in, pending: make(map[uint64]chan reply), events: make(chan Event, 64), done: make(chan struct{})}
	if err = cmd.Start(); err != nil {
		in.Close()
		out.Close()
		return nil, err
	}
	go p.read(out)
	return p, nil
}

func (p *Process) read(out io.Reader) {
	scanner := bufio.NewScanner(out)
	scanner.Buffer(make([]byte, 64<<10), maxResponseBytes)
	for scanner.Scan() {
		var message struct {
			Event
			reply
		}
		if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
			continue
		}
		if message.Name != "" {
			// Telemetry is replaceable. Never block replies behind a hidden UI.
			select {
			case p.events <- message.Event:
			default:
			}
			continue
		}
		r := message.reply
		if r.ID == 0 {
			continue
		}
		p.mu.Lock()
		ch := p.pending[r.ID]
		delete(p.pending, r.ID)
		p.mu.Unlock()
		if ch != nil {
			ch <- r
		}
	}
	err := scanner.Err()
	if err != nil {
		// EOF lets the broker restore the system proxy before exiting.
		_ = p.in.Close()
		_, _ = io.Copy(io.Discard, out)
	}
	waitErr := p.cmd.Wait()
	if err == nil {
		err = waitErr
	}
	if err == nil {
		err = io.EOF
	}
	p.mu.Lock()
	p.exitErr = err
	close(p.done)
	p.mu.Unlock()
	close(p.events)
}

func (p *Process) Call(ctx context.Context, method string, params, result any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	p.mu.Lock()
	if p.exitErr != nil {
		err := p.exitErr
		p.mu.Unlock()
		return fmt.Errorf("desktop engine stopped: %w", err)
	}
	p.seq++
	id := p.seq
	ch := make(chan reply, 1)
	p.pending[id] = ch
	p.mu.Unlock()
	defer func() { p.mu.Lock(); delete(p.pending, id); p.mu.Unlock() }()
	b, err := json.Marshal(struct {
		ID     uint64 `json:"id"`
		Method string `json:"method"`
		Params any    `json:"params"`
	}{id, method, params})
	if err != nil {
		return err
	}
	if len(b) >= maxRequestBytes {
		return errors.New("request exceeds the desktop engine limit")
	}
	p.writeMu.Lock()
	_, err = p.in.Write(append(b, '\n'))
	p.writeMu.Unlock()
	if err != nil {
		return fmt.Errorf("desktop engine: %w", err)
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-p.done:
		p.mu.Lock()
		err = p.exitErr
		p.mu.Unlock()
		return fmt.Errorf("desktop engine stopped: %w", err)
	case r := <-ch:
		if r.Error != nil {
			return errors.New(r.Error.Message)
		}
		if result != nil && len(r.Result) > 0 && string(r.Result) != "null" {
			return json.Unmarshal(r.Result, result)
		}
		return nil
	}
}

func (p *Process) Events() <-chan Event { return p.events }

func (p *Process) Close() error {
	p.closeOnce.Do(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		p.closeErr = p.Call(ctx, "disconnect", nil, nil)
		cancel()
		_ = p.in.Close()
		select {
		case <-p.done:
		case <-time.After(15 * time.Second):
			_ = p.cmd.Process.Kill()
			<-p.done
		}
	})
	return p.closeErr
}

// Executables resolves installed bundles and the local development build.
func Executables(gui string) (bridge, core string) {
	suffix := ""
	if runtime.GOOS == "windows" {
		suffix = ".exe"
	}
	dir := filepath.Dir(gui)
	if runtime.GOOS == "darwin" {
		dir = filepath.Join(dir, "..", "Resources")
	}
	bridge = filepath.Join(dir, "aster-bridge"+suffix)
	if _, err := os.Stat(bridge); err != nil {
		if development, err := filepath.Abs(filepath.Join(".build", "aster-bridge"+suffix)); err == nil {
			bridge = development
		}
	}
	return bridge, filepath.Join(filepath.Dir(bridge), "aster-core"+suffix)
}
