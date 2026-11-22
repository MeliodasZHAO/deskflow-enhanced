# SPDX-FileCopyrightText: (C) 2026 Deskflow Enhanced contributors
# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP) { throw 'Use only in the disposable Windows runner.' }
$testStart = Get-Date
$temp = Join-Path $env:RUNNER_TEMP 'preview-first-run'
$installDir = Join-Path $temp 'Deskflow Enhanced'
$null = New-Item -ItemType Directory $temp
$setup = Join-Path $temp 'preview-setup.exe'
$release = 'https://github.com/MeliodasZHAO/deskflow-enhanced/releases/download/v1.27.0.17-preview'
Invoke-WebRequest -UseBasicParsing "$release/Deskflow-Enhanced-1.27.0.17-Windows-x64-Setup.exe" -OutFile $setup
if ((Get-FileHash $setup).Hash -ne 'b881ed2e45dd5aed08640a7a9683c155bf88d766dd881ebb4f013d8843f3abea') {
  throw 'Published artifact hash mismatch.'
}
$install = Start-Process $setup -ArgumentList "/S /D=$installDir" -Wait -PassThru
if ($install.ExitCode) { throw "Install failed $($install.ExitCode)" }
$exe = Join-Path $installDir 'deskflow-candidate-core.exe'
$profile = Join-Path $env:USERPROFILE 'AppData/Roaming/DeskflowCandidate'
if (Test-Path $profile) { throw 'Expected a clean Windows profile.' }

