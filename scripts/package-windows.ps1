param([Parameter(Mandatory)][string]$ReleasePath,[string]$OutputPath)
$ErrorActionPreference='Stop'
$asterRoot=Split-Path -Parent $PSScriptRoot
$asterStage=Join-Path $asterRoot '.build\installer-stage'
$asterSource=Join-Path $asterRoot 'packaging\windows\setup'
$asterTarget=if($OutputPath){[IO.Path]::GetFullPath($OutputPath)}else{Join-Path $asterRoot 'dist\Aster-Desktop-0.2.0-windows-x64-setup.exe'}
New-Item -ItemType Directory -Path $asterStage -Force | Out-Null
Compress-Archive -Path "$ReleasePath\*" -DestinationPath (Join-Path $asterStage 'payload.zip') -Force
Copy-Item -LiteralPath (Join-Path $asterRoot 'packaging\windows\install.ps1'),(Join-Path $asterRoot 'packaging\windows\install-files.ps1') -Destination $asterStage
$asterCompile=Join-Path $asterRoot 'bridge\.build\setup'
New-Item -ItemType Directory -Path $asterCompile -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $asterStage 'payload.zip'),(Join-Path $asterStage 'install.ps1'),(Join-Path $asterStage 'install-files.ps1'),(Join-Path $asterSource 'main_windows.go') -Destination $asterCompile -Force
$asterVSWhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$asterVS=& $asterVSWhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$asterCvt=Get-ChildItem -Path (Join-Path $asterVS 'VC\Tools\MSVC\*\bin\Hostx64\x64\cvtres.exe') -File | Sort-Object FullName -Descending | Select-Object -First 1
$asterRc=Get-ChildItem -Path (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin\*\x64\rc.exe') -File | Sort-Object FullName -Descending | Select-Object -First 1
if(!$asterCvt -or !$asterRc){throw 'Visual Studio and Windows SDK resource tools are required for the Aster installer icon'}
$asterIcon=(Join-Path $asterRoot 'assets\aster.ico').Replace('\','/')
Set-Content -LiteralPath (Join-Path $asterCompile 'icon.rc') -Value ('1 ICON "'+$asterIcon+'"') -Encoding ascii
& $asterRc.FullName /nologo /fo (Join-Path $asterCompile 'icon.res') (Join-Path $asterCompile 'icon.rc')
if($LASTEXITCODE -ne 0){throw 'Installer icon resource compilation failed'}
& $asterCvt.FullName /NOLOGO /MACHINE:X64 "/OUT:$(Join-Path $asterCompile 'icon.syso')" (Join-Path $asterCompile 'icon.res')
if($LASTEXITCODE -ne 0){throw 'Installer icon resource conversion failed'}
Push-Location (Join-Path $asterRoot 'bridge')
try {
  go build -trimpath -ldflags '-H windowsgui -s -w' -o $asterTarget ./.build/setup
  if($LASTEXITCODE -ne 0){throw 'Windows installer packaging failed'}
} finally {Pop-Location}
$asterVerify=Start-Process -FilePath $asterTarget -ArgumentList '--verify' -WindowStyle Hidden -Wait -PassThru
if($asterVerify.ExitCode -ne 0){throw 'Windows installer payload verification failed'}
Write-Output "Created $asterTarget"
