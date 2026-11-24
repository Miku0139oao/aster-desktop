// Package instance shares the original client's authenticated activation lease.
package instance

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

type Lease struct {
	lock     *os.File
	listener net.Listener
}
type endpoint struct {
	PID   int    `json:"pid"`
	Port  int    `json:"port"`
	Token string `json:"token"`
}

func DataDirectory() (string, error) {
	switch runtime.GOOS {
	case "windows":
		dir, err := os.UserConfigDir()
		return filepath.Join(dir, "app.astercore", "aster_desktop"), err
	case "darwin":
		dir, err := os.UserConfigDir()
		return filepath.Join(dir, "app.astercore.asterDesktop"), err
	default:
		dir := os.Getenv("XDG_DATA_HOME")
		if !filepath.IsAbs(dir) {
			home, e := os.UserHomeDir()
			if e != nil {
				return "", e
			}
			dir = filepath.Join(home, ".local", "share")
		}
		current := filepath.Join(dir, "app.astercore.aster_desktop")
		legacy := filepath.Join(dir, "aster_desktop")
		if _, err := os.Stat(current); errors.Is(err, os.ErrNotExist) {
			if info, err := os.Stat(legacy); err == nil && info.IsDir() {
				return legacy, nil
			}
		}
		return current, nil
	}
}

// Acquire returns nil after activating the existing instance. No bridge or core
// may be started until a lease has been acquired. Old Flutter copies participate
// in this exact file lock and activation protocol as well.
func Acquire(ctx context.Context, dir string, activate func() bool) (*Lease, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "desktop.instance.json")
	for {
		f, err := tryLock(filepath.Join(dir, "desktop.instance.lock"))
		if err == nil {
			ln, e := net.Listen("tcp4", "127.0.0.1:0")
			if e != nil {
				f.Close()
				return nil, e
			}
			var random [32]byte
			if _, e = rand.Read(random[:]); e != nil {
				ln.Close()
				f.Close()
				return nil, e
			}
			ep := endpoint{os.Getpid(), ln.Addr().(*net.TCPAddr).Port, base64.URLEncoding.EncodeToString(random[:])}
			b, _ := json.Marshal(ep)
			tmp, e := os.CreateTemp(dir, ".activation-*")
			if e == nil {
				e = tmp.Chmod(0600)
				if e == nil {
					_, e = tmp.Write(b)
				}
				if ce := tmp.Close(); e == nil {
					e = ce
				}
				if e == nil {
					e = replaceEndpoint(tmp.Name(), path)
				}
				os.Remove(tmp.Name())
			}
			if e != nil {
				ln.Close()
				f.Close()
				return nil, e
			}
			lease := &Lease{f, ln}
			go lease.serve(ep.Token, activate)
			return lease, nil
		} else if !errors.Is(err, errLeaseBusy) {
			return nil, err
		}
		if b, e := os.ReadFile(path); e == nil {
			var ep endpoint
			if json.Unmarshal(b, &ep) == nil && ep.PID > 0 && ep.Port > 0 && ep.Port <= 65535 && len(ep.Token) == 44 {
				if activateExisting(ctx, ep) == nil {
					return nil, nil
				}
			}
		}
		select {
		case <-ctx.Done():
			return nil, errors.New("Aster Desktop is already running but could not reveal its window; open it from the tray")
		case <-time.After(100 * time.Millisecond):
		}
	}
}

var errLeaseBusy = errors.New("another desktop instance owns the lease")

func activateExisting(ctx context.Context, ep endpoint) error {
	conn, err := (&net.Dialer{Timeout: 600 * time.Millisecond}).DialContext(ctx, "tcp4", fmt.Sprintf("127.0.0.1:%d", ep.Port))
	if err != nil {
		return err
	}
	defer conn.Close()
	grantForeground(ep.PID)
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err = fmt.Fprintf(conn, "activate %s\n", ep.Token); err != nil {
		return err
	}
	reply, err := bufio.NewReader(io.LimitReader(conn, 16)).ReadString('\n')
	if err != nil {
		return err
	}
	if reply != "ok\n" {
		return errors.New("activation rejected")
	}
	return nil
}

func (l *Lease) serve(token string, activate func() bool) {
	for {
		conn, err := l.listener.Accept()
		if err != nil {
			return
		}
		go func() {
			defer conn.Close()
			_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
			line, err := bufio.NewReader(io.LimitReader(conn, 128)).ReadString('\n')
			if err == nil && subtle.ConstantTimeCompare([]byte(line), []byte("activate "+token+"\n")) == 1 {
				reply := "error\n"
				if activate() {
					reply = "ok\n"
				}
				_, _ = io.WriteString(conn, reply)
			}
		}()
	}
}
func (l *Lease) Close() error {
	if l == nil {
		return nil
	}
	_ = l.listener.Close()
	return l.lock.Close()
}
