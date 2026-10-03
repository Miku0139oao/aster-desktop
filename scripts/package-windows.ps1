param([Parameter(Mandatory)][string]$ReleasePath,[string]$OutputPath)
$ErrorActionPreference='Stop'
$asterRoot=Split-Path -Parent $PSScriptRoot
$asterStage=Join-Path $asterRoot '.build\installer-stage'
$asterSource=Join-Path $asterRoot 'packaging\windows\setup'
$asterTarget=if($OutputPath){[IO.Path]::GetFullPath($OutputPath)}else{Join-Path $asterRoot 'dist\Aster-Desktop-0.1.2-windows-x64-setup.exe'}
New-Item -ItemType Directory -Path $asterStage -Force | Out-Null
Compress-Archive -Path "$ReleasePath\*" -DestinationPath (Join-Path $asterStage 'payload.zip') -Force
Copy-Item -LiteralPath (Join-Path $asterRoot 'packaging\windows\install.ps1'),(Join-Path $asterRoot 'packaging\windows\install-files.ps1') -Destination $asterStage
Copy-Item -LiteralPath (Join-Path $asterStage 'payload.zip'),(Join-Path $asterStage 'install.ps1'),(Join-Path $asterStage 'install-files.ps1') -Destination $asterSource -Force
Push-Location (Join-Path $asterRoot 'bridge')
try {
  go build -trimpath -ldflags '-H windowsgui -s -w' -o $asterTarget (Join-Path $asterSource 'main_windows.go')
  if($LASTEXITCODE -ne 0){throw 'Windows installer packaging failed'}
} finally {Pop-Location}
$asterVerify=Start-Process -FilePath $asterTarget -ArgumentList '--verify' -WindowStyle Hidden -Wait -PassThru
if($asterVerify.ExitCode -ne 0){throw 'Windows installer payload verification failed'}
Write-Output "Created $asterTarget"
