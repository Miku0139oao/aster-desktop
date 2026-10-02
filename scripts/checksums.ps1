$asterRoot=Split-Path -Parent $PSScriptRoot
$asterLines=Get-ChildItem -LiteralPath (Join-Path $asterRoot 'dist') -File | Where-Object Name -ne 'checksums.txt' | Sort-Object Name | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),$_.Name }
[IO.File]::WriteAllLines((Join-Path $asterRoot 'dist\checksums.txt'),[string[]]$asterLines)
