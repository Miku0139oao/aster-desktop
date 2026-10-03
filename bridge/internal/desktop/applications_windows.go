package desktop

import (
	"context"
	"errors"
	"unsafe"

	"golang.org/x/sys/windows"
)

func applicationPaths(ctx context.Context) ([]string, error) {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return nil, err
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ProcessEntry32{Size: uint32(unsafe.Sizeof(windows.ProcessEntry32{}))}
	paths := []string{}
	buffer := make([]uint16, 32768)
	var currentSession uint32
	if err = windows.ProcessIdToSessionId(windows.GetCurrentProcessId(), &currentSession); err != nil {
		return nil, err
	}
	err = windows.Process32First(snapshot, &entry)
	for err == nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		var session uint32
		if windows.ProcessIdToSessionId(entry.ProcessID, &session) != nil || session != currentSession {
			err = windows.Process32Next(snapshot, &entry)
			continue
		}
		process, openErr := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, entry.ProcessID)
		if openErr == nil {
			size := uint32(len(buffer))
			queryErr := windows.QueryFullProcessImageName(process, 0, &buffer[0], &size)
			windows.CloseHandle(process)
			if queryErr == nil {
				paths = append(paths, windows.UTF16ToString(buffer[:size]))
			}
		}
		err = windows.Process32Next(snapshot, &entry)
	}
	if !errors.Is(err, windows.ERROR_NO_MORE_FILES) {
		return nil, err
	}
	return paths, nil
}
