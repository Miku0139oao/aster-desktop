param(
  [Parameter(Mandatory)][string]$PayloadPath,
  [string]$PreviousArchivePath
)
$ErrorActionPreference='Stop'
$asterRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path $asterRoot 'packaging\windows\install-files.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$asterTests=Join-Path $asterRoot ('.build\installer-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $asterTests | Out-Null
function Assert-InstallerTest([bool]$Condition,[string]$Message){if(!$Condition){throw $Message}}
function New-InstallerCase([string]$Name){
  $asterCase=Join-Path $asterTests $Name
  New-Item -ItemType Directory -Path $asterCase | Out-Null
  return (Join-Path $asterCase 'Aster Desktop')
}
function Assert-PayloadMatches([string]$Path,[string]$Archive){
  $asterZip=[IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    $asterCount=0
    foreach($asterEntry in $asterZip.Entries){
      # Windows PowerShell Compress-Archive can use backslashes for empty
      # directories. Verify files only, regardless of the ZIP separator.
      if($asterEntry.FullName.EndsWith('/') -or $asterEntry.FullName.EndsWith('\')){continue}
      $asterFile=Join-Path $Path $asterEntry.FullName
      Assert-InstallerTest (Test-Path -LiteralPath $asterFile -PathType Leaf) "Missing $($asterEntry.FullName)"
      $asterStream=$asterEntry.Open()
      $asterSHA=[Security.Cryptography.SHA256]::Create()
      try {$asterExpected=[BitConverter]::ToString($asterSHA.ComputeHash($asterStream)).Replace('-','')}finally{$asterStream.Dispose();$asterSHA.Dispose()}
      Assert-InstallerTest ((Get-FileHash -LiteralPath $asterFile -Algorithm SHA256).Hash -eq $asterExpected) "Hash mismatch $($asterEntry.FullName)"
      $asterCount++
    }
    Assert-InstallerTest (@(Get-ChildItem -LiteralPath $Path -File -Recurse -Force).Count -eq $asterCount) 'Mixed old/new installation files'
  } finally {$asterZip.Dispose()}
}
function Assert-NoInstallSiblings([string]$Path){
  Assert-InstallerTest (@(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Directory | Where-Object Name -like 'Aster Desktop.*').Count -eq 0) 'Installer temporary directories leaked'
}
function Assert-ExpectedFailure([scriptblock]$Action,[string]$Expected){
  $asterFailure=$null
  try {& $Action} catch {$asterFailure=$_.Exception.Message}
  Assert-InstallerTest ($asterFailure -and $asterFailure.Contains($Expected)) "Expected '$Expected', got '$asterFailure'"
}
try {
  $asterFresh=New-InstallerCase 'fresh'
  Install-AsterPayload -ArchivePath $PayloadPath -InstallPath $asterFresh
  Assert-PayloadMatches $asterFresh $PayloadPath
  Assert-NoInstallSiblings $asterFresh
  Write-Output 'PASS: full payload fresh install, every file SHA-256 matched'

  $asterUpgrade=New-InstallerCase 'upgrade'
  if($PreviousArchivePath){[IO.Compression.ZipFile]::ExtractToDirectory($PreviousArchivePath,$asterUpgrade)}
  else {New-Item -ItemType Directory -Path $asterUpgrade | Out-Null}
  [IO.File]::WriteAllText((Join-Path $asterUpgrade 'old-only.txt'),'old version')
  $asterProtectedACL=Get-Acl -LiteralPath $asterUpgrade
  $asterProtectedACL.SetAccessRuleProtection($true,$true)
  Set-Acl -LiteralPath $asterUpgrade -AclObject $asterProtectedACL
  $asterOldACL=(Get-Acl -LiteralPath $asterUpgrade).Sddl
  Install-AsterPayload -ArchivePath $PayloadPath -InstallPath $asterUpgrade
  Assert-PayloadMatches $asterUpgrade $PayloadPath
  Assert-InstallerTest ((Get-Acl -LiteralPath $asterUpgrade).Sddl -eq $asterOldACL) 'Existing installation ACL changed'
  Assert-NoInstallSiblings $asterUpgrade
  Write-Output 'PASS: full payload upgrade, stale files removed, ACL retained'

  $asterPartial=New-InstallerCase 'partial-old-install'
  New-Item -ItemType Directory -Path $asterPartial | Out-Null
  [IO.File]::WriteAllText((Join-Path $asterPartial 'aster_desktop.exe'),'incomplete old installation')
  Install-AsterPayload -ArchivePath $PayloadPath -InstallPath $asterPartial
  Assert-PayloadMatches $asterPartial $PayloadPath
  Assert-NoInstallSiblings $asterPartial
  Write-Output 'PASS: repairs incomplete old installation using complete payload'

  $asterFixture=Join-Path $asterTests 'fixture'
  New-Item -ItemType Directory -Path $asterFixture | Out-Null
  foreach($asterName in 'aster_desktop.exe','aster-core.exe','aster-bridge.exe','LICENSE'){
    [IO.File]::WriteAllText((Join-Path $asterFixture $asterName),'new version')
  }
  $asterFixtureZip=Join-Path $asterTests 'fixture.zip'
  [IO.Compression.ZipFile]::CreateFromDirectory($asterFixture,$asterFixtureZip)
  $asterRollback=New-InstallerCase 'rollback'
  New-Item -ItemType Directory -Path $asterRollback | Out-Null
  [IO.File]::WriteAllText((Join-Path $asterRollback 'LICENSE'),'old version')
  $asterCallbacks=[Collections.Generic.List[string]]::new()
  Assert-ExpectedFailure {
    Install-AsterPayload -ArchivePath $asterFixtureZip -InstallPath $asterRollback `
      -BeforeSwitch {$asterCallbacks.Add('stop-old')} `
      -AfterSwitch {$asterCallbacks.Add('start-new');throw 'new service failed'} `
      -BeforeRollback {$asterCallbacks.Add('stop-new')} -AfterRollback {$asterCallbacks.Add('start-old')}
  } 'new service failed'
  Assert-InstallerTest ([IO.File]::ReadAllText((Join-Path $asterRollback 'LICENSE')) -eq 'old version') 'Rollback lost previous files'
  Assert-InstallerTest (($asterCallbacks -join ',') -eq 'stop-old,start-new,stop-new,start-old') 'Service recovery callbacks out of order'
  Assert-NoInstallSiblings $asterRollback
  Write-Output 'PASS: new service startup failure restores old files and restarts old service callback'

  Assert-ExpectedFailure {
    Install-AsterPayload -ArchivePath $asterFixtureZip -InstallPath $asterRollback -BeforeSwitch {throw 'service did not stop'}
  } 'service did not stop'
  Assert-InstallerTest ([IO.File]::ReadAllText((Join-Path $asterRollback 'LICENSE')) -eq 'old version') 'Stop failure changed old files'
  Assert-NoInstallSiblings $asterRollback
  Write-Output 'PASS: service stop failure preserves old files'

  # An open file denies overwrite/deletion. A directory switch may still succeed;
  # in that case the locked old tree must be retained rather than merged/deleted.
  $asterLock=[IO.File]::Open((Join-Path $asterRollback 'LICENSE'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
  $asterLockFailure=$null
  try {
    try {Install-AsterPayload -ArchivePath $asterFixtureZip -InstallPath $asterRollback} catch {$asterLockFailure=$_.Exception.Message}
    if($asterLockFailure){Assert-InstallerTest ($asterLockFailure.Contains('previous installation preserved')) 'Locked-file error did not preserve installation'}
    else {Assert-PayloadMatches $asterRollback $asterFixtureZip}
  } finally {$asterLock.Dispose()}
  if($asterLockFailure){Assert-InstallerTest ([IO.File]::ReadAllText((Join-Path $asterRollback 'LICENSE')) -eq 'old version') 'Locked file damaged old installation'}
  else {
    $asterLockedBackup=@(Get-ChildItem -LiteralPath (Split-Path -Parent $asterRollback) -Directory | Where-Object Name -like 'Aster Desktop.backup-*')
    Assert-InstallerTest ($asterLockedBackup.Count -eq 1) 'Locked old file backup was lost'
    Assert-InstallerTest ([IO.File]::ReadAllText((Join-Path $asterLockedBackup[0].FullName 'LICENSE')) -eq 'old version') 'Locked old file contents changed'
    Remove-AsterInstallSibling $asterRollback $asterLockedBackup[0].FullName
    # Restore the old fixture used by the following extraction-error test.
    [IO.File]::WriteAllText((Join-Path $asterRollback 'LICENSE'),'old version')
  }
  Assert-NoInstallSiblings $asterRollback
  Write-Output 'PASS: real Windows file lock keeps original contents; no in-place overwrite'

  $asterCorrupt=Join-Path $asterTests 'corrupt.zip'
  [IO.File]::WriteAllText($asterCorrupt,'not a ZIP')
  Assert-ExpectedFailure {Install-AsterPayload -ArchivePath $asterCorrupt -InstallPath $asterRollback} 'Installation failed; previous installation preserved'
  Assert-InstallerTest ([IO.File]::ReadAllText((Join-Path $asterRollback 'LICENSE')) -eq 'old version') 'Extraction failure changed old files'
  Assert-NoInstallSiblings $asterRollback
  Write-Output 'PASS: extraction failure preserves old files and exposes original error'

  $asterRecovery=New-InstallerCase 'failed-recovery'
  New-Item -ItemType Directory -Path $asterRecovery | Out-Null
  [IO.File]::WriteAllText((Join-Path $asterRecovery 'LICENSE'),'recovery copy')
  Assert-ExpectedFailure {
    Install-AsterPayload -ArchivePath $asterFixtureZip -InstallPath $asterRecovery `
      -AfterSwitch {throw 'start failed'} -BeforeRollback {throw 'cannot stop new service'}
  } 'Recovery also failed: cannot stop new service'
  $asterRecoveryBackup=@(Get-ChildItem -LiteralPath (Split-Path -Parent $asterRecovery) -Directory | Where-Object Name -like 'Aster Desktop.backup-*')
  Assert-InstallerTest ($asterRecoveryBackup.Count -eq 1) 'Failed recovery deleted backup'
  Assert-InstallerTest ([IO.File]::ReadAllText((Join-Path $asterRecoveryBackup[0].FullName 'LICENSE')) -eq 'recovery copy') 'Failed recovery damaged backup'
  Write-Output 'PASS: failed recovery retains original backup and reports both errors'

  Assert-ExpectedFailure {Remove-AsterInstallSibling $asterRollback $asterTests} 'Invalid installer cleanup path'
  Assert-ExpectedFailure {Install-AsterPayload -ArchivePath $asterFixtureZip -InstallPath (Join-Path $asterTests 'wrong-directory')} 'Invalid installation directory'
  $asterJunction=Join-Path $asterTests 'junction'
  New-Item -ItemType Junction -Path $asterJunction -Target $asterFixture | Out-Null
  try {
    Assert-ExpectedFailure {Install-AsterPayload -ArchivePath $asterFixtureZip -InstallPath (Join-Path $asterJunction 'Aster Desktop')} 'not a regular directory'
  } finally {[IO.Directory]::Delete($asterJunction)}
  $asterLinkedBackup=Join-Path (Split-Path -Parent $asterRollback) ('Aster Desktop.backup-'+[Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $asterLinkedBackup | Out-Null
  $asterChildJunction=Join-Path $asterLinkedBackup 'linked-child'
  New-Item -ItemType Junction -Path $asterChildJunction -Target $asterFixture | Out-Null
  try {
    Assert-ExpectedFailure {Remove-AsterInstallSibling $asterRollback $asterLinkedBackup} 'cleanup tree contains a reparse point'
    Assert-InstallerTest (Test-Path -LiteralPath (Join-Path $asterFixture 'LICENSE')) 'Cleanup followed a child junction'
  } finally {[IO.Directory]::Delete($asterChildJunction)}
  Remove-AsterInstallSibling $asterRollback $asterLinkedBackup
  Write-Output 'PASS: unsafe cleanup, destination and junction rejected'
} finally {
  # Delete only this run's disposable fixture root inside the workspace.
  $asterAllowed=[IO.Path]::GetFullPath((Join-Path $asterRoot '.build'))+'\'
  $asterFull=[IO.Path]::GetFullPath($asterTests)
  if(!$asterFull.StartsWith($asterAllowed,[StringComparison]::OrdinalIgnoreCase) -or
     [IO.Path]::GetFileName($asterFull) -notmatch '^installer-tests-[0-9a-f]{32}$'){throw 'Unsafe fixture cleanup path'}
  Remove-Item -LiteralPath $asterFull -Recurse -Force
}
