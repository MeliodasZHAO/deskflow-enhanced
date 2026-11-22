# SPDX-FileCopyrightText: (C) 2026 Deskflow Enhanced contributors
# SPDX-License-Identifier: MIT
param([Parameter(Mandatory)][ValidateSet('build','package')][string]$Phase)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$version = '1.27.0.19'
$qt = $env:QT_SDK
$openssl = $env:OPENSSL_SDK
if (!$qt -or !$openssl) { throw 'Set QT_SDK and OPENSSL_SDK to the x64 release SDKs.' }
$env:Path = "$qt/bin;$openssl/bin;$env:Path"
if ($Phase -eq 'build') {
  $common = @('-G', 'Visual Studio 17 2022', '-A', 'x64', '-DBUILD_INSTALLER=OFF',
    '-DSKIP_BUILD_TESTS=ON', '-DUPDATE_TRANSLATIONS=OFF', "-DDESKFLOW_PACKAGE_VERSION=$version",
    "-DCMAKE_PREFIX_PATH=$qt", "-DOPENSSL_ROOT_DIR=$openssl")
  cmake -S . -B build-tests @common -DBUILD_TESTS=ON
  cmake --build build-tests --config Release --parallel 4
  # The test resolves ../../../translations relative to its executable.
  # Visual Studio adds a Release level that single-config builds do not have.
  New-Item -ItemType Directory -Force 'build-tests/src/translations' | Out-Null
  Copy-Item build-tests/translations/*.qm 'build-tests/src/translations'
  $env:QT_QPA_PLATFORM = 'offscreen'
  ctest --test-dir build-tests/src/unittests -C Release --parallel 2 --no-tests=error --output-on-failure
  cmake -S . -B build @common -DDESKFLOW_CANDIDATE_BUILD=ON -DBUILD_TESTS=OFF
  cmake --build build --config Release --target DeskflowCandidate deskflow-core deskflow-candidate-network-core app_translations --parallel 4
  exit
}

$out = (New-Item -ItemType Directory -Path release-out).FullName
$stage = (New-Item -ItemType Directory -Path installer-payload).FullName
foreach ($file in 'DeskflowCandidate.exe','deskflow-candidate-core.exe','deskflow-candidate-network-core.exe') {
  Copy-Item "build/bin/Release/$file" $stage
}
& "$qt/bin/windeployqt.exe" --release --no-compiler-runtime --no-system-d3d-compiler --no-opengl-sw --no-quick-import --no-translations --dir $stage "$stage/DeskflowCandidate.exe"
Get-ChildItem "$openssl/bin" -Filter 'lib*.dll' | Copy-Item -Destination $stage
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vs = & $vswhere -latest -products '*' -property installationPath
$crt = Get-ChildItem "$vs/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT" -Directory | Sort-Object FullName -Descending | Select-Object -First 1
if (!$crt) { throw 'Visual C++ app-local runtime files are missing.' }
Get-ChildItem $crt.FullName -Filter '*.dll' | Copy-Item -Destination $stage
$translations = (New-Item -ItemType Directory -Path "$stage/translations").FullName
Copy-Item build/translations/*.qm $translations
Copy-Item "$qt/translations/qtbase_zh_CN.qm" "$translations/qt_zh_CN.qm"
Copy-Item LICENSE "$stage/LICENSE.txt"
Copy-Item LICENSES "$stage/LICENSES" -Recurse
Copy-Item deploy/enhanced/THIRD-PARTY.md "$stage/THIRD-PARTY.md"
$opensslNotice = @('share/openssl/copyright','LICENSE.txt','LICENSE') | ForEach-Object { Join-Path $openssl $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($opensslNotice) { Copy-Item $opensslNotice "$stage/LICENSES/OpenSSL.txt" }
if (!(Test-Path "$stage/LICENSES/Apache-2.0.txt")) { throw 'OpenSSL license missing.' }
if (!(Get-ChildItem $stage -File -Filter 'libssl*.dll') -or !(Get-ChildItem $stage -File -Filter 'libcrypto*.dll')) { throw 'OpenSSL runtime is incomplete.' }
foreach ($file in 'Qt6Core.dll','Qt6Widgets.dll','platforms/qwindows.dll','translations/deskflow_zh_CN.qm', 'vcruntime140.dll') {
  if (!(Test-Path "$stage/$file")) { throw "Missing package entry $file" }
}
$files = @(Get-ChildItem $stage -Recurse -File)
if ($files | Where-Object { $_.Name -match '\.(conf|state|log|pem|key|pfx|pdb)$' }) { throw 'Profile, credentials, or debug artifacts found in package.' }
$remove = foreach ($file in $files) {
  $relative = [IO.Path]::GetRelativePath($stage, $file.FullName)
  '  Delete "$INSTDIR\' + $relative + '"'
}
$remove += @(Get-ChildItem $stage -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
  '  RMDir "$INSTDIR\' + [IO.Path]::GetRelativePath($stage, $_.FullName) + '"'
})
$payloadList = Join-Path $PWD 'remove-payload.nsh'
$remove | Set-Content $payloadList -Encoding utf8
$installer = Join-Path $out "Deskflow-Enhanced-$version-Windows-x64-Setup.exe"
$nsis = Join-Path ${env:ProgramFiles(x86)} 'NSIS/makensis.exe'
& $nsis "/DPAYLOAD=$stage" "/DRESULT=$installer" "/DREMOVE_PAYLOAD=$payloadList" deploy/enhanced/installer.nsi
if (!(Test-Path $installer)) { throw 'Installer was not generated.' }

# Exercise the exact installer with an empty profile on the disposable runner.
$target = Join-Path $env:RUNNER_TEMP 'enhanced-install-smoke'
if (Test-Path $target) { throw 'Install smoke path is not empty.' }
$install = Start-Process $installer -ArgumentList "/S /D=$target" -PassThru -Wait
if ($install.ExitCode -ne 0) { throw "Installer exit $($install.ExitCode)" }
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Deskflow Enhanced/Deskflow Enhanced.lnk'
if (!(Test-Path $shortcut)) { throw 'Start menu shortcut was not installed.' }
$env:Path = "$env:SystemRoot/System32;$env:SystemRoot"
Push-Location $target
try {
  $core = Start-Process "$target/deskflow-candidate-core.exe" -ArgumentList '--version' -Wait -PassThru -RedirectStandardOutput "$out/core-version.txt"
  if ($core.ExitCode -ne 0 -or !(Select-String -Path "$out/core-version.txt" -SimpleMatch $version)) { throw 'Installed core version check failed.' }
  $gui = Start-Process "$target/DeskflowCandidate.exe" -PassThru
  try {
    for ($i=0; $i -lt 30; $i++) {
      Start-Sleep -Seconds 1
      $gui.Refresh()
      if ($gui.HasExited) { throw "Installed GUI exited with $($gui.ExitCode)" }
      if ($gui.MainWindowHandle -ne 0 -and $gui.Responding) { break }
    }
    if ($gui.MainWindowHandle -eq 0 -or !$gui.Responding) { throw 'Installed GUI did not open a responsive window.' }
  } finally {
    if (!$gui.HasExited) {
      $null = $gui.CloseMainWindow()
      if (!$gui.WaitForExit(5000)) { Stop-Process -Id $gui.Id }
    }
  }
} finally { Pop-Location }
$uninstall = Start-Process "$target/Uninstall.exe" -ArgumentList "/S _?=$target" -Wait -PassThru
if ($uninstall.ExitCode -ne 0 -or (Test-Path "$target/DeskflowCandidate.exe") -or (Test-Path $shortcut)) { throw 'Uninstall smoke failed.' }
'Windows installer, installed core, native GUI and uninstaller passed.' | Set-Content "$out/windows-validation.txt"
