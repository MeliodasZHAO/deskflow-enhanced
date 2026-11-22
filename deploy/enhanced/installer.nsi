; SPDX-FileCopyrightText: (C) 2026 Deskflow Enhanced contributors
; SPDX-License-Identifier: MIT
Unicode true
Name "Deskflow Enhanced"
OutFile "${RESULT}"
InstallDir "$LOCALAPPDATA\Programs\Deskflow Enhanced"
InstallDirRegKey HKCU "Software\Deskflow Enhanced" "InstallDir"
RequestExecutionLevel user
VIProductVersion "1.27.0.18"
VIAddVersionKey "ProductName" "Deskflow Enhanced"
VIAddVersionKey "FileDescription" "Deskflow Enhanced Windows installer"
VIAddVersionKey "FileVersion" "1.27.0.18"
VIAddVersionKey "LegalCopyright" "Deskflow and Deskflow Enhanced contributors"
Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section
  SetShellVarContext current
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD}\*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\Deskflow Enhanced"
  CreateShortcut "$SMPROGRAMS\Deskflow Enhanced\Deskflow Enhanced.lnk" "$INSTDIR\DeskflowCandidate.exe"
  WriteRegStr HKCU "Software\Deskflow Enhanced" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskflowEnhanced" "DisplayName" "Deskflow Enhanced"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskflowEnhanced" "DisplayVersion" "1.27.0.18"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskflowEnhanced" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskflowEnhanced" "DisplayIcon" "$INSTDIR\DeskflowCandidate.exe"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskflowEnhanced" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskflowEnhanced" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  !include "${REMOVE_PAYLOAD}"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
  Delete "$SMPROGRAMS\Deskflow Enhanced\Deskflow Enhanced.lnk"
  RMDir "$SMPROGRAMS\Deskflow Enhanced"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskflowEnhanced"
  DeleteRegKey HKCU "Software\Deskflow Enhanced"
SectionEnd
