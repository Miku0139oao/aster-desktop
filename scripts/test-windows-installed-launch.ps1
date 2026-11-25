param([Parameter(Mandatory)][string]$SetupPath)

$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){
  throw 'This test installs and uninstalls Aster Desktop. Run only on a disposable GitHub-hosted Windows runner.'
}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'The installer test requires an elevated Windows runner.'}
if(!(Test-Path -LiteralPath $SetupPath -PathType Leaf)){throw "Setup executable is missing: $SetupPath"}
$setup=(Resolve-Path -LiteralPath $SetupPath).Path
$programFiles=[Environment]::GetFolderPath('ProgramFiles')
$install=Join-Path $programFiles 'Aster Desktop'
$desktop=Join-Path $install 'aster_desktop.exe'
$bridge=Join-Path $install 'aster-bridge.exe'
$core=Join-Path $install 'aster-core.exe'
$uninstall=Join-Path $install 'uninstall.ps1'
$shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'Aster Desktop.lnk'
$registry='HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AsterDesktop'
$powershell=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
if((Test-Path -LiteralPath $install) -or (Test-Path -LiteralPath $registry) -or
   (Test-Path -LiteralPath $shortcut) -or (Get-Service AsterDesktop -ErrorAction SilentlyContinue) -or
   (Get-Process aster_desktop -ErrorAction SilentlyContinue)){
  throw 'Refusing to test over an existing Aster Desktop installation, window, or service.'
}

function Wait-ForCheck([string]$Description,[scriptblock]$Check,[int]$Seconds=20){
  $timer=[Diagnostics.Stopwatch]::StartNew()
  do {
    $value=& $Check
    if($value){return $value}
    Start-Sleep -Milliseconds 250
  } while($timer.Elapsed.TotalSeconds -lt $Seconds)
  throw "Timed out waiting for $Description"
}

