# get_status.ps1 — Enhanced GPU/EDID/Sync status with per-port detail (C# native)
# All NVAPI logic runs inside C# to avoid MakeGenericMethod issues in remote PS sessions.
# Outputs JSON: { gpu_name, displays: [{port, output_id, edid_status, connected}], sync: {...}, edid_status, sync_status }

$ErrorActionPreference = "Stop"

Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @"
#pragma warning disable CS0168
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NvAPI
{
    [DllImport("nvapi64.dll", EntryPoint = "nvapi_QueryInterface", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr QueryInterface(uint id);

    // Function IDs
    public const uint ID_Initialize              = 0x0150E828;
    public const uint ID_EnumPhysicalGPUs        = 0xE5AC921F;
    public const uint ID_GPU_GetFullName         = 0xCEEE8E9F;
    public const uint ID_GPU_GetEDID             = 0x37D32E69;
    public const uint ID_GPU_GetAllOutputs       = 0x7D554F8E;
    public const uint ID_GPU_GetConnectedOutputs = 0x1730BFC9;
    public const uint ID_GSync_EnumDevices       = 0xD9639601;
    public const uint ID_GSync_GetSyncStatus     = 0x2AE50D0D;
    public const uint ID_GSync_GetControlParams  = 0x16DE1C6A;

    // ── Delegates ──
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_Initialize();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_EnumPhysicalGPUs(
        [MarshalAs(UnmanagedType.LPArray, SizeConst = 64)] IntPtr[] handles, ref int count);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GPU_GetFullName(IntPtr hGpu, StringBuilder name);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GPU_GetAllOutputs(IntPtr hGpu, ref uint outputsMask);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GPU_GetConnectedOutputs(IntPtr hGpu, uint flags, ref uint outputsMask);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GPU_GetEDID(IntPtr hGpu, uint outputId, ref NV_EDID edid);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GSync_EnumDevices(
        [MarshalAs(UnmanagedType.LPArray, SizeConst = 4)] IntPtr[] handles, ref int count);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GSync_GetSyncStatus(IntPtr hDevice, ref NV_GSYNC_STATUS status);

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

    // ── Helper: non-generic GetDelegateForFunctionPointer ──
    private static Delegate GetDelegate(uint id, Type delType)
    {
        IntPtr ptr = QueryInterface(id);
        if (ptr == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(ptr, delType);
    }

    // ── Escape helper for JSON strings ──
    private static string JStr(string s)
    {
        if (s == null) return "null";
        return "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }

    // ── Main status gathering — all NVAPI calls happen here in C# ──
    public static string GetStatus()
    {
        string gpuName = "UNKNOWN";
        string edidStatus = "UNKNOWN";
        string syncStatus = "UNKNOWN";
        bool syncDeviceFound = false;
        string houseSyncIncoming = "false";
        string syncSource = "UNKNOWN";
        string displaysJson = "[]";

        try
        {
            // Initialize
            var fnInit = (Del_Initialize)GetDelegate(ID_Initialize, typeof(Del_Initialize));
            if (fnInit == null) return ErrorJson("ERROR_NO_NVAPI");
            int s = fnInit();
            if (s != 0) return ErrorJson("ERROR_INIT_" + s);

            // Enum GPUs
            IntPtr[] gpuHandles = new IntPtr[64];
            int gpuCount = 0;
            var fnEnumGpus = (Del_EnumPhysicalGPUs)GetDelegate(ID_EnumPhysicalGPUs, typeof(Del_EnumPhysicalGPUs));
            if (fnEnumGpus == null) return ErrorJson("ERROR_NO_ENUM");
            s = fnEnumGpus(gpuHandles, ref gpuCount);
            if (s != 0 || gpuCount == 0) return ErrorJson("ERROR_ENUM_GPU");

            IntPtr hGpu = gpuHandles[0];

            // GPU name
            var fnGetName = (Del_GPU_GetFullName)GetDelegate(ID_GPU_GetFullName, typeof(Del_GPU_GetFullName));
            if (fnGetName != null)
            {
                StringBuilder sb = new StringBuilder(64);
                if (fnGetName(hGpu, sb) == 0) gpuName = sb.ToString();
            }

            // Output masks
            var fnAllOutputs = (Del_GPU_GetAllOutputs)GetDelegate(ID_GPU_GetAllOutputs, typeof(Del_GPU_GetAllOutputs));
            var fnConnOutputs = (Del_GPU_GetConnectedOutputs)GetDelegate(ID_GPU_GetConnectedOutputs, typeof(Del_GPU_GetConnectedOutputs));
            var fnGetEdid = (Del_GPU_GetEDID)GetDelegate(ID_GPU_GetEDID, typeof(Del_GPU_GetEDID));

            uint allMask = 0;
            uint connMask = 0;
            if (fnAllOutputs != null) fnAllOutputs(hGpu, ref allMask);
            // Try flags=1 (uncached), fallback to flags=0
            if (fnConnOutputs != null) {
                int cr = fnConnOutputs(hGpu, 1, ref connMask);
                if (cr != 0) fnConnOutputs(hGpu, 0, ref connMask);
            }
            if (allMask == 0) allMask = 0xFF00; // RTX 6000 Ada uses bits 8-15

            // Enumerate displays
            StringBuilder dJson = new StringBuilder();
            dJson.Append("[");
            bool anyEdidOk = false;
            bool anyEdidMissing = false;
            int portIndex = 0;
            bool firstDisplay = true;

            for (int bit = 0; bit < 32; bit++)
            {
                uint outputId = (uint)(1 << bit);
                if ((allMask & outputId) == 0) continue;

                bool connected = (connMask & outputId) != 0;
                string portName = "DP-" + portIndex;
                string edidSt = "N/A";
                bool hasEdid = false;

                if (fnGetEdid != null)
                {
                    NV_EDID edid = new NV_EDID();
                    edid.edidData = new byte[256];
                    edid.version = 0x00030000 | (uint)Marshal.SizeOf(typeof(NV_EDID));
                    edid.sizeofEDID = 0;
                    edid.offset = 0;
                    int es = fnGetEdid(hGpu, outputId, ref edid);
                    if (es == 0 && edid.sizeofEDID > 0)
                    {
                        edidSt = "OK";
                        anyEdidOk = true;
                        hasEdid = true;
                    }
                    else
                    {
                        edidSt = "MISSING";
                    }
                    // If EDID exists, port is effectively connected
                    if (hasEdid) connected = true;
                    if (!connected && edidSt == "MISSING") anyEdidMissing = false; // don't flag disconnected ports
                    if (connected && edidSt == "MISSING") anyEdidMissing = true;
                }

                if (!firstDisplay) dJson.Append(",");
                firstDisplay = false;
                dJson.Append("{");
                dJson.Append("\"port\":" + JStr(portName));
                dJson.Append(",\"output_id\":" + outputId);
                dJson.Append(",\"connected\":" + (connected ? "true" : "false"));
                dJson.Append(",\"edid_status\":" + JStr(edidSt));
                dJson.Append("}");
                portIndex++;
            }
            dJson.Append("]");
            displaysJson = dJson.ToString();

            // Overall EDID status
            if (anyEdidMissing) edidStatus = "MISSING";
            else if (anyEdidOk) edidStatus = "OK";

            // ── GSync ──
            var fnEnumSync = (Del_GSync_EnumDevices)GetDelegate(ID_GSync_EnumDevices, typeof(Del_GSync_EnumDevices));
            if (fnEnumSync != null)
            {
                IntPtr[] syncHandles = new IntPtr[4];
                int syncCount = 0;
                s = fnEnumSync(syncHandles, ref syncCount);

                if (s == 0 && syncCount > 0)
                {
                    syncDeviceFound = true;
                    IntPtr hSync = syncHandles[0];

                    // Sync status — GetSyncStatus (0x2AE50D0D) returns null ptr
                    // on some drivers (RTX 6000 Ada), so skip it and use GetControlParams
                    var fnGetSyncSt = (Del_GSync_GetSyncStatus)GetDelegate(ID_GSync_GetSyncStatus, typeof(Del_GSync_GetSyncStatus));
                    if (fnGetSyncSt != null)
                    {
                        NV_GSYNC_STATUS st = new NV_GSYNC_STATUS();
                        st.version = 0x00010000 | (uint)Marshal.SizeOf(typeof(NV_GSYNC_STATUS));
                        s = fnGetSyncSt(hSync, ref st);
                        if (s == 0)
                        {
                            syncStatus = (st.bIsSynced != 0) ? "OK" : "LOST";
                            houseSyncIncoming = (st.bHouseSyncIncoming != 0) ? "true" : "false";
                        }
                    }

                    // Control params — this works on RTX 6000 Ada
                    var fnGetCtrl = (Del_GSync_GetControlParams)GetDelegate(ID_GSync_GetControlParams, typeof(Del_GSync_GetControlParams));
                    if (fnGetCtrl != null)
                    {
                        NV_GSYNC_CONTROL_PARAMS cp = new NV_GSYNC_CONTROL_PARAMS();
                        cp.version = 0x00010000 | (uint)Marshal.SizeOf(typeof(NV_GSYNC_CONTROL_PARAMS));
                        s = fnGetCtrl(hSync, ref cp);
                        if (s == 0)
                        {
                            syncSource = (cp.source == 0) ? "INTERNAL" : "HOUSE";
                            // If GetSyncStatus was unavailable, infer sync from device presence + source
                            if (syncStatus == "UNKNOWN")
                            {
                                syncStatus = "ACTIVE";
                                // If source is HOUSE, house sync is incoming
                                if (cp.source == 1) houseSyncIncoming = "true";
                            }
                        }
                    }
                    // If we found a sync device but couldn't query status, mark as active
                    if (syncStatus == "UNKNOWN") syncStatus = "DEVICE_FOUND";
                }
                else
                {
                    syncStatus = "NO_DEVICE";
                }
            }
        }
        catch (Exception)
        {
            edidStatus = "ERROR";
            syncStatus = "ERROR";
        }

        // Build final JSON
        StringBuilder j = new StringBuilder();
        j.Append("{");
        j.Append("\"gpu_name\":" + JStr(gpuName));
        j.Append(",\"displays\":" + displaysJson);
        j.Append(",\"sync\":{");
        j.Append("\"device_found\":" + (syncDeviceFound ? "true" : "false"));
        j.Append(",\"sync_status\":" + JStr(syncStatus));
        j.Append(",\"house_sync_incoming\":" + houseSyncIncoming);
        j.Append(",\"sync_source\":" + JStr(syncSource));
        j.Append("}");
        j.Append(",\"edid_status\":" + JStr(edidStatus));
        j.Append(",\"sync_status\":" + JStr(syncStatus));
        j.Append("}");
        return j.ToString();
    }

    private static string ErrorJson(string edidError)
    {
        StringBuilder j = new StringBuilder();
        j.Append("{");
        j.Append("\"gpu_name\":\"UNKNOWN\"");
        j.Append(",\"displays\":[]");
        j.Append(",\"sync\":{\"device_found\":false,\"sync_status\":\"UNKNOWN\",\"house_sync_incoming\":false,\"sync_source\":\"UNKNOWN\"}");
        j.Append(",\"edid_status\":" + JStr(edidError));
        j.Append(",\"sync_status\":\"UNKNOWN\"");
        j.Append("}");
        return j.ToString();
    }
}
"@

Write-Output ([NvAPI]::GetStatus())
