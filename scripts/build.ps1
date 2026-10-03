param([string]$Flutter='flutter',[string]$VCRedist='',[switch]$SkipFlutter,[switch]$Installer)
$ErrorActionPreference='Stop'
$asterRoot=Split-Path -Parent $PSScriptRoot
$asterBuild=Join-Path $asterRoot '.build'
$asterLock=Get-Content (Join-Path $asterRoot 'toolchain.json') -Raw | ConvertFrom-Json
$env:GOTOOLCHAIN="go$($asterLock.go)"
New-Item -ItemType Directory -Path $asterBuild -Force | Out-Null
Push-Location (Join-Path $asterRoot 'bridge')
try {
  $env:CGO_ENABLED='0'
  $asterDependency=go mod download -json "$($asterLock.coreModule)@$($asterLock.coreVersion)" | ConvertFrom-Json
  if($LASTEXITCODE -ne 0){throw 'Could not obtain the pinned core source'}
  go build -trimpath -o (Join-Path $asterBuild 'aster-bridge.exe') ./cmd/aster-bridge
  if($LASTEXITCODE -ne 0){throw 'Desktop engine build failed'}
  Push-Location $asterDependency.Dir
  try {
    go build -mod=readonly -tags with_gvisor -trimpath -ldflags "-s -w -X github.com/Miku0139oao/aster-core/constant.Version=alpha-main-a9a3350 -X github.com/Miku0139oao/aster-core/constant.ReleaseAsset=aster-core-windows-amd64-v1" -o (Join-Path $asterBuild 'aster-core.exe') .
    if($LASTEXITCODE -ne 0){throw 'Pinned core build failed'}
  } finally { Pop-Location }
} finally { Pop-Location }
Push-Location $asterRoot
try {
  go run ./scripts/notices.go -core $asterDependency.Dir -out .build/third-party
  if($LASTEXITCODE -ne 0){throw 'Third-party notices could not be collected'}
  if(!$SkipFlutter){
    $asterVersion=& $Flutter --version --machine | ConvertFrom-Json
    if($asterVersion.frameworkVersion -ne $asterLock.flutter){throw "Use Flutter $($asterLock.flutter)"}
    & $Flutter pub get --enforce-lockfile
    if($LASTEXITCODE -ne 0){throw 'Flutter dependencies could not be resolved'}
    & $Flutter build windows --release
    if($LASTEXITCODE -ne 0){throw 'Windows GUI build failed'}
  }
  $asterRelease=Join-Path $asterRoot 'build\windows\x64\runner\Release'
  if(!$VCRedist){
    $asterVSWhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if(!(Test-Path -LiteralPath $asterVSWhere)){$asterVSWhere='D:\DevTools\VisualStudio\Installer\vswhere.exe'}
    if(Test-Path -LiteralPath $asterVSWhere){
      $asterVS=& $asterVSWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
      $asterCRT=Get-ChildItem -Path (Join-Path $asterVS 'VC\Redist\MSVC\*\x64\Microsoft.VC143.CRT') -Directory | Sort-Object FullName -Descending | Select-Object -First 1
      if($asterCRT){$VCRedist=$asterCRT.FullName}
    }
  }
  if(!$VCRedist -or !(Test-Path -LiteralPath $VCRedist)){throw 'Pass -VCRedist with the Visual Studio x64 Microsoft.VC143.CRT directory'}
  Copy-Item -Path (Join-Path $VCRedist '*.dll') -Destination $asterRelease -Force
  Copy-Item -LiteralPath (Join-Path $asterBuild 'aster-bridge.exe'),(Join-Path $asterBuild 'aster-core.exe'),(Join-Path $asterRoot 'LICENSE'),(Join-Path $asterRoot 'NOTICE.md'),(Join-Path $asterRoot 'toolchain.json') -Destination $asterRelease
  Copy-Item -LiteralPath (Join-Path $asterRoot 'README.md') -Destination (Join-Path $asterRelease 'Readme.md')
  Copy-Item -LiteralPath (Join-Path $asterBuild 'third-party') -Destination $asterRelease -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $asterRoot 'docs') -Destination $asterRelease -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $asterRoot 'assets\OFL-NotoSansTC.txt') -Destination $asterRelease
  New-Item -ItemType Directory -Path (Join-Path $asterRoot 'dist') -Force | Out-Null
  Compress-Archive -Path "$asterRelease\*" -DestinationPath (Join-Path $asterRoot 'dist\Aster-Desktop-0.1.3-windows-x64-portable.zip') -Force
  if($Installer){& (Join-Path $PSScriptRoot 'package-windows.ps1') -ReleasePath $asterRelease}
  & (Join-Path $PSScriptRoot 'package-source.ps1') -CoreSource $asterDependency.Dir
  & (Join-Path $PSScriptRoot 'checksums.ps1')
} finally { Pop-Location }
