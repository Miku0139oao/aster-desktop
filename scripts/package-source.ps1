param(
  [Parameter(Mandatory)][string]$CoreSource,
  [string]$Version
)
$ErrorActionPreference='Stop'
$asterRoot=Split-Path -Parent $PSScriptRoot
Push-Location $asterRoot
try{
  if(!$Version){
    $manifest=Get-Content -Raw (Join-Path $asterRoot 'pubspec.yaml')
    $match=[regex]::Match($manifest,'(?m)^version:\s*([^+\s]+)\+\d+')
    if(!$match.Success){throw 'Could not read version from pubspec.yaml'}
    $Version=$match.Groups[1].Value
  }
  New-Item -ItemType Directory -Force -Path (Join-Path $asterRoot 'dist') | Out-Null
  $asterSourceList=Join-Path $asterRoot '.build\source-files.list'
  $asterFiles=git -c core.quotePath=false ls-files
  if($LASTEXITCODE -ne 0 -or !$asterFiles){throw 'Stage all source files in Git before packaging source'}
  [IO.File]::WriteAllLines($asterSourceList,[string[]]$asterFiles,[Text.UTF8Encoding]::new($false))
  tar.exe -a -cf "dist/Aster-Desktop-$Version-source.zip" -T $asterSourceList
  if($LASTEXITCODE -ne 0){throw 'Desktop source archive failed'}
  tar.exe -czf "dist/Aster-Desktop-$Version-source.tar.gz" -T $asterSourceList
  if($LASTEXITCODE -ne 0){throw 'Desktop source tar archive failed'}
  tar.exe -a -cf dist/Aster-Core-a9a33503-source.zip -C $CoreSource .
  if($LASTEXITCODE -ne 0){throw 'Core source archive failed'}
  tar.exe -czf dist/Aster-Core-a9a33503-source.tar.gz -C $CoreSource .
  if($LASTEXITCODE -ne 0){throw 'Core source tar archive failed'}
}finally{Pop-Location}
