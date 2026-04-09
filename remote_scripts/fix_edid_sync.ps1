# fix_edid_sync.ps1 — EDID/Sync operations via NVAPI (IntPtr-only, no ref struct)
# Parameters injected by node_remote.py:
#   $Action   = "quick_fix" | "edid_load" | "edid_unload" | "sync_enable" | "sync_disable"
#   $OutputId = <uint32 display output id> (0 = first connected output)
#   $EdidData = <base64 string> (edid_load only)
# Outputs JSON result.

$ErrorActionPreference = "Stop"

if (-not (Test-Path variable:Action))   { $Action = "quick_fix" }
if (-not (Test-Path variable:OutputId)) { $OutputId = 0 }
if (-not (Test-Path variable:EdidData)) { $EdidData = "" }

Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @"
#pragma warning disable CS0168
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public class NvActionV2
{
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr QueryInterface(uint id);

    // Function IDs
    const uint ID_Initialize         = 0x0150E828;
    const uint ID_EnumPhysicalGPUs   = 0xE5AC921F;
    const uint ID_GPU_GetAllOutputs  = 0x7D554F8E;
    const uint ID_GPU_GetEDID        = 0x37D32E69;
    const uint ID_GPU_SetEDID        = 0xE83D6456;
    const uint ID_GSync_EnumDevices  = 0xD9639601;
    const uint ID_GSync_GetTopology  = 0x4562BC38;
    const uint ID_GSync_SetSyncState = 0x60ACDFDD;
    const uint ID_GSync_GetSyncStatus    = 0xF1F5B434;
    const uint ID_GSync_GetStatusParams  = 0x70D404EC;
    const uint ID_GSync_GetCapabilities  = 0x44A3F1D1;

    // NV_EDID layout: version(4) + edidData(256) + sizeofEDID(4) + edidId(4) + offset(4) = 272 bytes
    const int EDID_BUF_SIZE = 512;
    const uint EDID_VER = 0x00030000u | 272u;

    // Delegates — all use IntPtr buffers, no ref struct
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_Initialize();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_EnumPhysicalGPUs(IntPtr handleArray, IntPtr countPtr);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_GetAllOutputs(IntPtr hGpu, IntPtr maskPtr);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_GetEDID(IntPtr hGpu, uint outputId, IntPtr edidBuf);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_SetEDID(IntPtr hGpu, uint outputId, IntPtr edidBuf);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_EnumSyncDevices(IntPtr handleArray, IntPtr countPtr);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_GetTopology(IntPtr hSync, IntPtr topoBuf);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_SetSyncState(IntPtr topoBuf, uint topoCount, uint flags);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_GetSyncStatus(IntPtr hSync, IntPtr hGpu, IntPtr statusBuf);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_GetStatusParams(IntPtr hSync, IntPtr paramsBuf);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Del_GetCapabilities(IntPtr hSync, IntPtr capsBuf);

    // Cached
    static IntPtr hGpu = IntPtr.Zero;
    static IntPtr hSync = IntPtr.Zero;
    static bool inited = false;

    static Delegate GetDel(uint id, Type t)
    {
        IntPtr p = QueryInterface(id);
        if (p == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(p, t);
    }

    static string Init()
    {
        if (inited) return null;
        var fnInit = (Del_Initialize)GetDel(ID_Initialize, typeof(Del_Initialize));
        if (fnInit == null) return "NO_NVAPI";
        int r = fnInit();
        if (r != 0) return "INIT_ERR_" + r;

        // Enum GPUs via IntPtr
        IntPtr gpuArr = Marshal.AllocHGlobal(64 * IntPtr.Size);
        IntPtr cntPtr = Marshal.AllocHGlobal(4);
        try {
            for (int z = 0; z < 64 * IntPtr.Size; z++) Marshal.WriteByte(gpuArr, z, 0);
            Marshal.WriteInt32(cntPtr, 0);
            var fnEnum = (Del_EnumPhysicalGPUs)GetDel(ID_EnumPhysicalGPUs, typeof(Del_EnumPhysicalGPUs));
            if (fnEnum == null) return "NO_ENUM";
            r = fnEnum(gpuArr, cntPtr);
            int cnt = Marshal.ReadInt32(cntPtr);
            if (r != 0 || cnt == 0) return "NO_GPU";
            hGpu = Marshal.ReadIntPtr(gpuArr, 0);
        } finally {
            Marshal.FreeHGlobal(gpuArr);
            Marshal.FreeHGlobal(cntPtr);
        }

        // Enum sync devices
        IntPtr syncArr = Marshal.AllocHGlobal(4 * IntPtr.Size);
        IntPtr scntPtr = Marshal.AllocHGlobal(4);
        try {
            for (int z = 0; z < 4 * IntPtr.Size; z++) Marshal.WriteByte(syncArr, z, 0);
            Marshal.WriteInt32(scntPtr, 0);
            var fnES = (Del_EnumSyncDevices)GetDel(ID_GSync_EnumDevices, typeof(Del_EnumSyncDevices));
            if (fnES != null) {
                r = fnES(syncArr, scntPtr);
                int sc = Marshal.ReadInt32(scntPtr);
                if (r == 0 && sc > 0) hSync = Marshal.ReadIntPtr(syncArr, 0);
            }
        } finally {
            Marshal.FreeHGlobal(syncArr);
            Marshal.FreeHGlobal(scntPtr);
        }

        inited = true;
        return null;
    }

    static uint ResolveOutput(uint requested)
    {
        if (requested != 0) return requested;
        var fn = (Del_GetAllOutputs)GetDel(ID_GPU_GetAllOutputs, typeof(Del_GetAllOutputs));
        if (fn == null) return 1;
        IntPtr mp = Marshal.AllocHGlobal(4);
        try {
            Marshal.WriteInt32(mp, 0);
            fn(hGpu, mp);
            uint mask = (uint)Marshal.ReadInt32(mp);
            for (int b = 0; b < 32; b++) {
                uint oid = (uint)(1 << b);
                if ((mask & oid) != 0) return oid;
            }
        } finally { Marshal.FreeHGlobal(mp); }
        return 1;
    }

    // ── EDID Operations (IntPtr only) ──

    static IntPtr MakeEdidBuf(byte[] edidBytes)
    {
        IntPtr buf = Marshal.AllocHGlobal(EDID_BUF_SIZE);
        // Zero fill
        for (int z = 0; z < EDID_BUF_SIZE; z++) Marshal.WriteByte(buf, z, 0);
        // version at offset 0
        Marshal.WriteInt32(buf, 0, (int)EDID_VER);
        if (edidBytes != null && edidBytes.Length > 0) {
            // edidData at offset 4 (max 256 bytes)
            int copyLen = Math.Min(edidBytes.Length, 256);
            Marshal.Copy(edidBytes, 0, IntPtr.Add(buf, 4), copyLen);
            // sizeofEDID at offset 260
            Marshal.WriteInt32(buf, 260, edidBytes.Length);
        }
        // edidId at 264 = 0, offset at 268 = 0 (already zeroed)
        return buf;
    }

    static string DoEdidLoad(uint oid, string edidBase64)
    {
        var fnSet = (Del_SetEDID)GetDel(ID_GPU_SetEDID, typeof(Del_SetEDID));
        if (fnSet == null) return "NO_SETEDID";

        byte[] edidBytes;
        if (!string.IsNullOrEmpty(edidBase64)) {
            // Use provided EDID data
            edidBytes = Convert.FromBase64String(edidBase64);
        } else {
            // Read current EDID and reload it
            var fnGet = (Del_GetEDID)GetDel(ID_GPU_GetEDID, typeof(Del_GetEDID));
            if (fnGet == null) return "NO_GETEDID";
            IntPtr getBuf = MakeEdidBuf(null);
            try {
                int gr = fnGet(hGpu, oid, getBuf);
                int curSize = Marshal.ReadInt32(getBuf, 260);
                if (gr != 0 || curSize == 0) return "NO_EDID_TO_RELOAD";
                edidBytes = new byte[curSize];
                Marshal.Copy(IntPtr.Add(getBuf, 4), edidBytes, 0, curSize);
            } finally { Marshal.FreeHGlobal(getBuf); }

            // Unload first
            IntPtr blankBuf = MakeEdidBuf(null);
            try { fnSet(hGpu, oid, blankBuf); } finally { Marshal.FreeHGlobal(blankBuf); }
            Thread.Sleep(500);
        }

        // Load
        IntPtr loadBuf = MakeEdidBuf(edidBytes);
        try {
            int r = fnSet(hGpu, oid, loadBuf);
            return (r == 0) ? "OK" : "FAILED_" + r;
        } finally { Marshal.FreeHGlobal(loadBuf); }
    }

    static string DoEdidUnload(uint oid)
    {
        var fnSet = (Del_SetEDID)GetDel(ID_GPU_SetEDID, typeof(Del_SetEDID));
        if (fnSet == null) return "NO_SETEDID";
        IntPtr buf = MakeEdidBuf(null);
        try {
            int r = fnSet(hGpu, oid, buf);
            return (r == 0) ? "OK" : "FAILED_" + r;
        } finally { Marshal.FreeHGlobal(buf); }
    }

    // ── Sync Operations (IntPtr only, via GetTopology + SetSyncState) ──

    static string DoSyncEnable()
    {
        if (hSync == IntPtr.Zero) return "NO_SYNC_DEVICE";

        // GetTopology to get current display topology
        var fnTopo = (Del_GetTopology)GetDel(ID_GSync_GetTopology, typeof(Del_GetTopology));
        var fnSet = (Del_SetSyncState)GetDel(ID_GSync_SetSyncState, typeof(Del_SetSyncState));
        if (fnSet == null) return "NO_SETSYNCSTATE";

        // Topology buffer: version(4) + gpuCount(4) + gpu array
        // NV_GSYNC_GPU entry: hGpu(ptr) + connectorCount(4) + connector array
        // We'll allocate a generous buffer
        int topoSize = 4096;
        IntPtr topoBuf = Marshal.AllocHGlobal(topoSize);
        try {
            for (int z = 0; z < topoSize; z++) Marshal.WriteByte(topoBuf, z, 0);
            // version
            Marshal.WriteInt32(topoBuf, 0, (int)(0x00010000u | (uint)topoSize));

            if (fnTopo != null) {
                int tr = fnTopo(hSync, topoBuf);
                // Even if GetTopology fails, try SetSyncState with the sync handle
            }

            // SetSyncState: pass topology buffer, count=1, flags=0
            int r = fnSet(topoBuf, 1, 0);
            return (r == 0) ? "OK" : "FAILED_" + r;
        } finally { Marshal.FreeHGlobal(topoBuf); }
    }

    static string DoSyncDisable()
    {
        if (hSync == IntPtr.Zero) return "NO_SYNC_DEVICE";
        var fnSet = (Del_SetSyncState)GetDel(ID_GSync_SetSyncState, typeof(Del_SetSyncState));
        if (fnSet == null) return "NO_SETSYNCSTATE";

        // Pass empty topology to disable
        int topoSize = 4096;
        IntPtr topoBuf = Marshal.AllocHGlobal(topoSize);
        try {
            for (int z = 0; z < topoSize; z++) Marshal.WriteByte(topoBuf, z, 0);
            Marshal.WriteInt32(topoBuf, 0, (int)(0x00010000u | (uint)topoSize));
            int r = fnSet(topoBuf, 0, 0);
            return (r == 0) ? "OK" : "FAILED_" + r;
        } finally { Marshal.FreeHGlobal(topoBuf); }
    }

    // ── Status checks ──

    static string GetEdidStatus(uint oid)
    {
        var fn = (Del_GetEDID)GetDel(ID_GPU_GetEDID, typeof(Del_GetEDID));
        if (fn == null) return "UNKNOWN";
        IntPtr buf = MakeEdidBuf(null);
        try {
            int r = fn(hGpu, oid, buf);
            int sz = Marshal.ReadInt32(buf, 260);
            return (r == 0 && sz > 0) ? "OK" : "MISSING";
        } finally { Marshal.FreeHGlobal(buf); }
    }

    static string GetSyncStatusStr()
    {
        if (hSync == IntPtr.Zero) return "NO_DEVICE";
        // GetSyncStatus: 3 params (hSync, hGpu, statusBuf)
        var fn = (Del_GetSyncStatus)GetDel(ID_GSync_GetSyncStatus, typeof(Del_GetSyncStatus));
        if (fn == null) return "UNKNOWN";
        // Status buf: version(4) + bIsSynced(4) + bStereoSynced(4) + bHouseSyncIncoming(4) = 16
        IntPtr buf = Marshal.AllocHGlobal(64);
        try {
            for (int z = 0; z < 64; z++) Marshal.WriteByte(buf, z, 0);
            Marshal.WriteInt32(buf, 0, (int)(0x00010000u | 16u));
            int r = fn(hSync, hGpu, buf);
            if (r != 0) return "ERR_" + r;
            int synced = Marshal.ReadInt32(buf, 4);
            return (synced != 0) ? "LOCKED" : "UNLOCKED";
        } finally { Marshal.FreeHGlobal(buf); }
    }

    // ── JSON helpers ──

    static string JStr(string s)
    {
        if (s == null) return "null";
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    static string ResultJson(string action, int outputId,
        string edidResult, string syncResult, string edidStatus, string syncStatus)
    {
        StringBuilder o = new StringBuilder();
        o.Append("{");
        o.Append("\"action\":" + JStr(action));
        o.Append(",\"output_id\":" + outputId);
        o.Append(",\"edid_result\":" + JStr(edidResult));
        o.Append(",\"sync_result\":" + JStr(syncResult));
        o.Append(",\"edid_status\":" + JStr(edidStatus));
        o.Append(",\"sync_status\":" + JStr(syncStatus));
        o.Append("}");
        return o.ToString();
    }

    // ── Public entry point ──
    public static string Execute(string action, uint outputId, string edidBase64)
    {
        string edidResult = "SKIPPED";
        string syncResult = "SKIPPED";
        string edidStatus = "UNKNOWN";
        string syncStatus = "UNKNOWN";

        try
        {
            string err = Init();
            if (err != null)
                return ResultJson(action, (int)outputId, err, "SKIPPED", "UNKNOWN", "UNKNOWN");

            uint oid = ResolveOutput(outputId);

            switch (action)
            {
                case "edid_load":
                    edidResult = DoEdidLoad(oid, edidBase64);
                    Thread.Sleep(300);
                    edidStatus = GetEdidStatus(oid);
                    syncStatus = GetSyncStatusStr();
                    break;

                case "edid_unload":
                    edidResult = DoEdidUnload(oid);
                    Thread.Sleep(300);
                    edidStatus = GetEdidStatus(oid);
                    syncStatus = GetSyncStatusStr();
                    break;

                case "sync_enable":
                    syncResult = DoSyncEnable();
                    Thread.Sleep(500);
                    syncStatus = GetSyncStatusStr();
                    break;

                case "sync_disable":
                    syncResult = DoSyncDisable();
                    Thread.Sleep(500);
                    syncStatus = GetSyncStatusStr();
                    break;

                case "quick_fix":
                    edidResult = DoEdidLoad(oid, "");
                    Thread.Sleep(500);
                    syncResult = DoSyncEnable();
                    Thread.Sleep(500);
                    edidStatus = GetEdidStatus(oid);
                    syncStatus = GetSyncStatusStr();
                    break;

                default:
                    edidResult = "UNKNOWN_ACTION";
                    break;
            }
        }
        catch (Exception ex)
        {
            edidResult = "EXCEPTION";
            syncResult = ex.Message.Length > 80 ? ex.Message.Substring(0, 80) : ex.Message;
        }

        return ResultJson(action, (int)outputId, edidResult, syncResult, edidStatus, syncStatus);
    }
}
"@

Write-Output ([NvActionV2]::Execute($Action, [uint32]$OutputId, $EdidData))
