# SPDX-FileCopyrightText: (C) 2026 Deskflow Enhanced contributors
# SPDX-License-Identifier: MIT
$ErrorActionPreference = 'Stop'
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
  Invoke-Button '^(Pause|暂停|暂停共享)$'
  $remaining = @(Get-Process -Name 'deskflow-candidate-core' -ErrorAction SilentlyContinue)
  foreach ($process in $remaining) {
    if (!$process.WaitForExit(10000)) { throw 'Pause did not stop the input core.' }
  }
  Write-Host 'Pause stopped the installed input core.'
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