function Invoke-CoreToExit($mode) {
  $stdout = Join-Path $temp "$mode.out.log"
  $stderr = Join-Path $temp "$mode.err.log"
  $core = Start-Process $exe -ArgumentList $mode -WorkingDirectory $installDir -Wait -PassThru `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  Write-Host "$mode exit code $($core.ExitCode)"
  Get-Content $stdout, $stderr | Write-Host
  return $core.ExitCode
}

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$ui = [Windows.Automation.AutomationElement]
$scope = [Windows.Automation.TreeScope]
function Get-WindowElements {
  $pidCondition = New-Object Windows.Automation.PropertyCondition($ui::ProcessIdProperty, [int]$gui.Id)
  foreach ($window in $ui::RootElement.FindAll($scope::Children, $pidCondition)) {
    $window
    $window.FindAll($scope::Descendants, [Windows.Automation.Condition]::TrueCondition)
  }
}
function Invoke-Button($pattern, $timeout = 15) {
  $until = [DateTime]::UtcNow.AddSeconds($timeout)
  do {
    foreach ($item in Get-WindowElements) {
      try {
        if ($item.Current.ControlType -ne [Windows.Automation.ControlType]::Button -or
            $item.Current.IsOffscreen -or !$item.Current.IsEnabled -or $item.Current.Name -notmatch $pattern) {
          continue
        }
        $action = $null
        if ($item.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$action)) {
          Write-Host "Invoking $($item.Current.Name)"
          $action.Invoke()
          return
        }
      } catch [Windows.Automation.ElementNotAvailableException] { }
    }
    Start-Sleep -Milliseconds 300
  } while ([DateTime]::UtcNow -lt $until)
  throw "Could not invoke button: $pattern"
}

function Wait-ForFile($file, $timeout = 15) {
  $end = [DateTime]::UtcNow.AddSeconds($timeout)
  while (!(Test-Path $file)) {
    if ([DateTime]::UtcNow -ge $end) { throw "Timed out waiting for $file" }
    Start-Sleep -Milliseconds 250
  }
}

function Confirm-ExpectedPeer($fingerprint) {
  $end = [DateTime]::UtcNow.AddSeconds(15)
  do {
    Start-Sleep -Milliseconds 300
    $tree = @(Get-WindowElements)
    $hashes = $tree | Where-Object { $_.Current.AutomationId -match '\.pairingFingerprints$' } | Select-Object -First 1
    $comparison = $tree | Where-Object { $_.Current.AutomationId -match '\.pairingCompared$' } | Select-Object -First 1
  } while ((!$hashes -or !$comparison) -and [DateTime]::UtcNow -lt $end)
  if (!$hashes -or !$comparison) { throw 'The first-pairing review was not displayed.' }
  Write-Host "Fingerprint comparison enabled=$($comparison.Current.IsEnabled)"
  $textPattern = $null
  if ($hashes.TryGetCurrentPattern([Windows.Automation.TextPattern]::Pattern, [ref]$textPattern)) {
    $displayed = $textPattern.DocumentRange.GetText(-1)
  } else {
    $displayed = $hashes.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
  }
  $rows = [regex]::Matches($displayed, '(?im)^(?:[a-f0-9]{2}:){7}[a-f0-9]{2}\r?$')
  if ($rows.Count -ne 8 -or ((($rows | Select-Object -Last 4).Value -join '') -replace '[:\s]','') -ne $fingerprint) {
    throw 'The installed client did not display the expected test peer identity.'
  }
  $comparison.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
  Invoke-Button '^(Confirm comparison|确认核对结果)$'
  Write-Host 'Confirmed the exact first-pairing certificate fingerprint in the Windows GUI.'
}

function Test-NativeReceivedInput {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $window = [Windows.Forms.Form]::new()
  $window.Text = 'Isolated Deskflow input target'
  $window.TopMost = $true
  $window.StartPosition = 'CenterScreen'
  $window.ClientSize = [Drawing.Size]::new(430, 170)
  $instruction = [Windows.Forms.Button]::new()
  $instruction.Text = 'Input test'
  $instruction.Location = [Drawing.Point]::new(24, 19)
  $instruction.TabIndex = 0
  $edit = [Windows.Forms.TextBox]::new()
  $edit.Location = [Drawing.Point]::new(24, 78)
  $edit.Size = [Drawing.Size]::new(320, 32)
  $edit.TabIndex = 1
  $window.Controls.AddRange(@($instruction, $edit))
  $check = @{ Motion = $false; Click = $false }
  $edit.add_MouseMove({ $check.Motion = $true })
  $edit.add_MouseDown({ if ($_.Button -eq 'Left') { $check.Click = $true } })
  $window.add_Shown({
    $window.Activate()
    $window.ActiveControl = $instruction
    $point = $edit.PointToScreen([Drawing.Point]::new(62, 10))
    $resultFile = Join-Path $temp 'target.json'
    "[$($point.X),$($point.Y)]" | Set-Content "${resultFile}.tmp" -Encoding ASCII
    Move-Item "${resultFile}.tmp" $resultFile
  })
  $timer = [Windows.Forms.Timer]::new()
  $timer.Interval = 150
  $end = [DateTime]::UtcNow.AddSeconds(15)
  $timer.add_Tick({
    if (($check.Motion -and $check.Click -and $edit.Text -eq 'deskflow') -or [DateTime]::UtcNow -gt $end) {
      $window.Close()
    }
  })
  $timer.Start()
  try {
    $null = $window.ShowDialog()
    Write-Host "Native input observed: motion=$($check.Motion), left click=$($check.Click), typed text=$($edit.Text)"
    if (!$check.Motion -or !$check.Click -or $edit.Text -ne 'deskflow') { throw 'Native input did not reach the test textbox.' }
  } finally {
    $timer.Dispose()
    $window.Dispose()
  }
}

try {
  if ((Invoke-CoreToExit '--version') -ne 0) { throw 'Version command failed.' }
  if ((Invoke-CoreToExit 'server') -ne 3 -or (Invoke-CoreToExit 'client') -ne 3) {
    throw 'Unexpected exit for the default paused profile.'
  }
  $gui = Start-Process "$installDir/DeskflowCandidate.exe" -WorkingDirectory $installDir -PassThru
  Invoke-Button '^(Use this computer|使用本机的键盘和鼠标)'
  Invoke-Button '^(Prepare|准备)$'
  if (Get-Process -Name 'deskflow-candidate-core' -ErrorAction SilentlyContinue) {
    throw 'Prepare started the core before identity setup.'
  }
  Invoke-Button '^(Create identity|创建本机身份)'
  $cert = Join-Path $profile 'tls/deskflow-candidate.pem'
  Invoke-Button '^(&?OK|确定|好)$' 30
  if (!(Test-Path $cert)) { throw 'The GUI did not create a local identity.' }
  Invoke-Button '^(&?Close|关闭|完成|取消|Cancel)$'
  Invoke-Button '^(Start sharing|开始共享)$'
  $until = [DateTime]::UtcNow.AddSeconds(25)
  do {
    $core = Get-Process -Name 'deskflow-candidate-core' -ErrorAction SilentlyContinue
    $listener = Get-NetTCPConnection -LocalPort 34800 -State Listen -ErrorAction SilentlyContinue |
      Where-Object { $_.OwningProcess -in $core.Id }
    if ($listener) { break }
    Start-Sleep -Milliseconds 250
  } while ([DateTime]::UtcNow -lt $until)
  if (!$listener) { throw 'The installed input core did not listen on its default port.' }
  Write-Host 'Fresh identity creation and sharing passed, installed core is listening on TCP 34800.'
  Invoke-Button '^(&?OK|确定|好)$'
  Invoke-Button '^(Stop sharing|停止共享)$'
  $remaining = @(Get-Process -Name 'deskflow-candidate-core' -ErrorAction SilentlyContinue)
  foreach ($process in $remaining) {
    if (!$process.WaitForExit(10000)) { throw 'Pause did not stop the input core.' }
  }
  Write-Host 'Stop sharing stopped the installed input core.'
  if ((Invoke-CoreToExit 'server') -ne 3) { throw 'The paused server core ran directly.' }

  Invoke-Button '^(Change control to the other computer|Let the other computer control|改为由另一台电脑控制)$'
  Invoke-Button '^(Use the other computer|使用另一台的键盘和鼠标)'
  Invoke-Button '^(Enter address|输入地址)$'
  $until = [DateTime]::UtcNow.AddSeconds(10)
  do {
    Start-Sleep -Milliseconds 300
    $address = Get-WindowElements | Where-Object {
      $_.Current.AutomationId -match '(^|\.)homeAddress$' -and !$_.Current.IsOffscreen
    } | Select-Object -First 1
  } while (!$address -and [DateTime]::UtcNow -lt $until)
  if (!$address) { throw 'The manual address field is missing.' }
  $hostsFile = Join-Path $env:SystemRoot 'System32/drivers/etc/hosts'
  Add-Content -Path $hostsFile -Value "`r`n127.0.0.1 deskflow-test-peer.local" -Encoding ASCII
  $address.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('deskflow-test-peer.local')
  Invoke-Button '^(Use this address|使用此地址)$'
  $openssl = Join-Path $env:ProgramFiles 'OpenSSL/bin/openssl.exe'
  $certJob = Start-Process $openssl -ArgumentList 'req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=DeskflowTestPeer -keyout peer.key -out peer.pem' `
    -WorkingDirectory $temp -Wait -PassThru -RedirectStandardError "$temp/openssl.log"
  if ($certJob.ExitCode) { throw 'Could not create the temporary test peer identity.' }
  $fingerprint = ((& $openssl x509 -in "$temp/peer.pem" -noout -fingerprint -sha256) -split '=')[1] -replace ':',''
  $peerScript = (Resolve-Path 'deploy/enhanced/windows-input-peer.py').Path
  $peer = Start-Process python -ArgumentList ('"{0}" "{1}" "{2}"' -f $peerScript, $temp, "$profile/tls/deskflow-candidate.pem") `
    -PassThru -RedirectStandardOutput "$temp/peer.log" -RedirectStandardError "$temp/peer-error.log"
  try {
    Wait-ForFile "$temp/listening"
    Invoke-Button '^(Pair and connect|配对并连接)$'
    Confirm-ExpectedPeer $fingerprint
    Wait-ForFile "$temp/connected"
    Write-Host 'A new mutual TLS connection completed the Deskflow protocol handshake.'
    Invoke-Button '^(&?OK|确定|好)$' 5
    Test-NativeReceivedInput
  } finally {
    if (!$peer.HasExited -and !$peer.WaitForExit(3000)) { Stop-Process -Id $peer.Id }
    Get-Content "$temp/peer.log","$temp/peer-error.log" | Write-Host
  }
} finally {
  if ($gui -and !$gui.HasExited) {
    try {
      Get-WindowElements | ForEach-Object {
        if ($_.Current.Name -and !$_.Current.IsOffscreen) {
          Write-Host "$($_.Current.ControlType.ProgrammaticName) $($_.Current.AutomationId) $($_.Current.Name)"
        }
      }
    } catch { Write-Host $_ }
    Stop-Process -Id $gui.Id -ErrorAction SilentlyContinue
  }
  if (Test-Path "$profile/DeskflowCandidate.conf") {
    Get-Content "$profile/DeskflowCandidate.conf" | Write-Host
  }
  Get-Process -Name 'deskflow-candidate-core' -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
  Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000; StartTime=$testStart} -ErrorAction SilentlyContinue |
    Where-Object Message -Match 'DeskflowCandidate|deskflow-candidate-core' | Select-Object -ExpandProperty Message | Write-Host
}
