!macro NSIS_HOOK_POSTINSTALL
  ; Install VB-Cable A silently — set working dir so it finds companion .sys/.inf files
  DetailPrint "Installing AirMic Speaker (VB-Cable A)..."
  SetOutPath "$INSTDIR\resources\drivers\CableA"
  nsExec::ExecToLog '"$INSTDIR\resources\drivers\CableA\VBCABLE_Setup_x64.exe" /S /NCRC'

  ; Install VB-Cable B silently
  DetailPrint "Installing AirMic Mic (VB-Cable B)..."
  SetOutPath "$INSTDIR\resources\drivers\CableB"
  nsExec::ExecToLog '"$INSTDIR\resources\drivers\CableB\VBCABLE_Setup_x64.exe" /S /NCRC'

  ; Run the rename script — pass $INSTDIR so the script knows where drivers are
  DetailPrint "Renaming audio devices to AirMic branding..."
  SetOutPath "$INSTDIR\resources"
  nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\resources\install_and_rename.ps1" -InstDir "$INSTDIR"'
!macroend
