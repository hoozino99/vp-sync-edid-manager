# get_status.ps1 — Based on verified nvcombo.ps1 + JSON output
$ErrorActionPreference = "Continue"
try {
    Add-Type -IgnoreWarnings -WarningAction SilentlyContinue -TypeDefinition @'
#pragma warning disable CS0168
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NvComboJ {
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

        var ge = (Del_GetEdid)Marshal.GetDelegateForFunctionPointer(QueryInterface(0x37D32E69), typeof(Del_GetEdid));
        uint[] outs = {256,512,1024,2048,4096,8192,16384,32768};
        string[] ports = {"DP-0","DP-1","DP-2","DP-3","DP-4","DP-5","DP-6","DP-7"};
        int[] rets = new int[8];
        for (int i = 0; i < 8; i++) {
            IntPtr buf = Marshal.AllocHGlobal(512);
            for (int j = 0; j < 512; j++) Marshal.WriteByte(buf, j, 0);
            Marshal.WriteInt32(buf, 0, unchecked((int)(0x00030000u | 272u)));
            rets[i] = ge(gpus[0], outs[i], buf);
            Marshal.FreeHGlobal(buf);
        }

        IntPtr[] sh = new IntPtr[4]; int sc = 0;
        var es = (Del_EnumSync)Marshal.GetDelegateForFunctionPointer(QueryInterface(0xD9639601), typeof(Del_EnumSync));
        es(sh, ref sc);

        // Build JSON
        StringBuilder o = new StringBuilder(1024);
        o.Append("{\"gpu_name\":\"");
        o.Append(gpuName);
        o.Append("\",\"displays\":[");
        bool firstD = true;
        for (int i = 0; i < 8; i++) {
            if ((allMask & outs[i]) == 0) continue;
            if (!firstD) o.Append(",");
            firstD = false;
            bool ok = (rets[i] == 0);
            o.Append("{\"port\":\"");
            o.Append(ports[i]);
            o.Append("\",\"output_id\":");
            o.Append(outs[i]);
            o.Append(",\"connected\":");
            o.Append(ok ? "true" : "false");
            o.Append(",\"edid_status\":\"");
            o.Append(ok ? "OK" : "MISSING");
            o.Append("\"}");
        }
        o.Append("],\"sync\":{\"device_found\":");
        o.Append(sc > 0 ? "true" : "false");
        o.Append(",\"sync_status\":\"");
        o.Append(sc > 0 ? "ACTIVE" : "UNKNOWN");
        o.Append("\",\"house_sync_incoming\":false,\"sync_source\":\"UNKNOWN\",\"device_count\":");
        o.Append(sc);
        o.Append("},\"edid_status\":\"");
        bool anyOk = false;
        for (int k = 0; k < 8; k++) { if (rets[k] == 0) anyOk = true; }
        o.Append(anyOk ? "OK" : "UNKNOWN");
        o.Append("\",\"sync_status\":\"");
        o.Append(sc > 0 ? "ACTIVE" : "UNKNOWN");
        o.Append("\"}");
        return o.ToString();
    }
}
'@
    Write-Output ([NvComboJ]::GetStatus())
} catch {
    Write-Output ("{`"error`":`"PS: " + $_.Exception.Message.Replace('"',"'") + "`"}")
}
