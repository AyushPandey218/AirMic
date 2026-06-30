param(
    [string]$InstDir
)

Start-Transcript -Path "$env:TEMP\airmic_install_log.txt" -Force

try {
    # ─────────────────────────────────────────────────────────────────────────
    # 1. Install VB-Cable A silently
    # ─────────────────────────────────────────────────────────────────────────
    $cableADir  = "$InstDir\resources\drivers\CableA"
    $cableAExe  = "$cableADir\VBCABLE_Setup_x64.exe"
    if (Test-Path $cableAExe) {
        Write-Host "Installing VB-Cable A: $cableAExe"
        $procA = Start-Process -FilePath $cableAExe -ArgumentList "/S", "/NCRC" -Wait -NoNewWindow -WorkingDirectory $cableADir -PassThru
        Write-Host "VB-Cable A exit code: $($procA.ExitCode)"
    } else {
        Write-Host "WARNING: VB-Cable A installer not found at $cableAExe"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # 2. Install VB-Cable B silently
    # ─────────────────────────────────────────────────────────────────────────
    $cableBDir  = "$InstDir\resources\drivers\CableB"
    $cableBExe  = "$cableBDir\VBCABLE_Setup_x64.exe"
    if (Test-Path $cableBExe) {
        Write-Host "Installing VB-Cable B: $cableBExe"
        $procB = Start-Process -FilePath $cableBExe -ArgumentList "/S", "/NCRC" -Wait -NoNewWindow -WorkingDirectory $cableBDir -PassThru
        Write-Host "VB-Cable B exit code: $($procB.ExitCode)"
    } else {
        Write-Host "WARNING: VB-Cable B installer not found at $cableBExe"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # 3. Wait for Windows PnP to register the new audio endpoints
    # ─────────────────────────────────────────────────────────────────────────
    Write-Host "Waiting 10 seconds for device registration..."
    Start-Sleep -Seconds 10

    # ─────────────────────────────────────────────────────────────────────────
    # 4. C# helper to take ownership of registry keys and rename endpoints
    # ─────────────────────────────────────────────────────────────────────────
    $Definition = @"
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Security.AccessControl;
using Microsoft.Win32;

public class RegistrySecurityHelper
{
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    private static extern bool LookupPrivilegeValue(string lpSystemName, string lpName, out long lpLuid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool AdjustTokenPrivileges(IntPtr TokenHandle, bool DisableAllPrivileges, ref TOKEN_PRIVILEGES NewState, int BufferLength, IntPtr PreviousState, IntPtr ReturnLength);

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct LUID_AND_ATTRIBUTES { public long Luid; public uint Attributes; }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID_AND_ATTRIBUTES Privilege; }

    private const uint TOKEN_ADJUST_PRIVILEGES = 0x00000020;
    private const uint TOKEN_QUERY             = 0x00000008;
    private const uint SE_PRIVILEGE_ENABLED    = 0x00000002;

    private static RegistryKey OpenHklm(string path, RegistryKeyPermissionCheck permissionCheck, RegistryRights rights)
    {
        return RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(path, permissionCheck, rights);
    }

    private static RegistryKey OpenHklm(string path, bool writable)
    {
        return RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(path, writable);
    }

    public static void EnablePrivilege(string privilegeName)
    {
        IntPtr hToken;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle,
                              TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out hToken)) return;
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Privilege.Attributes = SE_PRIVILEGE_ENABLED;
        long luid;
        if (!LookupPrivilegeValue(null, privilegeName, out luid)) return;
        tp.Privilege.Luid = luid;
        AdjustTokenPrivileges(hToken, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }

    public static bool RenameEndpoint(string subKeyPath, string newFriendlyName)
    {
        EnablePrivilege("SeTakeOwnershipPrivilege");
        EnablePrivilege("SeRestorePrivilege");
        try
        {
            RegistryKey key = OpenHklm(subKeyPath,
                RegistryKeyPermissionCheck.ReadSubTree, RegistryRights.TakeOwnership);
            if (key == null) { Console.WriteLine("Cannot open (TakeOwnership): " + subKeyPath); return false; }
            RegistrySecurity sec = key.GetAccessControl(AccessControlSections.Owner);
            sec.SetOwner(new NTAccount("Administrators"));
            key.SetAccessControl(sec);
            key.Close();

            key = OpenHklm(subKeyPath,
                RegistryKeyPermissionCheck.ReadSubTree, RegistryRights.ChangePermissions);
            if (key == null) { Console.WriteLine("Cannot open (ChangePermissions): " + subKeyPath); return false; }
            sec = key.GetAccessControl(AccessControlSections.Access);
            sec.ResetAccessRule(new RegistryAccessRule("Administrators",
                RegistryRights.FullControl,
                InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
                PropagationFlags.None, AccessControlType.Allow));
            key.SetAccessControl(sec);
            key.Close();

            key = OpenHklm(subKeyPath, true);
            if (key == null) { Console.WriteLine("Cannot open (Write): " + subKeyPath); return false; }
            // PKEY_Device_FriendlyName = {a45c254e-df1c-4efd-8020-67d146a850e0},2
            key.SetValue("{a45c254e-df1c-4efd-8020-67d146a850e0},2", newFriendlyName, RegistryValueKind.String);
            key.Close();

            Console.WriteLine("Renamed -> " + newFriendlyName);
            return true;
        }
        catch (Exception ex)
        {
            Console.WriteLine("Error: " + ex.Message);
            return false;
        }
    }
}
"@
    Add-Type -TypeDefinition $Definition -ErrorAction Stop

    # ─────────────────────────────────────────────────────────────────────────
    # 5. List all audio endpoints for diagnostics (via PSDrive for reliability)
    # ─────────────────────────────────────────────────────────────────────────
    Write-Host "--- Audio endpoints found ---"
    $allDevices = @()
    $basePaths = @{
        "Render"  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render"
        "Capture" = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture"
    }
    foreach ($label in $basePaths.Keys) {
        $psPath = $basePaths[$label]
        if (-not (Test-Path $psPath)) { Write-Host "  ($label hive not found)"; continue }
        $guids = Get-ChildItem -Path $psPath -ErrorAction SilentlyContinue
        if (-not $guids) { Write-Host "  ($label: no device entries)"; continue }
        foreach ($guid in $guids) {
            $devPath = Join-Path $psPath $guid.PSChildName
            $propPath = Join-Path $devPath "Properties"
            if (-not (Test-Path $propPath)) { continue }
            $props = Get-ItemProperty -Path $propPath -ErrorAction SilentlyContinue
            $fKey = "{a45c254e-df1c-4efd-8020-67d146a850e0},2"
            $cKey = "{b3f8fa53-0004-438e-9003-51a46e139bfc},6"
            $friendly   = $props.$fKey
            $controller = $props.$cKey
            $regPath = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$label\$($guid.PSChildName)\Properties"
            if ($friendly -or $controller) {
                $allDevices += @{ Label=$label; RegPath=$regPath; Friendly=$friendly; Controller=$controller }
                Write-Host "  [$label] Friendly='$friendly'  Controller='$controller'"
            }
        }
    }

    # ─────────────────────────────────────────────────────────────────────────
    # 6. Rename table — match on friendly name OR controller/driver name
    #    Matches in order: cable-a/b -> cable (standard) -> vb-audio
    # ─────────────────────────────────────────────────────────────────────────
    $renameRules = @(
        @{ Label = "Render";  Match = "cable-a";     NewName = "AirMic Speaker"     },
        @{ Label = "Render";  Match = "cable-b";     NewName = "AirMic Mic In"      },
        @{ Label = "Capture"; Match = "cable-a";     NewName = "AirMic Speaker Out" },
        @{ Label = "Capture"; Match = "cable-b";     NewName = "AirMic Mic"         },
        @{ Label = "Render";  Match = "cable";       NewName = "AirMic Speaker"     },
        @{ Label = "Capture"; Match = "cable";       NewName = "AirMic Mic"         }
    )

    $renamedCount = 0
    $alreadyRenamed = @{}

    foreach ($rule in $renameRules) {
        $psPath = $basePaths[$rule.Label]
        if (-not (Test-Path $psPath)) { continue }
        $guids = Get-ChildItem -Path $psPath -ErrorAction SilentlyContinue
        if (-not $guids) { continue }
        foreach ($guid in $guids) {
            $regPath = "SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$($rule.Label)\$($guid.PSChildName)\Properties"
            if ($alreadyRenamed.ContainsKey($regPath)) { continue }
            $devPath = Join-Path $psPath $guid.PSChildName
            $propPath = Join-Path $devPath "Properties"
            if (-not (Test-Path $propPath)) { continue }
            $props = Get-ItemProperty -Path $propPath -ErrorAction SilentlyContinue
            $fKey = "{a45c254e-df1c-4efd-8020-67d146a850e0},2"
            $cKey = "{b3f8fa53-0004-438e-9003-51a46e139bfc},6"
            $friendly   = $props.$fKey
            $controller = $props.$cKey
            $friendlyStr   = if ($friendly)   { $friendly.ToString().ToLower()   } else { "" }
            $controllerStr = if ($controller) { $controller.ToString().ToLower() } else { "" }
            $matchKey      = $rule.Match.ToLower()

            if ($friendlyStr -like "*$matchKey*" -or $controllerStr -like "*$matchKey*") {
                Write-Host "Renaming '$($rule.NewName)' at $regPath (was: $friendly)"
                if ([RegistrySecurityHelper]::RenameEndpoint($regPath, $rule.NewName)) {
                    $alreadyRenamed[$regPath] = $true
                    $renamedCount++
                }
            }
        }
    }

    Write-Host "Total endpoints renamed: $renamedCount"

    # ─────────────────────────────────────────────────────────────────────────
    # 6. Restart Windows Audio to apply names without a reboot
    # ─────────────────────────────────────────────────────────────────────────
    if ($renamedCount -gt 0) {
        Write-Host "Restarting Windows Audio service..."
        Stop-Service  -Name "Audiosrv" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Start-Service -Name "Audiosrv"        -ErrorAction SilentlyContinue
        Write-Host "Audio service restarted."
    }

} catch {
    Write-Error $_
} finally {
    Stop-Transcript
}
