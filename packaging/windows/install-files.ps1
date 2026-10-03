# Windows PowerShell 5.1 compatible. The caller supplies a verified, protected ZIP.
function Assert-AsterInstallDirectory {
  param([string]$InstallPath)
  $asterFull=[IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
  if([IO.Path]::GetFileName($asterFull) -cne 'Aster Desktop'){throw 'Invalid installation directory'}
  $asterAncestor=$asterFull
  while($asterAncestor){
    if(Test-Path -LiteralPath $asterAncestor){
      $asterItem=Get-Item -LiteralPath $asterAncestor -Force
      if(!$asterItem.PSIsContainer -or ($asterItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){
        throw "Installation path is not a regular directory: $asterAncestor"
      }
    }
    $asterAncestor=[IO.Path]::GetDirectoryName($asterAncestor)
  }
  return $asterFull
}

function Remove-AsterInstallSibling {
  param([string]$InstallPath,[string]$SiblingPath)
  $asterFull=Assert-AsterInstallDirectory $InstallPath
  $asterSibling=[IO.Path]::GetFullPath($SiblingPath)
  $asterParent=[IO.Path]::GetDirectoryName($asterFull)
  if([IO.Path]::GetDirectoryName($asterSibling) -ne $asterParent -or
     [IO.Path]::GetFileName($asterSibling) -notmatch '^Aster Desktop\.(stage|backup|failed)-[0-9a-f]{32}$'){
    throw 'Invalid installer cleanup path'
  }
  if(Test-Path -LiteralPath $asterSibling){
    if((Get-Item -LiteralPath $asterSibling -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Installer cleanup path is a reparse point'}
    # Do not recurse through any link in an old installation. Keep the backup
    # rather than risking removal outside this explicitly bounded directory.
    $asterDirectories=[Collections.Generic.Stack[string]]::new()
    $asterDirectories.Push($asterSibling)
    while($asterDirectories.Count){
      foreach($asterChild in Get-ChildItem -LiteralPath $asterDirectories.Pop() -Force -ErrorAction Stop){
        if($asterChild.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Installer cleanup tree contains a reparse point'}
        if($asterChild.PSIsContainer){$asterDirectories.Push($asterChild.FullName)}
      }
    }
    Remove-Item -LiteralPath $asterSibling -Recurse -Force -ErrorAction Stop
  }
}

function Install-AsterPayload {
  param(
    [Parameter(Mandatory)][string]$ArchivePath,
    [Parameter(Mandatory)][string]$InstallPath,
    [scriptblock]$BeforeSwitch={},
    [scriptblock]$AfterSwitch={},
    [scriptblock]$BeforeRollback={},
    [scriptblock]$AfterRollback={}
  )
  $asterFull=Assert-AsterInstallDirectory $InstallPath
  $asterID=[Guid]::NewGuid().ToString('N')
  # Siblings are on the same volume; directory renames never merge old/new files.
  $asterStage="$asterFull.stage-$asterID"
  $asterBackup="$asterFull.backup-$asterID"
  $asterFailed="$asterFull.failed-$asterID"
  $asterOldMoved=$false
  $asterNewPlaced=$false
  $asterStopAttempted=$false
  try {
    New-Item -ItemType Directory -Path $asterStage -ErrorAction Stop | Out-Null
    if(Test-Path -LiteralPath $asterFull){Set-Acl -LiteralPath $asterStage -AclObject (Get-Acl -LiteralPath $asterFull) -ErrorAction Stop}
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # Extract to a fresh directory. Expand-Archive's failed-overwrite cleanup can
    # remove original files and hide the initiating error behind PathNotFound.
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath,$asterStage)
    foreach($asterName in 'aster_desktop.exe','aster-core.exe','aster-bridge.exe','LICENSE'){
      if(!(Test-Path -LiteralPath (Join-Path $asterStage $asterName) -PathType Leaf)){throw "Package is missing $asterName"}
    }
    $asterStopAttempted=$true
    & $BeforeSwitch
    # Recheck immediately before renaming any live installation.
    $null=Assert-AsterInstallDirectory $asterFull
    if(Test-Path -LiteralPath $asterFull){
      Rename-Item -LiteralPath $asterFull -NewName ([IO.Path]::GetFileName($asterBackup)) -ErrorAction Stop
      $asterOldMoved=$true
    }
    Rename-Item -LiteralPath $asterStage -NewName 'Aster Desktop' -ErrorAction Stop
    $asterNewPlaced=$true
    & $AfterSwitch
  } catch {
    $asterOriginal=$_.Exception.Message
    try {
      if($asterNewPlaced){
        & $BeforeRollback
        $null=Assert-AsterInstallDirectory $asterFull
        Rename-Item -LiteralPath $asterFull -NewName ([IO.Path]::GetFileName($asterFailed)) -ErrorAction Stop
      }
      if($asterOldMoved){Rename-Item -LiteralPath $asterBackup -NewName 'Aster Desktop' -ErrorAction Stop}
      if($asterStopAttempted){& $AfterRollback}
    } catch {
      throw "Installation failed: $asterOriginal`nRecovery also failed: $($_.Exception.Message)`nInstallation directory: $asterFull`nRecovery directory (if retained): $asterBackup"
    }
    throw "Installation failed; previous installation preserved: $asterOriginal"
  } finally {
    foreach($asterUnused in @($asterStage,$asterFailed)){
      try {Remove-AsterInstallSibling $asterFull $asterUnused} catch {Write-Warning "Temporary files retained at ${asterUnused}: $($_.Exception.Message)"}
    }
  }
  try {Remove-AsterInstallSibling $asterFull $asterBackup} catch {Write-Warning "Previous files retained at ${asterBackup}: $($_.Exception.Message)"}
}
