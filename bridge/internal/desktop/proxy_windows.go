package desktop

import (
	"encoding/binary"
	"fmt"
	"golang.org/x/sys/windows"
	"runtime"
	"strconv"
	"unsafe"
)

var wininet = windows.NewLazySystemDLL("wininet.dll")

type internetOption struct {
	Kind  uint32
	_     uint32
	Value [8]byte
}
type internetOptions struct {
	Size       uint32
	_          uint32
	Connection uintptr
	Count      uint32
	Error      uint32
	Options    uintptr
}

func winProxyRead() (map[string]string, error) {
	opts := []internetOption{{Kind: 1}, {Kind: 2}, {Kind: 3}, {Kind: 4}}
	list := internetOptions{Count: uint32(len(opts)), Options: uintptr(unsafe.Pointer(&opts[0]))}
	list.Size = uint32(unsafe.Sizeof(list))
	size := list.Size
	r, _, err := wininet.NewProc("InternetQueryOptionW").Call(0, 75, uintptr(unsafe.Pointer(&list)), uintptr(unsafe.Pointer(&size)))
	if r == 0 {
		return nil, err
	}
	m := map[string]string{"flags": strconv.FormatUint(binary.LittleEndian.Uint64(opts[0].Value[:]), 10)}
	for i, k := range []string{"server", "bypass", "pac"} {
		p := *(*unsafe.Pointer)(unsafe.Pointer(&opts[i+1].Value[0]))
		if p != nil {
			m[k] = windows.UTF16PtrToString((*uint16)(p))
			kernel.NewProc("GlobalFree").Call(uintptr(p))
		} else {
			m[k] = ""
		}
	}
	return m, nil
}
func winProxyWrite(m map[string]string) error {
	flags, err := strconv.ParseUint(m["flags"], 10, 32)
	if err != nil {
		return err
	}
	strings := make([]*uint16, 3)
	for i, k := range []string{"server", "bypass", "pac"} {
		strings[i], err = windows.UTF16PtrFromString(m[k])
		if err != nil {
			return err
		}
	}
	opts := []internetOption{{Kind: 1}, {Kind: 2}, {Kind: 3}, {Kind: 4}}
	binary.LittleEndian.PutUint64(opts[0].Value[:], flags)
	for i := range strings {
		*(*unsafe.Pointer)(unsafe.Pointer(&opts[i+1].Value[0])) = unsafe.Pointer(strings[i])
	}
	list := internetOptions{Count: 4, Options: uintptr(unsafe.Pointer(&opts[0]))}
	list.Size = uint32(unsafe.Sizeof(list))
	r, _, err := wininet.NewProc("InternetSetOptionW").Call(0, 75, uintptr(unsafe.Pointer(&list)), uintptr(list.Size))
	runtime.KeepAlive(strings)
	if r == 0 {
		return err
	}
	wininet.NewProc("InternetSetOptionW").Call(0, 39, 0, 0)
	wininet.NewProc("InternetSetOptionW").Call(0, 37, 0, 0)
	return nil
}
func CaptureProxy(port int) (ProxySnapshot, error) {
	b, err := winProxyRead()
	return ProxySnapshot{Backend: "windows", Targets: []ProxyTarget{{Before: b, Installed: map[string]string{"flags": "3", "server": fmt.Sprintf("127.0.0.1:%d", port), "bypass": "localhost;127.*;10.*;172.16.*;192.168.*;<local>", "pac": ""}}}}, err
}
func SetProxy(p ProxySnapshot) error { return winProxyWrite(p.Targets[0].Installed) }
func RestoreProxy(p ProxySnapshot) error {
	if len(p.Targets) != 1 || p.Backend != "windows" {
		return fmt.Errorf("invalid proxy backup")
	}
	now, err := winProxyRead()
	if err != nil {
		return err
	}
	return winProxyWrite(ownedProxyValues(p.Targets[0], now, "flags", []string{"server", "pac"}))
}
