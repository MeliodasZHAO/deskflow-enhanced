# SPDX-FileCopyrightText: (C) 2026 Deskflow Enhanced contributors
# SPDX-License-Identifier: MIT
param([string]$Installer, [switch]$Baseline)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$env:RUNNER_TEMP) {
  throw 'Use only on the disposable Windows release runner.'
}
$temp = Join-Path $env:RUNNER_TEMP 'onboarding-check'
$target = Join-Path $temp 'Deskflow Enhanced'
$null = New-Item -ItemType Directory $temp
$evidence = (New-Item -ItemType Directory 'first-use-evidence').FullName
if ($Baseline) {
  $Installer = Join-Path $temp 'original.exe'
  $url = 'https://github.com/MeliodasZHAO/deskflow-enhanced/releases/download/v1.27.0.17-preview/Deskflow-Enhanced-1.27.0.17-Windows-x64-Setup.exe'
  curl.exe -fL -sS $url -o $Installer
  if ($LASTEXITCODE -or (Get-FileHash $Installer).Hash -ne 'b881ed2e45dd5aed08640a7a9683c155bf88d766dd881ebb4f013d8843f3abea') {
    throw 'The published installer did not match its hash.'
  }
}
$setup = Start-Process $Installer -ArgumentList "/S /D=$target" -Wait -PassThru
if ($setup.ExitCode) { throw "Install failed: $($setup.ExitCode)" }
$profile = Join-Path $env:USERPROFILE 'AppData/Roaming/DeskflowCandidate'
if (Test-Path "$profile/tls") { throw 'An unexpected test profile already contains an identity.' }
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
$ui = [Windows.Automation.AutomationElement]
$scope = [Windows.Automation.TreeScope]

function Get-Elements {
  $condition = [Windows.Automation.PropertyCondition]::new($ui::ProcessIdProperty, [int]$gui.Id)
  foreach ($window in $ui::RootElement.FindAll($scope::Children, $condition)) {
    $window
    $window.FindAll($scope::Descendants, [Windows.Automation.Condition]::TrueCondition)
  }
}
function Wait-Element($name, $controlType) {
  $end = [DateTime]::UtcNow.AddSeconds(20)
  do {
    foreach ($element in Get-Elements) {
      try {
        $info = $element.Current
        if ($info.Name -match $name -and $info.ControlType -eq $controlType -and $info.IsEnabled -and !$info.IsOffscreen) {
          return $element
        }
      } catch [Windows.Automation.ElementNotAvailableException] { }
    }
    Start-Sleep -Milliseconds 300
  } while ([DateTime]::UtcNow -lt $end)
  throw "Missing visible control: $name"
}
function Press-Button($name) {
  $button = Wait-Element $name ([Windows.Automation.ControlType]::Button)
  Write-Host "Click $($button.Current.Name)"
  $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
}
function Save-Capture($window, $file) {
  $bounds = $window.Current.BoundingRectangle
  $image = [Drawing.Bitmap]::new([int]$bounds.Width, [int]$bounds.Height)
  $canvas = [Drawing.Graphics]::FromImage($image)
  try {
    $canvas.CopyFromScreen([int]$bounds.X, [int]$bounds.Y, 0, 0, $image.Size)
    $image.Save((Join-Path $evidence $file), [Drawing.Imaging.ImageFormat]::Png)
  } finally {
    $canvas.Dispose()
    $image.Dispose()
  }
}

foreach ($role in 'sharing', 'receiving') {
  if (Test-Path $profile) {
    # This profile belongs only to the disposable runner and previous iteration.
    Rename-Item $profile "DeskflowCandidate-test-$role"
  }
  $gui = Start-Process "$target/DeskflowCandidate.exe" -WorkingDirectory $target -PassThru
  try {
    if ($role -eq 'sharing') {
      Press-Button '^(Use this computer|使用本机的键盘和鼠标)'
      $next = '^(Start sharing|开始共享)$'
      $hint = 'click .Start sharing.|点「开始共享」'
    } else {
      Press-Button '^(Use the other computer|使用另一台的键盘和鼠标)'
      $next = '^(Find computer|查找电脑)$'
      $hint = 'click .Enter address.|点「输入地址」'
    }
    Press-Button '^(Prepare|准备)$'
    Press-Button '^(Create identity|创建本机身份)'
    $title = if ($Baseline) { '^(TLS Certificate Regenerated|TLS 证书已重新生成)$' } else { '^(Identity is ready|本机身份已就绪)$' }
    $window = Wait-Element $title ([Windows.Automation.ControlType]::Window)
    Save-Capture $window "$role-confirmation.png"
    if (!$Baseline) {
      $null = Wait-Element $hint ([Windows.Automation.ControlType]::Text)
    }
    if ($Baseline) {
      Press-Button '^(&?OK|确定|好)$'
      Press-Button '^(&?Cancel|取消|关闭)$'
    } else {
      Press-Button '^(Back to Overview|返回概览)$'
    }
    $null = Wait-Element $next ([Windows.Automation.ControlType]::Button)
    $home = Wait-Element '^DeskflowCandidate( - .*)?$' ([Windows.Automation.ControlType]::Window)
    Save-Capture $home "$role-overview.png"
    if (!(Test-Path "$profile/tls/deskflow-candidate.pem")) { throw 'The local identity was not written.' }
    if (Get-Process -Name 'deskflow-candidate-core' -ErrorAction SilentlyContinue) {
      throw 'Returning to Overview unexpectedly started the input core.'
    }
    Write-Host "Verified $role reaches its next action with sharing still stopped."
  } finally {
    if (!$gui.HasExited) {
      Stop-Process -Id $gui.Id -ErrorAction SilentlyContinue
      $null = $gui.WaitForExit(3000)
    }
  }
}
