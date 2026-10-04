package desktop

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf16"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Resolve Start Menu shortcuts as data, never execute their targets or arguments.
// A single hidden, bounded invocation also obtains small executable icons.
const startMenuCatalogScript = `
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
$shell = New-Object -ComObject Shell.Application
Add-Type -AssemblyName System.Drawing
$roots = @([Console]::In.ReadToEnd() | ConvertFrom-Json)
$seen = @{}
$apps = @()
$iconBudget = 1048576
foreach ($root in $roots) {
  if (-not (Test-Path -LiteralPath $root)) { continue }
  foreach ($link in (Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue)) {
    if ($apps.Count -ge 1000) { break }
    try {
      $folder = $shell.NameSpace($link.DirectoryName)
      if ($null -eq $folder) { continue }
      $item = $folder.ParseName($link.Name)
      if ($null -eq $item -or -not $item.IsLink) { continue }
      $target = $item.GetLink.Path
      if (-not [IO.Path]::IsPathRooted($target) -or [IO.Path]::GetExtension($target) -ine '.exe') { continue }
      if ($target.StartsWith('\\')) { continue }
      if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
      if ([IO.Path]::GetFileName($target) -match '(?i)^(update|uninstall|cmd|powershell|pwsh|rundll32|explorer|wscript|cscript)\.exe$') { continue }
      $key = $target.ToLowerInvariant()
      if ($seen.ContainsKey($key) -or $link.BaseName -match '(?i)uninstall|remove|解除安裝|卸載') { continue }
      $seen[$key] = $true
      $iconText = ''
      $icon = $null; $bitmap = $null; $stream = $null
      try {
        $icon = [Drawing.Icon]::ExtractAssociatedIcon($target)
        if ($null -ne $icon) {
          $bitmap = $icon.ToBitmap()
          $stream = New-Object IO.MemoryStream
          $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
          if ($stream.Length -le 32768 -and $stream.Length -le $iconBudget) {
            $iconText = [Convert]::ToBase64String($stream.ToArray()); $iconBudget -= $stream.Length
          }
        }
      } catch {} finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $icon) { $icon.Dispose() }
      }
      $apps += @{name=$link.BaseName; path=$target; icon=$iconText}
    } catch { continue }
  }
}
ConvertTo-Json -InputObject @($apps) -Compress -Depth 3
`

func installedApplications(ctx context.Context) ([]Application, error) {
	roots := []string{}
	for _, folder := range []*windows.KNOWNFOLDERID{windows.FOLDERID_Programs, windows.FOLDERID_CommonPrograms} {
		if root, err := windows.KnownFolderPath(folder, 0); err == nil {
			roots = append(roots, root)
		}
	}
	return startMenuApplications(ctx, roots)
}

func startMenuApplications(ctx context.Context, roots []string) ([]Application, error) {
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	encoded := utf16.Encode([]rune(startMenuCatalogScript))
	encodedBytes := make([]byte, len(encoded)*2)
	for i, v := range encoded {
		binary.LittleEndian.PutUint16(encodedBytes[i*2:], v)
	}
	command := exec.CommandContext(ctx, filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe"), "-NoProfile", "-NonInteractive", "-EncodedCommand", base64.StdEncoding.EncodeToString(encodedBytes))
	hideCommand(command)
	input, err := json.Marshal(roots)
	if err != nil {
		return nil, err
	}
	command.Stdin = bytes.NewReader(input)
	output, err := command.Output()
	if err != nil {
		return nil, err
	}
	var apps []Application
	err = json.Unmarshal(output, &apps)
	return apps, err
}

func describeApplication(path string) Application {
	name := strings.TrimSuffix(filepath.Base(path), ".exe")
	if description := executableDescription(path); description != "" {
		name = description
	}
	base := strings.ToLower(filepath.Base(path))
	systemRoot := applicationIdentity(os.Getenv("SystemRoot")) + string(filepath.Separator)
	background := strings.HasPrefix(applicationIdentity(path), systemRoot) || strings.Contains(base, "helper") || strings.Contains(base, "crashpad") || strings.Contains(base, "updater")
	return Application{Name: name, Background: background}
}

func executableDescription(path string) string {
	var zero windows.Handle
	size, err := windows.GetFileVersionInfoSize(path, &zero)
	if err != nil || size == 0 || size > 1024*1024 {
		return ""
	}
	data := make([]byte, size)
	if windows.GetFileVersionInfo(path, 0, size, unsafe.Pointer(&data[0])) != nil {
		return ""
	}
	var translations *uint16
	var length uint32
	if windows.VerQueryValue(unsafe.Pointer(&data[0]), `\VarFileInfo\Translation`, unsafe.Pointer(&translations), &length) != nil || length < 4 || length > size {
		return ""
	}
	pairs := unsafe.Slice(translations, int(length)/2)
	for i := 0; i+1 < len(pairs); i += 2 {
		var value *uint16
		var chars uint32
		key := fmt.Sprintf(`\StringFileInfo\%04x%04x\FileDescription`, pairs[i], pairs[i+1])
		if windows.VerQueryValue(unsafe.Pointer(&data[0]), key, unsafe.Pointer(&value), &chars) == nil && value != nil && chars > 0 && chars <= size/2 {
			return strings.TrimSpace(windows.UTF16ToString(unsafe.Slice(value, int(chars))))
		}
	}
	return ""
}
