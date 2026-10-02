param([Parameter(Mandatory)][string]$CoreSource)
$ErrorActionPreference='Stop'
$asterRoot=Split-Path -Parent $PSScriptRoot
Push-Location $asterRoot
try{
  $asterSourceList=Join-Path $asterRoot '.build\source-files.txt'
  $asterFiles=git -c core.quotePath=false ls-files
  if($LASTEXITCODE -ne 0 -or !$asterFiles){throw 'Stage all source files in Git before packaging source'}
  [IO.File]::WriteAllLines($asterSourceList,[string[]]$asterFiles,[Text.UTF8Encoding]::new($false))
  tar.exe -a -cf dist/Aster-Desktop-0.1.1-source.zip -T $asterSourceList
  if($LASTEXITCODE -ne 0){throw 'Desktop source archive failed'}
  tar.exe -a -cf dist/Aster-Core-a9a33503-source.zip -C $CoreSource .
  if($LASTEXITCODE -ne 0){throw 'Core source archive failed'}
}finally{Pop-Location}
