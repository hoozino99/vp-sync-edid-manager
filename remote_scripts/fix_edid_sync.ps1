# fix_edid_sync.ps1 — Parameterized EDID/Sync operations via NVAPI
# Parameters are injected as PowerShell variables by node_remote.py:
#   $Action   = "quick_fix" | "edid_load" | "edid_unload" | "sync_enable" | "sync_disable"
#   $OutputId = <uint32 display output id> (for EDID operations, 0 = first output)
# Outputs JSON result.

$ErrorActionPreference = "Stop"

# Default params (overridden by prepended variable assignments from node_remote.py)
if (-not (Test-Path variable:Action))   { $Action = "quick_fix" }
if (-not (Test-Path variable:OutputId)) { $OutputId = 0 }

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NvAPI
{
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr QueryInterface(uint id);

    public const uint ID_Initialize              = 0x0150E828;
    public const uint ID_EnumPhysicalGPUs        = 0xE5AC921F;
    public const uint ID_GPU_GetEDID             = 0x37D32E69;
    public const uint ID_GPU_SetEDID             = 0xE83D6456;
    public const uint ID_GPU_GetAllOutputs       = 0x7D554F8E;
    public const uint ID_GSync_EnumDevices       = 0xD9639601;
    public const uint ID_GSync_GetSyncStatus     = 0x2AE50D0D;
    public const uint ID_GSync_SetSyncState      = 0x60ACDFDD;
    public const uint ID_GSync_GetControlParams  = 0x16DE1C6A;
    public const uint ID_GSync_SetControlParams  = 0x8BBFF88B;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_Initialize();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_EnumPhysicalGPUs(
        [MarshalAs(UnmanagedType.LPArray, SizeConst = 64)] IntPtr[] handles, ref int count);

    [StructLayout(LayoutKind.Sequential)]
    public struct NV_EDID
    {
        public uint version;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)]
        public byte[] edidData;
        public uint sizeofEDID;
        public uint edidId;
        public uint offset;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GPU_GetEDID(IntPtr hGpu, uint outputId, ref NV_EDID edid);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GPU_SetEDID(IntPtr hGpu, uint outputId, ref NV_EDID edid);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GPU_GetAllOutputs(IntPtr hGpu, ref uint outputsMask);

    [StructLayout(LayoutKind.Sequential)]
    public struct NV_GSYNC_STATUS
    {
        public uint version;
        public uint bIsSynced;
        public uint bStereoSynced;
        public uint bHouseSyncIncoming;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GSync_EnumDevices(
        [MarshalAs(UnmanagedType.LPArray, SizeConst = 4)] IntPtr[] handles, ref int count);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GSync_GetSyncStatus(IntPtr hDevice, ref NV_GSYNC_STATUS status);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GSync_SetSyncStateSettings(uint count, IntPtr pTopology, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct NV_GSYNC_CONTROL_PARAMS
    {
        public uint version;
        public uint polarity;
        public uint vmode;
        public uint interval;
        public uint source;
        public uint interlaceMode;
        public uint syncSkew;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GSync_GetControlParams(IntPtr hDevice, ref NV_GSYNC_CONTROL_PARAMS p);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GSync_SetControlParams(IntPtr hDevice, ref NV_GSYNC_CONTROL_PARAMS p);

    public static T GetDelegate<T>(uint id) where T : class
    {
        IntPtr ptr = QueryInterface(id);
        if (ptr == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(ptr, typeof(T)) as T;
    }
}
"@

# PS5.1-compatible helper for calling generic GetDelegate<T>(uint id)
function Invoke-NvAPIDelegate {
    param([Type]$DelegateType, [uint32]$FunctionId)
    $method = [NvAPI].GetMethod('GetDelegate')
    $generic = $method.MakeGenericMethod($DelegateType)
    return $generic.Invoke($null, @($FunctionId))
}


function Init-NvAPI {
    $init = Invoke-NvAPIDelegate ([NvAPI+NvAPI_Initialize]) ([uint32][NvAPI]::ID_Initialize)
    if ($null -eq $init) { return $false }
    $s = $init.Invoke()
    return ($s -eq 0)
}

function Get-Gpu {
    $gpuHandles = New-Object IntPtr[] 64
    [int]$gpuCount = 0
    $enumGpus = Invoke-NvAPIDelegate ([NvAPI+NvAPI_EnumPhysicalGPUs]) ([uint32][NvAPI]::ID_EnumPhysicalGPUs)
    $s = $enumGpus.Invoke($gpuHandles, [ref]$gpuCount)
    if ($s -ne 0 -or $gpuCount -eq 0) { return $null }
    return $gpuHandles[0]
}

function Get-SyncHandle {
    $enumSync = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GSync_EnumDevices]) ([uint32][NvAPI]::ID_GSync_EnumDevices)
    if ($null -eq $enumSync) { return $null }
    $syncHandles = New-Object IntPtr[] 4
    [int]$syncCount = 0
    $s = $enumSync.Invoke($syncHandles, [ref]$syncCount)
    if ($s -eq 0 -and $syncCount -gt 0) { return $syncHandles[0] }
    return $null
}

function Resolve-OutputId {
    param([IntPtr]$hGpu, [uint32]$requestedId)
    # If 0, use the first available output
    if ($requestedId -ne 0) { return $requestedId }
    $getAllOutputs = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GPU_GetAllOutputs]) ([uint32][NvAPI]::ID_GPU_GetAllOutputs)
    if ($null -ne $getAllOutputs) {
        [uint32]$mask = 0
        $getAllOutputs.Invoke($hGpu, [ref]$mask) | Out-Null
        if ($mask -ne 0) {
            for ($b = 0; $b -lt 32; $b++) {
                $oid = [uint32](1 -shl $b)
                if (($mask -band $oid) -ne 0) { return $oid }
            }
        }
    }
    return [uint32]1  # fallback to output 0
}

