# fix_edid_sync.ps1 — Parameterized EDID/Sync operations via NVAPI (C# native)
# All NVAPI logic runs inside C# to avoid MakeGenericMethod issues in remote PS sessions.
# Parameters are injected as PowerShell variables by node_remote.py:
#   $Action   = "quick_fix" | "edid_load" | "edid_unload" | "sync_enable" | "sync_disable"
#   $OutputId = <uint32 display output id> (for EDID operations, 0 = first output)
# Outputs JSON result.

$ErrorActionPreference = "Stop"

# Default params (overridden by prepended variable assignments from node_remote.py)
if (-not (Test-Path variable:Action))   { $Action = "quick_fix" }
if (-not (Test-Path variable:OutputId)) { $OutputId = 0 }

Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @"
#pragma warning disable CS0168
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class NvAPI
{
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr QueryInterface(uint id);

    // Function IDs
    public const uint ID_Initialize              = 0x0150E828;
    public const uint ID_EnumPhysicalGPUs        = 0xE5AC921F;
    public const uint ID_GPU_GetEDID             = 0x37D32E69;
    public const uint ID_GPU_SetEDID             = 0xE83D6456;
    public const uint ID_GPU_GetAllOutputs       = 0x7D554F8E;
    public const uint ID_GSync_EnumDevices       = 0xD9639601;
    public const uint ID_GSync_GetSyncStatus     = 0x2AE50D0D;
    public const uint ID_GSync_SetSyncState      = 0x60ACDFDD;
    public const uint ID_GSync_GetControlParams  = 0x16DE1C6A;

    // ── Delegates ──
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_Initialize();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_EnumPhysicalGPUs(
        [MarshalAs(UnmanagedType.LPArray, SizeConst = 64)] IntPtr[] handles, ref int count);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GPU_GetAllOutputs(IntPtr hGpu, ref uint outputsMask);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GPU_GetEDID(IntPtr hGpu, uint outputId, ref NV_EDID edid);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GPU_SetEDID(IntPtr hGpu, uint outputId, ref NV_EDID edid);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GSync_EnumDevices(
        [MarshalAs(UnmanagedType.LPArray, SizeConst = 4)] IntPtr[] handles, ref int count);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GSync_GetSyncStatus(IntPtr hDevice, ref NV_GSYNC_STATUS status);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GSync_SetSyncStateSettings(uint count, IntPtr pTopology, uint flags);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GSync_GetControlParams(IntPtr hDevice, ref NV_GSYNC_CONTROL_PARAMS p);

    // ── Structs ──
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

    [StructLayout(LayoutKind.Sequential)]
    public struct NV_GSYNC_STATUS
    {
        public uint version;
        public uint bIsSynced;
        public uint bStereoSynced;
        public uint bHouseSyncIncoming;
    }

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

    // ── Helper: non-generic delegate resolution ──
    private static Delegate GetDelegate(uint id, Type delType)
    {
        IntPtr ptr = QueryInterface(id);
        if (ptr == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(ptr, delType);
    }

    private static string JStr(string s)
    {
        if (s == null) return "null";
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    // ── Cached handles (set during Init) ──
    private static IntPtr hGpu = IntPtr.Zero;
    private static IntPtr hSync = IntPtr.Zero;
    private static bool initialized = false;

    private static string Init()
    {
        if (initialized) return null;

        var fnInit = (Del_Initialize)GetDelegate(ID_Initialize, typeof(Del_Initialize));
        if (fnInit == null) return "ERROR_NO_NVAPI";
        int s = fnInit();
        if (s != 0) return "ERROR_INIT_" + s;

        // Enum GPUs
        IntPtr[] gpuHandles = new IntPtr[64];
        int gpuCount = 0;
        var fnEnum = (Del_EnumPhysicalGPUs)GetDelegate(ID_EnumPhysicalGPUs, typeof(Del_EnumPhysicalGPUs));
        if (fnEnum == null) return "ERROR_NO_ENUM";
        s = fnEnum(gpuHandles, ref gpuCount);
        if (s != 0 || gpuCount == 0) return "ERROR_NO_GPU";
        hGpu = gpuHandles[0];

        // Enum sync devices
        var fnEnumSync = (Del_GSync_EnumDevices)GetDelegate(ID_GSync_EnumDevices, typeof(Del_GSync_EnumDevices));
        if (fnEnumSync != null)
        {
            IntPtr[] syncHandles = new IntPtr[4];
            int syncCount = 0;
            s = fnEnumSync(syncHandles, ref syncCount);
            if (s == 0 && syncCount > 0) hSync = syncHandles[0];
        }

        initialized = true;
        return null;
    }

    private static uint ResolveOutputId(uint requestedId)
    {
        if (requestedId != 0) return requestedId;
        var fnAll = (Del_GPU_GetAllOutputs)GetDelegate(ID_GPU_GetAllOutputs, typeof(Del_GPU_GetAllOutputs));
        if (fnAll != null)
        {
            uint mask = 0;
            fnAll(hGpu, ref mask);
            if (mask != 0)
            {
                for (int b = 0; b < 32; b++)
                {
                    uint oid = (uint)(1 << b);
                    if ((mask & oid) != 0) return oid;
                }
            }
        }
        return 1;
    }

    private static string DoEdidLoad(uint oid)
    {
        var fnGet = (Del_GPU_GetEDID)GetDelegate(ID_GPU_GetEDID, typeof(Del_GPU_GetEDID));
        var fnSet = (Del_GPU_SetEDID)GetDelegate(ID_GPU_SetEDID, typeof(Del_GPU_SetEDID));
        if (fnGet == null || fnSet == null) return "ERROR_NO_FUNC";

        // Read current EDID
        NV_EDID edid = new NV_EDID();
        edid.edidData = new byte[256];
        edid.version = 0x00030000 | 276;
        edid.sizeofEDID = 0;
        edid.offset = 0;
        int s = fnGet(hGpu, oid, ref edid);
        if (s != 0 || edid.sizeofEDID == 0) return "NO_EDID_TO_RELOAD";

        byte[] savedData = (byte[])edid.edidData.Clone();
        uint savedSize = edid.sizeofEDID;

        // Unload
        NV_EDID blank = new NV_EDID();
        blank.edidData = new byte[256];
        blank.version = 0x00030000 | 276;
        blank.sizeofEDID = 0;
        fnSet(hGpu, oid, ref blank);
        Thread.Sleep(500);

        // Reload
        NV_EDID reload = new NV_EDID();
        reload.edidData = savedData;
        reload.version = 0x00030000 | 276;
        reload.sizeofEDID = savedSize;
        reload.offset = 0;
        s = fnSet(hGpu, oid, ref reload);
        return (s == 0) ? "OK" : "FAILED_" + s;
    }

    private static string DoEdidUnload(uint oid)
    {
        var fnSet = (Del_GPU_SetEDID)GetDelegate(ID_GPU_SetEDID, typeof(Del_GPU_SetEDID));
        if (fnSet == null) return "ERROR_NO_FUNC";

        NV_EDID blank = new NV_EDID();
        blank.edidData = new byte[256];
        blank.version = 0x00030000 | 276;
        blank.sizeofEDID = 0;
        int s = fnSet(hGpu, oid, ref blank);
        return (s == 0) ? "OK" : "FAILED_" + s;
    }

    private static string DoSyncEnable()
    {
        if (hSync == IntPtr.Zero) return "NO_SYNC_DEVICE";
        var fnSet = (Del_GSync_SetSyncStateSettings)GetDelegate(ID_GSync_SetSyncState, typeof(Del_GSync_SetSyncStateSettings));
        if (fnSet == null) return "ERROR_NO_FUNC";
        int s = fnSet(1, hSync, 0);
        return (s == 0) ? "OK" : "FAILED_" + s;
    }

    private static string DoSyncDisable()
    {
        if (hSync == IntPtr.Zero) return "NO_SYNC_DEVICE";
        var fnSet = (Del_GSync_SetSyncStateSettings)GetDelegate(ID_GSync_SetSyncState, typeof(Del_GSync_SetSyncStateSettings));
        if (fnSet == null) return "ERROR_NO_FUNC";
        int s = fnSet(0, hSync, 0);
        return (s == 0) ? "OK" : "FAILED_" + s;
    }

    private static string GetEdidStatus(uint oid)
    {
        var fnGet = (Del_GPU_GetEDID)GetDelegate(ID_GPU_GetEDID, typeof(Del_GPU_GetEDID));
        if (fnGet == null) return "UNKNOWN";
        NV_EDID edid = new NV_EDID();
        edid.edidData = new byte[256];
        edid.version = 0x00030000 | 276;
        edid.offset = 0;
        int s = fnGet(hGpu, oid, ref edid);
        return (s == 0 && edid.sizeofEDID > 0) ? "OK" : "MISSING";
    }

    private static string GetSyncStatus()
    {
        if (hSync == IntPtr.Zero) return "UNKNOWN";
        var fnGet = (Del_GSync_GetSyncStatus)GetDelegate(ID_GSync_GetSyncStatus, typeof(Del_GSync_GetSyncStatus));
        if (fnGet == null) return "UNKNOWN";
        NV_GSYNC_STATUS st = new NV_GSYNC_STATUS();
        st.version = 0x00010000 | 16;
        int s = fnGet(hSync, ref st);
        if (s == 0) return (st.bIsSynced != 0) ? "OK" : "LOST";
        return "UNKNOWN";
    }

    // ── Public entry point called from PowerShell ──
    public static string FixEdidSync(string action, uint outputId)
    {
        string edidResult = "SKIPPED";
        string syncResult = "SKIPPED";
        string edidStatus = "UNKNOWN";
        string syncStatus = "UNKNOWN";

        try
        {
            string err = Init();
            if (err != null)
            {
                return ResultJson(action, (int)outputId, err, "SKIPPED", "UNKNOWN", "UNKNOWN");
            }

            uint oid = ResolveOutputId(outputId);

            switch (action)
            {
                case "edid_load":
                    edidResult = DoEdidLoad(oid);
                    Thread.Sleep(300);
                    edidStatus = GetEdidStatus(oid);
                    break;

                case "edid_unload":
                    edidResult = DoEdidUnload(oid);
                    Thread.Sleep(300);
                    edidStatus = GetEdidStatus(oid);
                    break;

                case "sync_enable":
                    syncResult = DoSyncEnable();
                    Thread.Sleep(500);
                    syncStatus = GetSyncStatus();
                    break;

                case "sync_disable":
                    syncResult = DoSyncDisable();
                    Thread.Sleep(500);
                    syncStatus = GetSyncStatus();
                    break;

                case "quick_fix":
                    edidResult = DoEdidLoad(oid);
                    Thread.Sleep(500);
                    syncResult = DoSyncEnable();
                    Thread.Sleep(500);
                    syncStatus = GetSyncStatus();
                    edidStatus = GetEdidStatus(oid);
                    break;

                default:
                    edidResult = "UNKNOWN_ACTION";
                    break;
            }
        }
        catch (Exception)
        {
            edidResult = "EXCEPTION";
            syncResult = "EXCEPTION";
        }

        return ResultJson(action, (int)outputId, edidResult, syncResult, edidStatus, syncStatus);
    }

    private static string ResultJson(string action, int outputId,
        string edidResult, string syncResult, string edidStatus, string syncStatus)
    {
        StringBuilder j = new StringBuilder();
        j.Append("{");
        j.Append("\"action\":" + JStr(action));
        j.Append(",\"output_id\":" + outputId);
        j.Append(",\"edid_result\":" + JStr(edidResult));
        j.Append(",\"sync_result\":" + JStr(syncResult));
        j.Append(",\"edid_status\":" + JStr(edidStatus));
        j.Append(",\"sync_status\":" + JStr(syncStatus));
        j.Append("}");
        return j.ToString();
    }
}
"@

Write-Output ([NvAPI]::FixEdidSync($Action, [uint32]$OutputId))
