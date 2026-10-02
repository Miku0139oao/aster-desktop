$ErrorActionPreference='Stop'
$asterPrincipal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$asterPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  $asterElevated=Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"') -WindowStyle Hidden -Wait -PassThru
  exit $asterElevated.ExitCode
}
$asterInstall=Join-Path $env:ProgramFiles 'Aster Desktop'
$asterExpected=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Aster Desktop'))
if([IO.Path]::GetFullPath($asterInstall) -ne $asterExpected){throw 'Invalid installation directory'}
$asterApp=Get-Process -Name aster_desktop -ErrorAction SilentlyContinue
if($asterApp){Add-Type -AssemblyName PresentationFramework;[System.Windows.MessageBox]::Show('Close Aster Desktop from its tray menu, then run this installer again.','Aster Desktop') | Out-Null;exit 1}
New-Item -ItemType Directory -Path $asterInstall -Force | Out-Null
$asterService=Get-Service -Name AsterDesktop -ErrorAction SilentlyContinue
if($asterService -and $asterService.Status -ne 'Stopped'){
  Stop-Service -Name AsterDesktop
  $asterService.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))
}
Expand-Archive -LiteralPath (Join-Path $PSScriptRoot 'payload.zip') -DestinationPath $asterInstall -Force
if($asterService){Start-Service -Name AsterDesktop}
$asterUninstall=Join-Path $asterInstall 'uninstall.ps1'
$asterRemoval=@'
$ErrorActionPreference='Stop'
$asterPrincipal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$asterPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  $asterElevated=Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"') -WindowStyle Hidden -Wait -PassThru
  exit $asterElevated.ExitCode
}
$asterTarget=Join-Path $env:ProgramFiles 'Aster Desktop'
$asterExpected=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Aster Desktop'))
if([IO.Path]::GetFullPath($asterTarget) -ne $asterExpected){throw 'Invalid uninstall directory'}
if(Get-Process -Name aster_desktop -ErrorAction SilentlyContinue){throw 'Close Aster Desktop from its tray menu before uninstalling'}
if(Get-Service AsterDesktop -ErrorAction SilentlyContinue){& (Join-Path $asterTarget 'aster-bridge.exe') --uninstall-service;if($LASTEXITCODE -ne 0){throw 'Background service could not be removed'}}
Remove-Item -LiteralPath 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AsterDesktop' -ErrorAction SilentlyContinue
$asterShortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Aster Desktop.lnk'
Remove-Item -LiteralPath $asterShortcut -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $asterTarget -Recurse -Force
'@
[IO.File]::WriteAllText($asterUninstall,$asterRemoval)
$asterShell=New-Object -ComObject WScript.Shell
$asterShortcut=$asterShell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Aster Desktop.lnk'))
$asterShortcut.TargetPath=Join-Path $asterInstall 'aster_desktop.exe';$asterShortcut.WorkingDirectory=$asterInstall;$asterShortcut.IconLocation=Join-Path $asterInstall 'aster_desktop.exe';$asterShortcut.Save()
$asterRegistry='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AsterDesktop'
New-Item -Path $asterRegistry -Force | Out-Null
New-ItemProperty -Path $asterRegistry -Name DisplayName -Value 'Aster Desktop' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $asterRegistry -Name DisplayVersion -Value '0.1.0' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $asterRegistry -Name UninstallString -Value ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$asterUninstall+'"') -PropertyType String -Force | Out-Null
New-ItemProperty -Path $asterRegistry -Name InstallLocation -Value $asterInstall -PropertyType String -Force | Out-Null
Add-Type -AssemblyName PresentationFramework
[System.Windows.MessageBox]::Show('Aster Desktop is installed. Open it from the Start menu. Your profiles stay in your user account.','Aster Desktop') | Out-Null