function Do-EdidLoad {
    param([IntPtr]$hGpu, [uint32]$oid)
    $getEdid = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GPU_GetEDID]) ([uint32][NvAPI]::ID_GPU_GetEDID)
    $setEdid = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GPU_SetEDID]) ([uint32][NvAPI]::ID_GPU_SetEDID)
    if ($null -eq $getEdid -or $null -eq $setEdid) { return "ERROR_NO_FUNC" }

    # Read current EDID
    $edid = New-Object NvAPI+NV_EDID
    $edid.edidData = New-Object byte[] 256
    $edid.version = 0x00030000 -bor 276
    $edid.offset = 0
    $s = $getEdid.Invoke($hGpu, $oid, [ref]$edid)
    if ($s -ne 0 -or $edid.sizeofEDID -eq 0) { return "NO_EDID_TO_RELOAD" }

    $savedData = $edid.edidData.Clone()
    $savedSize = $edid.sizeofEDID

    # Unload
    $blank = New-Object NvAPI+NV_EDID
    $blank.edidData = New-Object byte[] 256
    $blank.version = 0x00030000 -bor 276
    $blank.sizeofEDID = 0
    $setEdid.Invoke($hGpu, $oid, [ref]$blank) | Out-Null
    Start-Sleep -Milliseconds 500

    # Reload
    $reload = New-Object NvAPI+NV_EDID
    $reload.edidData = $savedData
    $reload.version = 0x00030000 -bor 276
    $reload.sizeofEDID = $savedSize
    $reload.offset = 0
    $s = $setEdid.Invoke($hGpu, $oid, [ref]$reload)
    return $(if ($s -eq 0) { "OK" } else { "FAILED_$s" })
}

function Do-EdidUnload {
    param([IntPtr]$hGpu, [uint32]$oid)
    $setEdid = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GPU_SetEDID]) ([uint32][NvAPI]::ID_GPU_SetEDID)
    if ($null -eq $setEdid) { return "ERROR_NO_FUNC" }

    $blank = New-Object NvAPI+NV_EDID
    $blank.edidData = New-Object byte[] 256
    $blank.version = 0x00030000 -bor 276
    $blank.sizeofEDID = 0
    $s = $setEdid.Invoke($hGpu, $oid, [ref]$blank)
    return $(if ($s -eq 0) { "OK" } else { "FAILED_$s" })
}

function Do-SyncEnable {
    param([IntPtr]$hSync)
    $setSync = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GSync_SetSyncStateSettings]) ([uint32][NvAPI]::ID_GSync_SetSyncState)
    if ($null -eq $setSync) { return "ERROR_NO_FUNC" }
    $s = $setSync.Invoke(1, $hSync, 0)
    return $(if ($s -eq 0) { "OK" } else { "FAILED_$s" })
}

