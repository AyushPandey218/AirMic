param()

Start-Transcript -Path "$env:TEMP\airmic_uninstall_log.txt" -Force

try {
    Write-Host "Finding VB-Cable / VB-Audio driver packages..."

    $raw = pnputil /enum-drivers
    $lines = $raw -split "`r`n"
    $current = @{}
    $toRemove = @()

    foreach ($line in $lines) {
        if ($line -match "^Published Name:\s+(oem\d+\.inf)") {
            $current.Published = $matches[1]
        } elseif ($line -match "^Original Name:\s+(.+)") {
            $current.Original = $matches[1]
        } elseif ($line -match "^Provider Name:\s+(.+)") {
            $current.Provider = $matches[1]
        } elseif ($line.Trim() -eq "") {
            if ($current.ContainsKey("Original") -and
                ($current.Original -match "vbaudio_cable" -or $current.Provider -match "VB-Audio")) {
                Write-Host "  Found VB-Cable driver: Published=$($current.Published), Original=$($current.Original)"
                $toRemove += $current.Published
            }
            $current = @{}
        }
    }

    if ($toRemove.Count -eq 0) {
        Write-Host "No VB-Cable drivers found."
    } else {
        foreach ($inf in $toRemove) {
            Write-Host "Removing driver package: $inf ..."
            & pnputil /delete-driver $inf /uninstall /force
            Write-Host "  Exit code: $LASTEXITCODE"
        }
    }

    # Clean up any leftover driver files
    $sysFiles = @(
        "$env:SystemRoot\System32\drivers\vbaudio_cable.sys",
        "$env:SystemRoot\System32\drivers\vbaudio_cable64.sys",
        "$env:SystemRoot\System32\drivers\vbaudio_cablea.sys",
        "$env:SystemRoot\System32\drivers\vbaudio_cablea64.sys",
        "$env:SystemRoot\System32\drivers\vbaudio_cableb.sys",
        "$env:SystemRoot\System32\drivers\vbaudio_cableb64.sys"
    )
    foreach ($f in $sysFiles) {
        if (Test-Path $f) {
            Write-Host "Removing leftover driver file: $f"
            Remove-Item -Path $f -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "VB-Cable driver cleanup complete."
} catch {
    Write-Error $_
} finally {
    Stop-Transcript
}
