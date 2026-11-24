param([Parameter(Mandatory)][string]$ReleasePath,[string]$OutputPath)
$ErrorActionPreference='Stop'
$asterRoot=Split-Path -Parent $PSScriptRoot
$asterManifest=Get-Content -Raw (Join-Path $asterRoot 'pubspec.yaml')
$asterReleaseMatch=[regex]::Match($asterManifest,'(?m)^version:\s*([^+\s]+)\+\d+')
if(!$asterReleaseMatch.Success){throw 'Could not read version from pubspec.yaml'}
$asterReleaseVersion=$asterReleaseMatch.Groups[1].Value
$asterStage=Join-Path $asterRoot '.build\installer-stage'
$asterSource=Join-Path $asterRoot 'packaging\windows\setup'
$asterTarget=if($OutputPath){[IO.Path]::GetFullPath($OutputPath)}else{Join-Path $asterRoot "dist\Aster-Desktop-$asterReleaseVersion-windows-x64-setup.exe"}
New-Item -ItemType Directory -Path $asterStage -Force | Out-Null
Compress-Archive -Path "$ReleasePath\*" -DestinationPath (Join-Path $asterStage 'payload.zip') -Force
Copy-Item -LiteralPath (Join-Path $asterRoot 'packaging\windows\install.ps1'),(Join-Path $asterRoot 'packaging\windows\install-files.ps1') -Destination $asterStage
$asterCompile=Join-Path $asterRoot 'bridge\.build\setup'
New-Item -ItemType Directory -Path $asterCompile -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $asterStage 'payload.zip'),(Join-Path $asterStage 'install.ps1'),(Join-Path $asterStage 'install-files.ps1'),(Join-Path $asterSource 'main_windows.go') -Destination $asterCompile -Force
$asterInstaller=Join-Path $asterCompile 'install.ps1'
$asterInstallerText=[IO.File]::ReadAllText($asterInstaller)
if(!$asterInstallerText.Contains('#ASTER_VERSION')){throw 'install.ps1 has no #ASTER_VERSION placeholder'}
[IO.File]::WriteAllText($asterInstaller,$asterInstallerText.Replace('#ASTER_VERSION',$asterReleaseVersion))
$asterLock=Get-Content (Join-Path $asterRoot 'toolchain.json') -Raw | ConvertFrom-Json
$asterIcon=Join-Path $asterRoot 'assets\aster.ico'
go run "github.com/akavel/rsrc@$($asterLock.windowsResourceTool)" -arch amd64 -ico $asterIcon -o (Join-Path $asterCompile 'icon.syso')
if($LASTEXITCODE -ne 0){throw 'Installer icon resource generation failed'}
Push-Location (Join-Path $asterRoot 'bridge')
try {
  go build -tags aster_installer -trimpath -ldflags '-H windowsgui -s -w' -o $asterTarget ./.build/setup
  if($LASTEXITCODE -ne 0){throw 'Windows installer packaging failed'}
} finally {Pop-Location}
$asterVerify=Start-Process -FilePath $asterTarget -ArgumentList '--verify' -WindowStyle Hidden -Wait -PassThru
if($asterVerify.ExitCode -ne 0){throw 'Windows installer payload verification failed'}
Write-Output "Created $asterTarget"