function Do-SyncDisable {
    param([IntPtr]$hSync)
    $setSync = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GSync_SetSyncStateSettings]) ([uint32][NvAPI]::ID_GSync_SetSyncState)
    if ($null -eq $setSync) { return "ERROR_NO_FUNC" }
    $s = $setSync.Invoke(0, $hSync, 0)
    return $(if ($s -eq 0) { "OK" } else { "FAILED_$s" })
}

function Get-FinalSyncStatus {
    param([IntPtr]$hSync)
    $getSyncSt = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GSync_GetSyncStatus]) ([uint32][NvAPI]::ID_GSync_GetSyncStatus)
    if ($null -eq $getSyncSt) { return "UNKNOWN" }
    $st = New-Object NvAPI+NV_GSYNC_STATUS
    $st.version = 0x00010000 -bor 16
    $s = $getSyncSt.Invoke($hSync, [ref]$st)
    if ($s -eq 0) { return $(if ($st.bIsSynced -ne 0) { "OK" } else { "LOST" }) }
    return "UNKNOWN"
}

function Get-FinalEdidStatus {
    param([IntPtr]$hGpu, [uint32]$oid)
    $getEdid = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GPU_GetEDID]) ([uint32][NvAPI]::ID_GPU_GetEDID)
    if ($null -eq $getEdid) { return "UNKNOWN" }
    $edid = New-Object NvAPI+NV_EDID
    $edid.edidData = New-Object byte[] 256
    $edid.version = 0x00030000 -bor 276
    $edid.offset = 0
    $s = $getEdid.Invoke($hGpu, $oid, [ref]$edid)
    if ($s -eq 0 -and $edid.sizeofEDID -gt 0) { return "OK" } else { return "MISSING" }
}

# ── Main ──

$result = @{
    action        = $Action
    output_id     = [int]$OutputId
    edid_result   = "SKIPPED"
    sync_result   = "SKIPPED"
    edid_status   = "UNKNOWN"
    sync_status   = "UNKNOWN"
}

try {
    if (-not (Init-NvAPI)) {
        $result.edid_result = "ERROR_NO_NVAPI"
        $result | ConvertTo-Json -Compress
        exit
    }

    $hGpu = Get-Gpu
    if ($null -eq $hGpu) {
        $result.edid_result = "ERROR_NO_GPU"
        $result | ConvertTo-Json -Compress
        exit
    }

    $oid = Resolve-OutputId -hGpu $hGpu -requestedId ([uint32]$OutputId)
    $hSync = Get-SyncHandle

    switch ($Action) {
        "edid_load" {
            $result.edid_result = Do-EdidLoad -hGpu $hGpu -oid $oid
            Start-Sleep -Milliseconds 300
            $result.edid_status = Get-FinalEdidStatus -hGpu $hGpu -oid $oid
        }
        "edid_unload" {
            $result.edid_result = Do-EdidUnload -hGpu $hGpu -oid $oid
            Start-Sleep -Milliseconds 300
            $result.edid_status = Get-FinalEdidStatus -hGpu $hGpu -oid $oid
        }
        "sync_enable" {
            if ($null -ne $hSync) {
                $result.sync_result = Do-SyncEnable -hSync $hSync
                Start-Sleep -Milliseconds 500
                $result.sync_status = Get-FinalSyncStatus -hSync $hSync
            } else {
                $result.sync_result = "NO_SYNC_DEVICE"
            }
        }
        "sync_disable" {
            if ($null -ne $hSync) {
                $result.sync_result = Do-SyncDisable -hSync $hSync
                Start-Sleep -Milliseconds 500
                $result.sync_status = Get-FinalSyncStatus -hSync $hSync
            } else {
                $result.sync_result = "NO_SYNC_DEVICE"
            }
        }
        "quick_fix" {
            # EDID reload on target port
            $result.edid_result = Do-EdidLoad -hGpu $hGpu -oid $oid
            Start-Sleep -Milliseconds 500

            # Sync re-enable
            if ($null -ne $hSync) {
                $result.sync_result = Do-SyncEnable -hSync $hSync
                Start-Sleep -Milliseconds 500
                $result.sync_status = Get-FinalSyncStatus -hSync $hSync
            } else {
                $result.sync_result = "NO_SYNC_DEVICE"
            }

            $result.edid_status = Get-FinalEdidStatus -hGpu $hGpu -oid $oid
        }
        default {
            $result.edid_result = "UNKNOWN_ACTION"
        }
    }
} catch {
    $result.edid_result = "EXCEPTION"
    $result.sync_result = "EXCEPTION"
}

$result | ConvertTo-Json -Compress
