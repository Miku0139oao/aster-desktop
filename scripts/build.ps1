param([switch]$Installer)
$ErrorActionPreference='Stop'
$asterRoot=Split-Path -Parent $PSScriptRoot
$asterBuild=Join-Path $asterRoot '.build'
$asterLock=Get-Content (Join-Path $asterRoot 'toolchain.json') -Raw | ConvertFrom-Json
$asterManifest=Get-Content -Raw (Join-Path $asterRoot 'pubspec.yaml')
$asterReleaseMatch=[regex]::Match($asterManifest,'(?m)^version:\s*([^+\s]+)\+\d+')
if(!$asterReleaseMatch.Success){throw 'Could not read version from pubspec.yaml'}
$asterReleaseVersion=$asterReleaseMatch.Groups[1].Value
$env:GOTOOLCHAIN="go$($asterLock.go)"
New-Item -ItemType Directory -Path $asterBuild -Force | Out-Null
Push-Location (Join-Path $asterRoot 'bridge')
try {
  $env:CGO_ENABLED='0'
  $asterDependency=go mod download -json "$($asterLock.coreModule)@$($asterLock.coreVersion)" | ConvertFrom-Json
  if($LASTEXITCODE -ne 0){throw 'Could not obtain the pinned core source'}
  go build -trimpath -ldflags "-X github.com/Miku0139oao/aster-desktop/bridge/internal/desktop.Version=$asterReleaseVersion" -o (Join-Path $asterBuild 'aster-bridge.exe') ./cmd/aster-bridge
  if($LASTEXITCODE -ne 0){throw 'Desktop engine build failed'}
  Push-Location $asterDependency.Dir
  try {
    go build -mod=readonly -tags with_gvisor -trimpath -ldflags "-s -w -X github.com/Miku0139oao/aster-core/constant.Version=alpha-main-a9a3350 -X github.com/Miku0139oao/aster-core/constant.ReleaseAsset=aster-core-windows-amd64-v1" -o (Join-Path $asterBuild 'aster-core.exe') .
    if($LASTEXITCODE -ne 0){throw 'Pinned core build failed'}
  } finally { Pop-Location }
} finally { Pop-Location }
Push-Location $asterRoot
try {
  $env:GOTOOLCHAIN="go$($asterLock.nativeGo)"
  $asterEntry=Join-Path $asterBuild 'native\windows-entry'
  $asterRelease=Join-Path $asterBuild 'native\windows-bundle'
  New-Item -ItemType Directory -Path $asterEntry,$asterRelease -Force | Out-Null
  Copy-Item -Path (Join-Path $asterRoot 'cmd\aster-desktop\*.go') -Destination $asterEntry -Force
  go run "github.com/akavel/rsrc@$($asterLock.windowsResourceTool)" -arch amd64 -ico (Join-Path $asterRoot 'assets/aster.ico') -manifest (Join-Path $asterRoot 'windows/runner/runner.exe.manifest') -o (Join-Path $asterEntry 'resources_windows_amd64.syso')
  if($LASTEXITCODE -ne 0){throw 'Application resource generation failed'}
  go build -mod=readonly -trimpath -ldflags '-H windowsgui -s -w' -o (Join-Path $asterRelease 'aster_desktop.exe') ./.build/native/windows-entry
  if($LASTEXITCODE -ne 0){throw 'MyGo desktop build failed'}
  go run ./scripts/notices.go -core $asterDependency.Dir -engine-go "go$($asterLock.go)" -out .build/third-party
  if($LASTEXITCODE -ne 0){throw 'Third-party notices could not be collected'}
  Copy-Item -LiteralPath (Join-Path $asterBuild 'aster-bridge.exe'),(Join-Path $asterBuild 'aster-core.exe'),(Join-Path $asterRoot 'LICENSE'),(Join-Path $asterRoot 'NOTICE.md'),(Join-Path $asterRoot 'toolchain.json') -Destination $asterRelease
  Copy-Item -LiteralPath (Join-Path $asterRoot 'README.md') -Destination (Join-Path $asterRelease 'Readme.md')
  Copy-Item -LiteralPath (Join-Path $asterBuild 'third-party') -Destination $asterRelease -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $asterRoot 'docs') -Destination $asterRelease -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $asterRoot 'assets\OFL-NotoSansTC.txt') -Destination $asterRelease -Force
  Copy-Item -LiteralPath (Join-Path $asterRoot 'assets\opencc\LICENSE') -Destination (Join-Path $asterRelease 'LICENSE-OpenCC') -Force
  New-Item -ItemType Directory -Path (Join-Path $asterRoot 'dist') -Force | Out-Null
  Compress-Archive -Path "$asterRelease\*" -DestinationPath (Join-Path $asterRoot "dist\Aster-Desktop-$asterReleaseVersion-windows-x64-portable.zip") -Force
  if($Installer){
    $env:GOTOOLCHAIN="go$($asterLock.go)"
    & (Join-Path $PSScriptRoot 'package-windows.ps1') -ReleasePath $asterRelease
  }
  & (Join-Path $PSScriptRoot 'package-source.ps1') -CoreSource $asterDependency.Dir
  & (Join-Path $PSScriptRoot 'checksums.ps1')
} finally { Pop-Location }