function Invoke-InstallerCommand([string]$Label,[string]$Executable,[string[]]$Arguments){
  $out=Join-Path $scratch "$Label.stdout"
  $err=Join-Path $scratch "$Label.stderr"
  $command=Start-Process -FilePath $Executable -ArgumentList $Arguments -WorkingDirectory $scratch `
    -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
  try {
    if(!$command.WaitForExit(90000)){throw "$Label exceeded 90 seconds"}
    if($command.ExitCode -ne 0){throw "$Label failed with exit code $($command.ExitCode)"}
  } catch {
    Get-Content -LiteralPath $out,$err | Write-Host
    throw
  } finally {
    if(!$command.HasExited){$command.Kill()}
    $command.Dispose()
  }
}

function Find-MixedPort {
  for($i=0;$i -lt 32;$i++){
    # Windows can reserve different ephemeral ranges for TCP and UDP.
    $port=Get-Random -Minimum 24000 -Maximum 34000
    $endpoint=[Net.IPEndPoint]::new([Net.IPAddress]::Loopback,$port)
    $tcp=[Net.Sockets.TcpListener]::new($endpoint)
    $udp=[Net.Sockets.UdpClient]::new()
    $tcp.ExclusiveAddressUse=$true
    $udp.ExclusiveAddressUse=$true
    try {$udp.Client.Bind($endpoint);$tcp.Start();return $port}
    catch [Net.Sockets.SocketException] {}
    finally {$tcp.Stop();$udp.Dispose()}
  }
  throw 'No available test port for the TCP and UDP listeners'
}

function Assert-LoopbackForwarding([int]$MixedPort){
  $fixture=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
  $client=[Net.Sockets.TcpClient]::new()
  $accepted=$null
  try {
    $fixture.Start()
    $accept=$fixture.AcceptTcpClientAsync()
    $port=$fixture.LocalEndpoint.Port
    $client.Connect([Net.IPAddress]::Loopback,$MixedPort)
    $stream=$client.GetStream()
    $stream.ReadTimeout=10000
    $request=[Text.Encoding]::ASCII.GetBytes("GET http://127.0.0.1:$port/installer-check HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nConnection: close`r`n`r`n")
    $stream.Write($request,0,$request.Length)
    if(!$accept.Wait(10000)){throw 'The installed core did not forward the loopback request'}
    $accepted=$accept.GetAwaiter().GetResult()
    $target=$accepted.GetStream()
    $target.ReadTimeout=10000
    $reader=[IO.StreamReader]::new($target)
    if($reader.ReadLine() -notlike 'GET /installer-check HTTP/1.*'){throw 'The installed core forwarded an unexpected request'}
    while($reader.ReadLine()){}
    $body='aster-desktop-installer-check'
    $response=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$body")
    $target.Write($response,0,$response.Length)
    $accepted.Dispose()
    $reply=[IO.StreamReader]::new($stream)
    if($reply.ReadLine() -notlike 'HTTP/1.* 200 *'){throw 'The native application did not relay the loopback response'}
    while($reply.ReadLine()){}
    $result=[char[]]::new($body.Length)
    if($reply.ReadBlock($result,0,$result.Length) -ne $body.Length -or (-join $result) -ne $body){
      throw 'The installed core changed the loopback response body'
    }
  } finally {
    if($accepted){$accepted.Dispose()}
    $client.Dispose()
    $fixture.Stop()
  }
}

Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$temp=(Resolve-Path -LiteralPath $env:RUNNER_TEMP).Path
$scratch=Join-Path $temp ('aster-installed-launch-'+[Guid]::NewGuid().ToString('N'))
$appData=Join-Path $scratch 'AppData'
$profileDir=Join-Path $appData 'app.astercore\aster_desktop'
New-Item -ItemType Directory -Path $profileDir | Out-Null
$state=Join-Path $profileDir 'state.json'
$gui=$null
$uninstallArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$uninstall+'"'))
try {
  $mixedPort=Find-MixedPort
  $fixtureProfile=@{
    settings=@{language='en';theme='system';systemProxy=$false;tun=$false;mixedPort=$mixedPort;mode='rule'}
    activeId='ci';selections=@{}
    profiles=@(@{id='ci';name='Installed package test';content="proxies: []`nrules: ['MATCH,DIRECT']`n"})
  } | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($state,$fixtureProfile)
  Invoke-InstallerCommand 'Install' $setup @('--quiet')
  foreach($file in $desktop,$bridge,$core,$uninstall,$shortcut){
    if(!(Test-Path -LiteralPath $file -PathType Leaf)){throw "Installed file is missing: $file"}
  }
  $entry=Get-ItemProperty -LiteralPath $registry
  $version=[regex]::Match((Get-Content -Raw (Join-Path $PSScriptRoot '..\pubspec.yaml')),'(?m)^version:\s*([^+\s]+)\+').Groups[1].Value
  if(!$version -or $entry.InstallLocation -ne $install -or $entry.DisplayVersion -cne $version -or
     $entry.UninstallString -ne ('powershell.exe '+($uninstallArgs -join ' '))){throw 'Uninstall registration does not match the installed package'}
  $shell=New-Object -ComObject WScript.Shell
  $link=$shell.CreateShortcut($shortcut)
  if($link.TargetPath -ne $desktop -or $link.WorkingDirectory -ne $install){throw 'Start menu shortcut does not target the installed app'}

  # Launch from a different working directory so the app must locate the
  # bridge and core relative to its own installed executable.
  $savedAppData=$env:APPDATA
  try {
    $env:APPDATA=$appData
    $gui=Start-Process -FilePath $link.TargetPath -ArgumentList '--autostart' -WorkingDirectory $scratch -PassThru `
      -RedirectStandardOutput (Join-Path $scratch 'gui.stdout') -RedirectStandardError (Join-Path $scratch 'gui.stderr')
  } finally {$env:APPDATA=$savedAppData}
  $hwnd=Wait-ForCheck 'the installed MyGo window' {
    $gui.Refresh()
    if($gui.HasExited){throw "The installed application exited with code $($gui.ExitCode) before opening a window"}
    if($gui.MainWindowTitle -eq 'Aster Desktop'){$gui.MainWindowHandle}
  }
  $bridgeProcess=Wait-ForCheck 'the app to spawn its installed bridge' {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($gui.Id) AND Name='aster-bridge.exe'" |
      Where-Object ExecutablePath -eq $bridge | Select-Object -First 1
  }
  $coreProcess=Wait-ForCheck 'the bridge to spawn its installed core' {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($bridgeProcess.ProcessId) AND Name='aster-core.exe'" |
      Where-Object ExecutablePath -eq $core | Select-Object -First 1
  }
  $null=Wait-ForCheck 'the core to listen on the configured loopback port' {
    Get-NetTCPConnection -State Listen -LocalAddress 127.0.0.1 -LocalPort $mixedPort -OwningProcess $coreProcess.ProcessId -ErrorAction SilentlyContinue
  }
  Assert-LoopbackForwarding $mixedPort
  Write-Output 'PASS: Setup installed the native GUI, Start menu entry and registry metadata. The installed core forwarded a local HTTP request.'

  $window=[Windows.Automation.AutomationElement]::FromHandle($hwnd)
  $byName=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Quit and stop proxy')
  $byType=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button)
  $quitCondition=[Windows.Automation.AndCondition]::new($byName,$byType)
  $quitButton=Wait-ForCheck 'the native Quit button' {$window.FindFirst([Windows.Automation.TreeScope]::Descendants,$quitCondition)}
  $quitButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
  if(!$gui.WaitForExit(30000) -or $gui.ExitCode -ne 0){throw 'The installed application did not exit successfully from its Quit button'}
  $null=Wait-ForCheck 'the installed bridge and core to stop' {
    !(Get-Process -Id $bridgeProcess.ProcessId,$coreProcess.ProcessId -ErrorAction SilentlyContinue)
  }

  # Exercise the real uninstaller with the optional background service present.
  Invoke-InstallerCommand 'InstallService' $bridge @('--install-service','--owner',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
  $service=Get-Service AsterDesktop
  try {$service.WaitForStatus('Running',[TimeSpan]::FromSeconds(20))}finally{$service.Dispose()}
  $beforeUninstall=Get-FileHash -LiteralPath $state
  Invoke-InstallerCommand 'Uninstall' $powershell $uninstallArgs
  $null=Wait-ForCheck 'removal of the Aster Desktop service' {!(Get-Service AsterDesktop -ErrorAction SilentlyContinue)}
  foreach($path in $install,$shortcut,$registry){
    if(Test-Path -LiteralPath $path){throw "Uninstall did not remove $path"}
  }
  if((Get-FileHash -LiteralPath $state).Hash -ne $beforeUninstall.Hash){throw 'Uninstall changed the retained user profile'}
  Write-Output 'PASS: Native Quit stopped the engine. Uninstall removed the app, shortcut, registry entry and service and preserved the user profile.'
} catch {
  Get-ChildItem -LiteralPath $scratch -Filter 'gui.std*' | Get-Content | Write-Host
  throw
} finally {
  if($gui){
    if(!$gui.HasExited){$gui.Kill();$null=$gui.WaitForExit(10000)}
    $gui.Dispose()
  }
  if(Test-Path -LiteralPath $uninstall){
    try {Invoke-InstallerCommand 'Cleanup' $powershell $uninstallArgs} catch {Write-Warning $_.Exception.Message}
  }
  $cleanup=(Resolve-Path -LiteralPath $scratch).Path
  if((Split-Path -Parent $cleanup) -ne $temp -or (Split-Path -Leaf $cleanup) -notmatch '^aster-installed-launch-[0-9a-f]{32}$'){
    throw "Unexpected installer test cleanup path: $cleanup"
  }
  Remove-Item -LiteralPath $cleanup -Recurse -Force
}
