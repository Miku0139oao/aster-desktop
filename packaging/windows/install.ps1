$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
try {
$asterPrincipal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$asterPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
  $asterElevated=Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"') -WindowStyle Hidden -Wait -PassThru
  exit $asterElevated.ExitCode
}
$asterInstall=Join-Path $env:ProgramFiles 'Aster Desktop'
$asterExpected=[IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'Aster Desktop'))
if([IO.Path]::GetFullPath($asterInstall) -ne $asterExpected){throw 'Invalid installation directory'}
$asterApp=Get-Process -Name aster_desktop -ErrorAction SilentlyContinue
if($asterApp){throw 'Please exit Aster Desktop from its tray menu, then run this installer again.'}
. (Join-Path $PSScriptRoot 'install-files.ps1')
$asterService=Get-Service -Name AsterDesktop -ErrorAction SilentlyContinue
$asterWasRunning=$asterService -and $asterService.Status -ne 'Stopped'
function Stop-AsterInstallerService {
  $asterCurrent=Get-Service -Name AsterDesktop -ErrorAction SilentlyContinue
  if(!$asterCurrent){return}
  $asterSCM=Get-CimInstance Win32_Service -Filter "Name='AsterDesktop'"
  $asterProcess=if($asterSCM.ProcessId){Get-Process -Id $asterSCM.ProcessId -ErrorAction SilentlyContinue}
  if($asterCurrent.Status -ne 'Stopped'){
    Stop-Service -Name AsterDesktop -ErrorAction Stop
    $asterCurrent.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))
  }
  # SCM may report Stopped just before the executable releases its handles.
  if($asterProcess -and !$asterProcess.WaitForExit(30000)){throw 'Background service process did not exit within 30 seconds; previous files are preserved.'}
}
function Start-AsterInstallerService {
  if(!$asterWasRunning){return}
  Start-Service -Name AsterDesktop -ErrorAction Stop
  (Get-Service -Name AsterDesktop).WaitForStatus('Running',[TimeSpan]::FromSeconds(30))
}
Install-AsterPayload -ArchivePath (Join-Path $PSScriptRoot 'payload.zip') -InstallPath $asterInstall `
  -BeforeSwitch {Stop-AsterInstallerService} -AfterSwitch {Start-AsterInstallerService} `
  -BeforeRollback {Stop-AsterInstallerService} -AfterRollback {Start-AsterInstallerService}
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
New-ItemProperty -Path $asterRegistry -Name DisplayVersion -Value '0.1.3' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $asterRegistry -Name UninstallString -Value ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+$asterUninstall+'"') -PropertyType String -Force | Out-Null
New-ItemProperty -Path $asterRegistry -Name InstallLocation -Value $asterInstall -PropertyType String -Force | Out-Null
Add-Type -AssemblyName PresentationFramework
[System.Windows.MessageBox]::Show('Aster Desktop is installed. Open it from the Start menu. Your profiles stay in your user account.','Aster Desktop') | Out-Null
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
