# get_status.ps1 — Enhanced GPU/EDID/Sync status with per-port detail
# Outputs JSON: { gpu_name, displays: [{port, output_id, edid_status, connected}], sync: {...}, edid_status, sync_status }

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NvAPI
{
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr QueryInterface(uint id);

    // Function IDs
    public const uint ID_Initialize          = 0x0150E828;
    public const uint ID_EnumPhysicalGPUs    = 0xE5AC921F;
    public const uint ID_GPU_GetFullName     = 0xCEEE8E9F;
    public const uint ID_GPU_GetEDID         = 0x37D32E69;
    public const uint ID_GPU_GetAllOutputs   = 0x7D554F8E;
    public const uint ID_GPU_GetConnectedOutputs = 0x1730BFC9;
    public const uint ID_GSync_EnumDevices   = 0xD9639601;
    public const uint ID_GSync_GetSyncStatus = 0x2AE50D0D;
    public const uint ID_GSync_GetControlParams = 0x16DE1C6A;

    // Delegates
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_Initialize();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_EnumPhysicalGPUs(
        [MarshalAs(UnmanagedType.LPArray, SizeConst = 64)] IntPtr[] handles, ref int count);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GPU_GetFullName(IntPtr hGpu, StringBuilder name);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GPU_GetAllOutputs(IntPtr hGpu, ref uint outputsMask);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GPU_GetConnectedOutputs(IntPtr hGpu, uint flags, ref uint outputsMask);

    // NV_EDID v3
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

    // GSync status
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

    // GSync control parameters
    [StructLayout(LayoutKind.Sequential)]
    public struct NV_GSYNC_CONTROL_PARAMS
    {
        public uint version;
        public uint polarity;
        public uint vmode;
        public uint interval;
        public uint source;       // 0=internal, 1=house
        public uint interlaceMode;
        public uint syncSkew;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int NvAPI_GSync_GetControlParams(IntPtr hDevice, ref NV_GSYNC_CONTROL_PARAMS p);

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


function Get-NvStatus {
    $result = @{
        gpu_name    = "UNKNOWN"
        displays    = @()
        sync        = @{
            device_found       = $false
            sync_status        = "UNKNOWN"
            house_sync_incoming = $false
            sync_source        = "UNKNOWN"
        }
        edid_status = "UNKNOWN"
        sync_status = "UNKNOWN"
    }

    try {
        # Initialize NVAPI
        $init = Invoke-NvAPIDelegate ([NvAPI+NvAPI_Initialize]) ([uint32][NvAPI]::ID_Initialize)
        if ($null -eq $init) { $result.edid_status = "ERROR_NO_NVAPI"; return $result }
        $s = $init.Invoke()
        if ($s -ne 0) { $result.edid_status = "ERROR_INIT_$s"; return $result }

        # Enumerate GPUs
        $gpuHandles = New-Object IntPtr[] 64
        [int]$gpuCount = 0
        $enumGpus = Invoke-NvAPIDelegate ([NvAPI+NvAPI_EnumPhysicalGPUs]) ([uint32][NvAPI]::ID_EnumPhysicalGPUs)
        $s = $enumGpus.Invoke($gpuHandles, [ref]$gpuCount)
        if ($s -ne 0 -or $gpuCount -eq 0) { $result.edid_status = "ERROR_ENUM_GPU"; return $result }

        $hGpu = $gpuHandles[0]

        # GPU name
        $getName = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GPU_GetFullName]) ([uint32][NvAPI]::ID_GPU_GetFullName)
        if ($null -ne $getName) {
            $sb = New-Object System.Text.StringBuilder 64
            $getName.Invoke($hGpu, $sb) | Out-Null
            $result.gpu_name = $sb.ToString()
        }

        # Get all outputs and connected outputs
        $getAllOutputs = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GPU_GetAllOutputs]) ([uint32][NvAPI]::ID_GPU_GetAllOutputs)
        $getConnected = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GPU_GetConnectedOutputs]) ([uint32][NvAPI]::ID_GPU_GetConnectedOutputs)
        $getEdid = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GPU_GetEDID]) ([uint32][NvAPI]::ID_GPU_GetEDID)

        [uint32]$allMask = 0
        [uint32]$connMask = 0

        if ($null -ne $getAllOutputs) {
            $getAllOutputs.Invoke($hGpu, [ref]$allMask) | Out-Null
        }
        if ($null -ne $getConnected) {
            $getConnected.Invoke($hGpu, 0, [ref]$connMask) | Out-Null
        }

        # If we couldn't get output masks, try DP-0 through DP-7 by brute force
        if ($allMask -eq 0) { $allMask = 0xFF }

        $displays = @()
        $anyEdidOk = $false
        $anyEdidMissing = $false
        $portIndex = 0

        for ($bit = 0; $bit -lt 32; $bit++) {
            $outputId = [uint32](1 -shl $bit)
            if (($allMask -band $outputId) -eq 0) { continue }

            $connected = (($connMask -band $outputId) -ne 0)
            $portName = "DP-$portIndex"
            $edidSt = "N/A"

            if ($null -ne $getEdid) {
                $edid = New-Object NvAPI+NV_EDID
                $edid.edidData = New-Object byte[] 256
                $edid.version = 0x00030000 -bor 276
                $edid.sizeofEDID = 0
                $edid.offset = 0
                $es = $getEdid.Invoke($hGpu, $outputId, [ref]$edid)
                if ($es -eq 0 -and $edid.sizeofEDID -gt 0) {
                    $edidSt = "OK"
                    $anyEdidOk = $true
                } else {
                    $edidSt = "MISSING"
                    if ($connected) { $anyEdidMissing = $true }
                }
            }

            $displays += @{
                port      = $portName
                output_id = [int]$outputId
                connected = $connected
                edid_status = $edidSt
            }
            $portIndex++
        }

        $result.displays = $displays
        # Overall EDID status (backward compat)
        if ($anyEdidMissing) { $result.edid_status = "MISSING" }
        elseif ($anyEdidOk) { $result.edid_status = "OK" }

        # ── GSync ──
        $enumSync = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GSync_EnumDevices]) ([uint32][NvAPI]::ID_GSync_EnumDevices)
        if ($null -ne $enumSync) {
            $syncHandles = New-Object IntPtr[] 4
            [int]$syncCount = 0
            $s = $enumSync.Invoke($syncHandles, [ref]$syncCount)

            if ($s -eq 0 -and $syncCount -gt 0) {
                $result.sync.device_found = $true
                $hSync = $syncHandles[0]

                # Sync status (locked / house sync)
                $getSyncSt = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GSync_GetSyncStatus]) ([uint32][NvAPI]::ID_GSync_GetSyncStatus)
                if ($null -ne $getSyncSt) {
                    $syncSt = New-Object NvAPI+NV_GSYNC_STATUS
                    $syncSt.version = 0x00010000 -bor 16
                    $s = $getSyncSt.Invoke($hSync, [ref]$syncSt)
                    if ($s -eq 0) {
                        $locked = ($syncSt.bIsSynced -ne 0)
                        $result.sync.sync_status = if ($locked) { "OK" } else { "LOST" }
                        $result.sync.house_sync_incoming = ($syncSt.bHouseSyncIncoming -ne 0)
                        $result.sync_status = $result.sync.sync_status
                    }
                }

                # Control parameters (sync source → master/slave hint)
                $getCtrl = Invoke-NvAPIDelegate ([NvAPI+NvAPI_GSync_GetControlParams]) ([uint32][NvAPI]::ID_GSync_GetControlParams)
                if ($null -ne $getCtrl) {
                    $cp = New-Object NvAPI+NV_GSYNC_CONTROL_PARAMS
                    $cp.version = 0x00010000 -bor 28
                    $s = $getCtrl.Invoke($hSync, [ref]$cp)
                    if ($s -eq 0) {
                        $result.sync.sync_source = if ($cp.source -eq 0) { "INTERNAL" } else { "HOUSE" }
                    }
                }
            } else {
                $result.sync.device_found = $false
                $result.sync_status = "NO_DEVICE"
            }
        }
    } catch {
        $result.edid_status = "ERROR"
        $result.sync_status = "ERROR"
    }

    return $result
}

$status = Get-NvStatus
$status | ConvertTo-Json -Depth 3 -Compress
