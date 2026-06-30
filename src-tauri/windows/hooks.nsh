!macro NSIS_HOOK_POSTINSTALL
  ; Run the install + rename script — handles VB-Cable A/B installation and device renaming
  DetailPrint "Installing AirMic audio drivers (VB-Cable A+B)..."
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\resources\install_and_rename.ps1" -InstDir "$INSTDIR"'
!macroend
