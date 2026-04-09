# get_status.ps1 — Full NVAPI status with Sync Lock + Hz + House Sync + EDID
$ErrorActionPreference = "Continue"
try {
    Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @'
#pragma warning disable CS0168
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NvFull2 {
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
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GetSyncStatus(IntPtr hSync, IntPtr hGpu, IntPtr status);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate int Del_GetStatusParams(IntPtr hSync, IntPtr p);

    public static string GetStatus() {
        var init = (Del_Init)Marshal.GetDelegateForFunctionPointer(QueryInterface(0x0150E828), typeof(Del_Init));
        if (init() != 0) return "{\"error\":\"INIT_FAIL\"}";

        IntPtr[] gpus = new IntPtr[64]; int cnt = 0;
        var eg = (Del_EnumGPUs)Marshal.GetDelegateForFunctionPointer(QueryInterface(0xE5AC921F), typeof(Del_EnumGPUs));
        eg(gpus, ref cnt);
        if (cnt == 0) return "{\"error\":\"NO_GPU\"}";

        StringBuilder sb = new StringBuilder(64);
        var gn = (Del_GetName)Marshal.GetDelegateForFunctionPointer(QueryInterface(0xCEEE8E9F), typeof(Del_GetName));
        gn(gpus[0], sb);
        string gpuName = sb.ToString();

        uint allMask = 0;
        var fa = (Del_AllOut)Marshal.GetDelegateForFunctionPointer(QueryInterface(0x7D554F8E), typeof(Del_AllOut));
        fa(gpus[0], ref allMask);
        if (allMask == 0) allMask = 0xFF00;

        // EDID per port
        var ge = (Del_GetEdid)Marshal.GetDelegateForFunctionPointer(QueryInterface(0x37D32E69), typeof(Del_GetEdid));
        uint[] outs = {256,512,1024,2048,4096,8192,16384,32768};
        string[] ports = {"DP-0","DP-1","DP-2","DP-3","DP-4","DP-5","DP-6","DP-7"};
        int[] rets = new int[8];
        string[] edidNames = new string[8];
        for (int i = 0; i < 8; i++) {
            edidNames[i] = "";
            IntPtr buf = Marshal.AllocHGlobal(512);
            for (int k = 0; k < 512; k++) Marshal.WriteByte(buf, k, 0);
            Marshal.WriteInt32(buf, 0, unchecked((int)(0x00030000u | 272u)));
            rets[i] = ge(gpus[0], outs[i], buf);
            if (rets[i] == 0) {
                try {
                    byte[] edid = new byte[256];
                    Marshal.Copy(IntPtr.Add(buf, 4), edid, 0, 256);
                    int mfgCode = (edid[8] << 8) | edid[9];
                    char mc1 = (char)(((mfgCode >> 10) & 0x1F) + 'A' - 1);
                    char mc2 = (char)(((mfgCode >> 5) & 0x1F) + 'A' - 1);
                    char mc3 = (char)((mfgCode & 0x1F) + 'A' - 1);
                    string mfgStr = "" + mc1 + mc2 + mc3;
                    string monName = "";
                    for (int d = 0; d < 4; d++) {
                        int doff = 54 + d * 18;
                        if (edid[doff] == 0 && edid[doff+1] == 0 && edid[doff+3] == 0xFC) {
                            StringBuilder nm = new StringBuilder();
                            for (int p = 5; p < 18; p++) {
                                byte b = edid[doff + p];
                                if (b == 0x0A || b == 0) break;
                                nm.Append((char)b);
                            }
                            monName = nm.ToString().Trim();
                        }
                    }
                    edidNames[i] = mfgStr + " " + monName;
                } catch { edidNames[i] = ""; }
            }
            Marshal.FreeHGlobal(buf);
        }

        // Sync
        bool syncFound = false;
        int syncCnt = 0;
        int synced = 0;
        int houseSyncFlag = 0;
        int refreshRate = 0;
        int houseIncoming = 0;
        int bHouseSync = 0;
        string syncStatus = "UNKNOWN";

        IntPtr pEnumSync = QueryInterface(0xD9639601);
        if (pEnumSync != IntPtr.Zero) {
            var es = (Del_EnumSync)Marshal.GetDelegateForFunctionPointer(pEnumSync, typeof(Del_EnumSync));
            IntPtr[] sh = new IntPtr[4]; int sc = 0;
            if (es(sh, ref sc) == 0 && sc > 0) {
                syncFound = true;
                syncCnt = sc;

                // GetSyncStatus — correct ID 0xF1F5B434, 3 params (hSync, hGpu, status)
                IntPtr pSyncSt = QueryInterface(0xF1F5B434);
                if (pSyncSt != IntPtr.Zero) {
                    var fnSt = (Del_GetSyncStatus)Marshal.GetDelegateForFunctionPointer(pSyncSt, typeof(Del_GetSyncStatus));
                    IntPtr stBuf = Marshal.AllocHGlobal(64);
                    for (int k = 0; k < 64; k++) Marshal.WriteByte(stBuf, k, 0);
                    Marshal.WriteInt32(stBuf, 0, (int)(0x00010000 | 16));
                    int stRet = fnSt(sh[0], gpus[0], stBuf);
                    if (stRet == 0) {
                        synced = Marshal.ReadInt32(stBuf, 4);
                        houseSyncFlag = Marshal.ReadInt32(stBuf, 12);
                        syncStatus = (synced != 0) ? "LOCKED" : "UNLOCKED";
                    }
                    Marshal.FreeHGlobal(stBuf);
                }

                // GetStatusParameters — 0x70D404EC (refreshRate, houseIncoming, bHouseSync)
                IntPtr pStatP = QueryInterface(0x70D404EC);
                if (pStatP != IntPtr.Zero) {
                    var fnSP = (Del_GetStatusParams)Marshal.GetDelegateForFunctionPointer(pStatP, typeof(Del_GetStatusParams));
                    IntPtr spBuf = Marshal.AllocHGlobal(64);
                    for (int k = 0; k < 64; k++) Marshal.WriteByte(spBuf, k, 0);
                    Marshal.WriteInt32(spBuf, 0, (int)(0x00010000 | 32));
                    int spRet = fnSP(sh[0], spBuf);
                    if (spRet == 0) {
                        refreshRate = Marshal.ReadInt32(spBuf, 4);
                        houseIncoming = Marshal.ReadInt32(spBuf, 24);
                        bHouseSync = Marshal.ReadInt32(spBuf, 28);
                    }
                    Marshal.FreeHGlobal(spBuf);
                }
            }
        }

        // Build JSON
        StringBuilder o = new StringBuilder(1024);
        o.Append("{\"gpu_name\":\"");
        o.Append(gpuName);
        o.Append("\",\"displays\":[");
        bool firstD = true;
        bool anyOk = false;
        int portIdx = 0;
        for (int i = 0; i < 8; i++) {
            if ((allMask & outs[i]) == 0) continue;
            if (!firstD) o.Append(",");
            firstD = false;
            bool ok = (rets[i] == 0);
            if (ok) anyOk = true;
            o.Append("{\"port\":\"");
            o.Append(ports[i]);
            o.Append("\",\"output_id\":");
            o.Append(outs[i]);
            o.Append(",\"connected\":");
            o.Append(ok ? "true" : "false");
            o.Append(",\"edid_status\":\"");
            o.Append(ok ? "OK" : "MISSING");
            o.Append("\",\"edid_name\":\"");
            o.Append(edidNames[i].Replace("\"", "'"));
            o.Append("\"}");
            portIdx++;
        }
        o.Append("],\"sync\":{\"device_found\":");
        o.Append(syncFound ? "true" : "false");
        o.Append(",\"sync_status\":\"");
        o.Append(syncStatus);
        o.Append("\",\"house_sync_incoming\":");
        o.Append((houseSyncFlag != 0 || bHouseSync != 0) ? "true" : "false");
        o.Append(",\"sync_source\":\"");
        o.Append(bHouseSync != 0 ? "HOUSE" : "INTERNAL");
        o.Append("\",\"device_count\":");
        o.Append(syncCnt);
        o.Append(",\"refresh_rate\":");
        o.Append(refreshRate);
        o.Append(",\"house_incoming_rate\":");
        o.Append(houseIncoming);
        o.Append(",\"synced\":");
        o.Append(synced != 0 ? "true" : "false");
        o.Append("},\"edid_status\":\"");
        o.Append(anyOk ? "OK" : "UNKNOWN");
        o.Append("\",\"sync_status\":\"");
        o.Append(syncStatus);
        o.Append("\"}");
        return o.ToString();
    }
}
'@
    Write-Output ([NvFull2]::GetStatus())
} catch {
    Write-Output ("{`"error`":`"PS: " + $_.Exception.Message.Replace('"',"'") + "`"}")
}
