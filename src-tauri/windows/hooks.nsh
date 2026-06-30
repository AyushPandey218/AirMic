!macro NSIS_HOOK_POSTINSTALL
  ; Run the install + rename script — handles VB-Cable A/B installation and device renaming
  ; Resources are extracted to $INSTDIR\_up_\resources\ by Tauri's NSIS template
  DetailPrint "Installing AirMic audio drivers (VB-Cable A+B)..."
  SetOutPath "$INSTDIR\_up_\resources"
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\_up_\resources\install_and_rename.ps1" -InstDir "$INSTDIR\_up_"'
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ; Remove VB-Cable A+B drivers using the bundled uninstall script
  DetailPrint "Removing VB-Cable audio drivers..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\_up_\resources\uninstall_vbcable.ps1"'
!macroend
