// Native test-version installer; payload is embedded by package-windows.ps1.
package main

import (
	"archive/zip"
	"bytes"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

//go:embed payload.zip install.ps1
var files embed.FS

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--verify" {
		if err := verify(); err != nil {
			os.Exit(1)
		}
		return
	}
	if err := install(); err != nil {
		message("安裝未完成 / Installation incomplete\n\n" + err.Error())
		os.Exit(1)
	}
}
func message(content string) {
	text, _ := windows.UTF16PtrFromString(content)
	title, _ := windows.UTF16PtrFromString("Aster Desktop")
	windows.NewLazySystemDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), 0x10)
}
func verify() error {
	data, err := files.ReadFile("payload.zip")
	if err != nil {
		return err
	}
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return err
	}
	required := map[string]bool{"aster_desktop.exe": false, "aster-core.exe": false, "aster-bridge.exe": false, "LICENSE": false}
	for _, file := range reader.File {
		name := strings.ReplaceAll(file.Name, "\\", "/")
		if strings.HasPrefix(name, "/") || strings.Contains(name, ":") {
			return errors.New("unsafe package entry")
		}
		for _, part := range strings.Split(name, "/") {
			if part == ".." {
				return errors.New("unsafe package entry")
			}
		}
		if !file.FileInfo().IsDir() {
			stream, err := file.Open()
			if err != nil {
				return err
			}
			_, err = io.Copy(io.Discard, stream)
			stream.Close()
			if err != nil {
				return err
			}
		}
		if _, ok := required[name]; ok {
			required[name] = true
		}
	}
	for name, present := range required {
		if !present {
			return fmt.Errorf("package is missing %s", name)
		}
	}
	return nil
}
func install() error {
	if !windows.GetCurrentProcessToken().IsElevated() {
		return elevate()
	}
	if err := verify(); err != nil {
		return err
	}
	base, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, 0)
	if err != nil {
		return err
	}
	var random [16]byte
	if _, err = rand.Read(random[:]); err != nil {
		return err
	}
	dir := filepath.Join(base, "AsterDesktop-setup-"+hex.EncodeToString(random[:]))
	descriptor, err := windows.SecurityDescriptorFromString("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")
	if err != nil {
		return err
	}
	path, _ := windows.UTF16PtrFromString(dir)
	attributes := windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: descriptor}
	if err = windows.CreateDirectory(path, &attributes); err != nil {
		return err
	}
	defer func() {
		relative, err := filepath.Rel(base, dir)
		if err == nil && !strings.Contains(relative, string(os.PathSeparator)) && strings.HasPrefix(relative, "AsterDesktop-setup-") {
			_ = os.RemoveAll(dir)
		}
	}()
	for _, name := range []string{"payload.zip", "install.ps1"} {
		data, err := files.ReadFile(name)
		if err != nil {
			return err
		}
		if err = os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
			return err
		}
	}
	system, err := windows.GetSystemDirectory()
	if err != nil {
		return err
	}
	programFiles, err := windows.KnownFolderPath(windows.FOLDERID_ProgramFiles, 0)
	if err != nil {
		return err
	}
	command := exec.Command(filepath.Join(system, "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", filepath.Join(dir, "install.ps1"))
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	command.Env = append(os.Environ(), "ProgramFiles="+programFiles, "SystemRoot="+filepath.Dir(system), "WINDIR="+filepath.Dir(system))
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("close Aster Desktop and retry; %s", strings.TrimSpace(string(output)))
	}
	return nil
}
func elevate() error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	verb, _ := windows.UTF16PtrFromString("runas")
	file, _ := windows.UTF16PtrFromString(executable)
	type info struct {
		Size, Mask                        uint32
		Window                            uintptr
		Verb, File, Parameters, Directory *uint16
		Show                              int32
		Instance, IDList                  uintptr
		Class                             *uint16
		ClassKey                          uintptr
		HotKey                            uint32
		Icon                              uintptr
		Process                           windows.Handle
	}
	value := info{Mask: 0x40 | 0x400, Verb: verb, File: file, Show: 0}
	value.Size = uint32(unsafe.Sizeof(value))
	result, _, callErr := windows.NewLazySystemDLL("shell32.dll").NewProc("ShellExecuteExW").Call(uintptr(unsafe.Pointer(&value)))
	if result == 0 {
		return fmt.Errorf("administrator permission was not granted: %w", callErr)
	}
	defer windows.CloseHandle(value.Process)
	if result, err := windows.WaitForSingleObject(value.Process, windows.INFINITE); err != nil || result != windows.WAIT_OBJECT_0 {
		return errors.New("installer did not complete")
	}
	var code uint32
	if err = windows.GetExitCodeProcess(value.Process, &code); err != nil {
		return err
	}
	if code != 0 {
		return errors.New("installer did not complete; close the app and try again")
	}
	return nil
}
