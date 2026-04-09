# get_status.ps1 — NVAPI IntPtr-only implementation (no C# structs)
# All NVAPI calls use Marshal.AllocHGlobal + ReadInt32/WriteByte only.
$ErrorActionPreference = "Stop"

Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @"
#pragma warning disable CS0168
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NvAPI {
    [DllImport("nvapi64.dll", EntryPoint="nvapi_QueryInterface", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr QueryInterface(uint id);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_Init();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_EnumGPUs([MarshalAs(UnmanagedType.LPArray, SizeConst=64)] IntPtr[] h, ref int c);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GetName(IntPtr h, StringBuilder n);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_AllOut(IntPtr h, ref uint mask);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_ConnOut(IntPtr h, uint flags, ref uint mask);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GetEdid(IntPtr hGpu, uint outId, IntPtr edidBuf);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_EnumSync([MarshalAs(UnmanagedType.LPArray, SizeConst=4)] IntPtr[] h, ref int c);

    const uint ID_Init     = 0x0150E828;
    const uint ID_EnumGPUs = 0xE5AC921F;
    const uint ID_GetName  = 0xCEEE8E9F;
    const uint ID_AllOut   = 0x7D554F8E;
    const uint ID_ConnOut  = 0x1730BFC9;
    const uint ID_GetEdid  = 0x37D32E69;
    const uint ID_EnumSync = 0xD9639601;

    static Delegate GetFn(uint id, Type t) {
        IntPtr ptr = QueryInterface(id);
        if (ptr == IntPtr.Zero) return null;
        return Marshal.GetDelegateForFunctionPointer(ptr, t);
    }

    public static string GetStatus() {
        try {
            // 1. Initialize
            var init = (Del_Init)GetFn(ID_Init, typeof(Del_Init));
            if (init == null) return "{\"error\":\"INIT_NULL\"}";
            int initRet = init();
            if (initRet != 0) return "{\"error\":\"INIT_FAIL\",\"code\":" + initRet + "}";

            // 2. Enum GPUs
            IntPtr[] gpus = new IntPtr[64];
            int gpuCount = 0;
            var enumG = (Del_EnumGPUs)GetFn(ID_EnumGPUs, typeof(Del_EnumGPUs));
            if (enumG == null) return "{\"error\":\"ENUM_GPU_NULL\"}";
            int enumRet = enumG(gpus, ref gpuCount);
            if (enumRet != 0 || gpuCount == 0) return "{\"error\":\"NO_GPU\",\"code\":" + enumRet + ",\"count\":" + gpuCount + "}";
            IntPtr hGpu = gpus[0];

            // 3. GPU Name
            string gpuName = "UNKNOWN";
            var getName = (Del_GetName)GetFn(ID_GetName, typeof(Del_GetName));
            if (getName != null) {
                StringBuilder sb = new StringBuilder(64);
                if (getName(hGpu, sb) == 0) gpuName = sb.ToString();
            }

            // 4. All outputs mask
            uint allMask = 0;
            var fnAll = (Del_AllOut)GetFn(ID_AllOut, typeof(Del_AllOut));
            if (fnAll != null) fnAll(hGpu, ref allMask);
            if (allMask == 0) allMask = 0xFF00; // RTX 6000 Ada fallback (8 DP ports)

            // 5. Connected outputs — try flags=1 then flags=0
            uint connMask = 0;
            int connRet = -1;
            var fnConn = (Del_ConnOut)GetFn(ID_ConnOut, typeof(Del_ConnOut));
            if (fnConn != null) {
                connRet = fnConn(hGpu, 1, ref connMask);
                if (connRet != 0) {
                    connMask = 0;
                    connRet = fnConn(hGpu, 0, ref connMask);
                }
            }

            // 6. EDID per output — IntPtr buffer only!
            var fnEdid = (Del_GetEdid)GetFn(ID_GetEdid, typeof(Del_GetEdid));

            StringBuilder json = new StringBuilder();
            json.Append("{");
            json.Append("\"gpu_name\":\"" + gpuName.Replace("\"", "") + "\"");
            json.Append(",\"all_outputs_mask\":" + allMask);
            json.Append(",\"connected_outputs_mask\":" + connMask);
            json.Append(",\"connected_outputs_ret\":" + connRet);

            // displays array
            json.Append(",\"displays\":[");
            int portIdx = 0;
            bool first = true;
            bool anyOk = false, anyMissing = false;

            for (int bit = 0; bit < 32; bit++) {
                uint outId = (uint)(1 << bit);
                if ((allMask & outId) == 0) continue;

                bool connected = (connMask & outId) != 0;
                string edidSt = "N/A";
                int edidRet = -999;
                int edidSize = 0;

                if (fnEdid != null) {
                    IntPtr buf = Marshal.AllocHGlobal(512);
                    try {
                        // Zero fill
                        for (int i = 0; i < 512; i++) Marshal.WriteByte(buf, i, 0);
                        // Write version: v3 | 272
                        Marshal.WriteInt32(buf, 0, unchecked((int)(0x00030000 | 272)));

                        edidRet = fnEdid(hGpu, outId, buf);

                        if (edidRet == 0) {
                            edidSt = "OK";
                            anyOk = true;
                            connected = true; // EDID present = connected
                            // Read sizeofEDID at offset 260
                            edidSize = Marshal.ReadInt32(buf, 260);
                        } else {
                            edidSt = "MISSING";
                        }
                    } finally {
                        Marshal.FreeHGlobal(buf);
                    }
                }

                if (connected && edidSt == "MISSING") anyMissing = true;

                if (!first) json.Append(",");
                first = false;
                json.Append("{\"port\":\"DP-" + portIdx + "\"");
                json.Append(",\"output_id\":" + outId);
                json.Append(",\"connected\":" + (connected ? "true" : "false"));
                json.Append(",\"edid_status\":\"" + edidSt + "\"");
                json.Append(",\"edid_ret\":" + edidRet);
                if (edidSize > 0) json.Append(",\"edid_size\":" + edidSize);
                json.Append("}");
                portIdx++;
            }
            json.Append("]");

            // Overall EDID status
            string overallEdid = "UNKNOWN";
            if (anyMissing) overallEdid = "MISSING";
            else if (anyOk) overallEdid = "OK";

            // 7. Sync — EnumDevices only (GetSyncStatus=null, GetControlParams=-9)
            bool syncDeviceFound = false;
            int syncDeviceCount = 0;
            string syncStatus = "UNKNOWN";

            var fnEnumSync = (Del_EnumSync)GetFn(ID_EnumSync, typeof(Del_EnumSync));
            if (fnEnumSync != null) {
                IntPtr[] syncH = new IntPtr[4];
                int syncCnt = 0;
                if (fnEnumSync(syncH, ref syncCnt) == 0 && syncCnt > 0) {
                    syncDeviceFound = true;
                    syncDeviceCount = syncCnt;
                    syncStatus = "ACTIVE";
                }
            }

            json.Append(",\"sync\":{");
            json.Append("\"device_found\":" + (syncDeviceFound ? "true" : "false"));
            json.Append(",\"sync_status\":\"" + syncStatus + "\"");
            json.Append(",\"house_sync_incoming\":false");
            json.Append(",\"sync_source\":\"UNKNOWN\"");
            json.Append(",\"device_count\":" + syncDeviceCount);
            json.Append("}");

            json.Append(",\"edid_status\":\"" + overallEdid + "\"");
            json.Append(",\"sync_status\":\"" + syncStatus + "\"");
            json.Append("}");

            return json.ToString();
        } catch (Exception ex) {
            return "{\"error\":\"EXCEPTION\",\"message\":\"" + ex.Message.Replace("\"", "'").Replace("\\", "/") + "\"}";
        }
    }
}
"@

Write-Output ([NvAPI]::GetStatus())
