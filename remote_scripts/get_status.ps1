# get_status.ps1 — Built from verified working test scripts (nvsafe + nvedid4)
$ErrorActionPreference = "Continue"
try {
    Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @'
#pragma warning disable CS0168
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NvStatus {
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
    public delegate int Del_GetEdid(IntPtr hGpu, uint outId, IntPtr edid);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_EnumSync([MarshalAs(UnmanagedType.LPArray, SizeConst=4)] IntPtr[] h, ref int c);

    public static string GetStatus() {
        try {
            // Init
            IntPtr p = QueryInterface(0x0150E828);
            if (p == IntPtr.Zero) return "{\"error\":\"NO_NVAPI\"}";
            var init = (Del_Init)Marshal.GetDelegateForFunctionPointer(p, typeof(Del_Init));
            if (init() != 0) return "{\"error\":\"INIT_FAIL\"}";

            // GPUs
            IntPtr[] gpus = new IntPtr[64]; int cnt = 0;
            var enumG = (Del_EnumGPUs)Marshal.GetDelegateForFunctionPointer(QueryInterface(0xE5AC921F), typeof(Del_EnumGPUs));
            enumG(gpus, ref cnt);
            if (cnt == 0) return "{\"error\":\"NO_GPU\"}";

            // Name
            string gpuName = "UNKNOWN";
            IntPtr pName = QueryInterface(0xCEEE8E9F);
            if (pName != IntPtr.Zero) {
                var getName = (Del_GetName)Marshal.GetDelegateForFunctionPointer(pName, typeof(Del_GetName));
                StringBuilder sb = new StringBuilder(64);
                if (getName(gpus[0], sb) == 0) gpuName = sb.ToString();
            }

            // AllOutputs
            uint allMask = 0;
            IntPtr pAll = QueryInterface(0x7D554F8E);
            if (pAll != IntPtr.Zero) {
                var fnAll = (Del_AllOut)Marshal.GetDelegateForFunctionPointer(pAll, typeof(Del_AllOut));
                fnAll(gpus[0], ref allMask);
            }
            if (allMask == 0) allMask = 0xFF00;

            // EDID per port
            IntPtr pEdid = QueryInterface(0x37D32E69);
            StringBuilder dj = new StringBuilder();
            dj.Append("[");
            bool firstD = true;
            bool anyOk = false;
            int portIdx = 0;

            uint[] outputs = {256,512,1024,2048,4096,8192,16384,32768};
            for (int i = 0; i < outputs.Length; i++) {
                uint outId = outputs[i];
                if ((allMask & outId) == 0) continue;

                bool connected = false;
                string edidSt = "N/A";
                int edidRet = -999;

                if (pEdid != IntPtr.Zero) {
                    var fnEdid = (Del_GetEdid)Marshal.GetDelegateForFunctionPointer(pEdid, typeof(Del_GetEdid));
                    IntPtr buf = Marshal.AllocHGlobal(512);
                    for (int j = 0; j < 512; j++) Marshal.WriteByte(buf, j, 0);
                    Marshal.WriteInt32(buf, 0, unchecked((int)(0x00030000u | 272u)));
                    edidRet = fnEdid(gpus[0], outId, buf);
                    if (edidRet == 0) {
                        edidSt = "OK";
                        anyOk = true;
                        connected = true;
                    } else {
                        edidSt = "MISSING";
                    }
                    Marshal.FreeHGlobal(buf);
                }

                if (!firstD) dj.Append(",");
                firstD = false;
                dj.Append("{\"port\":\"DP-" + portIdx + "\"");
                dj.Append(",\"output_id\":" + outId);
                dj.Append(",\"connected\":" + (connected ? "true" : "false"));
                dj.Append(",\"edid_status\":\"" + edidSt + "\"");
                dj.Append(",\"edid_ret\":" + edidRet + "}");
                portIdx++;
            }
            dj.Append("]");

            // Sync
            bool syncFound = false;
            int syncCnt = 0;
            IntPtr pSync = QueryInterface(0xD9639601);
            if (pSync != IntPtr.Zero) {
                var fnSync = (Del_EnumSync)Marshal.GetDelegateForFunctionPointer(pSync, typeof(Del_EnumSync));
                IntPtr[] sh = new IntPtr[4];
                int sc = 0;
                if (fnSync(sh, ref sc) == 0 && sc > 0) {
                    syncFound = true;
                    syncCnt = sc;
                }
            }

            string syncSt = syncFound ? "ACTIVE" : "UNKNOWN";
            string edidOv = anyOk ? "OK" : "UNKNOWN";

            StringBuilder j2 = new StringBuilder();
            j2.Append("{\"gpu_name\":\"" + gpuName.Replace("\"","") + "\"");
            j2.Append(",\"displays\":" + dj.ToString());
            j2.Append(",\"sync\":{\"device_found\":" + (syncFound ? "true" : "false"));
            j2.Append(",\"sync_status\":\"" + syncSt + "\"");
            j2.Append(",\"house_sync_incoming\":false");
            j2.Append(",\"sync_source\":\"UNKNOWN\"");
            j2.Append(",\"device_count\":" + syncCnt + "}");
            j2.Append(",\"edid_status\":\"" + edidOv + "\"");
            j2.Append(",\"sync_status\":\"" + syncSt + "\"}");
            return j2.ToString();
        } catch (Exception ex) {
            return "{\"error\":\"" + ex.Message.Replace("\"","'").Replace("\\","/") + "\"}";
        }
    }
}
'@
    Write-Output ([NvStatus]::GetStatus())
} catch {
    Write-Output ("{`"error`":`"PS_ERROR: " + $_.Exception.Message.Replace('"',"'") + "`"}")
}
