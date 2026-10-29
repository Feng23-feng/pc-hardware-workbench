// Windows native probe declarations used by collect-windows.ps1.
// Display configuration, DXGI output, and active-monitor native probes.
// This file is read-only and performs no network or configuration changes.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public sealed class CodexHdrPathInfo
{
    public string GdiDeviceName { get; set; }
    public int QueryResult { get; set; }
    public bool Supported { get; set; }
    public bool Enabled { get; set; }
    public bool WideColorEnforced { get; set; }
    public bool ForceDisabled { get; set; }
    public uint BitsPerColorChannel { get; set; }
    public int ColorEncoding { get; set; }
}

public static class CodexDisplayConfigReader
{
    private const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;
    private const int GET_SOURCE_NAME = 1;
    private const int GET_ADVANCED_COLOR_INFO = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RATIONAL
    {
        public uint Numerator;
        public uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SOURCE_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TARGET_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public RATIONAL refreshRate;
        public uint scanLineOrdering;
        public int targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PATH_INFO
    {
        public SOURCE_INFO sourceInfo;
        public TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MODE_INFO
    {
        public int infoType;
        public uint id;
        public LUID adapterId;

        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 48)]
        public byte[] info;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DEVICE_INFO_HEADER
    {
        public int type;
        public uint size;
        public LUID adapterId;
        public uint id;
    }

    [StructLayout(
        LayoutKind.Sequential,
        CharSet = CharSet.Unicode)]
    private struct SOURCE_DEVICE_NAME
    {
        public DEVICE_INFO_HEADER header;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string viewGdiDeviceName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct TARGET_ADVANCED_COLOR_INFO
    {
        public DEVICE_INFO_HEADER header;
        public uint value;
        public int colorEncoding;
        public uint bitsPerColorChannel;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(
        uint flags,
        out uint pathCount,
        out uint modeCount);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(
        uint flags,
        ref uint pathCount,
        [Out] PATH_INFO[] paths,
        ref uint modeCount,
        [Out] MODE_INFO[] modes,
        IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(
        ref SOURCE_DEVICE_NAME packet);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(
        ref TARGET_ADVANCED_COLOR_INFO packet);

    public static List<CodexHdrPathInfo> Read()
    {
        List<CodexHdrPathInfo> result =
            new List<CodexHdrPathInfo>();

        for (int attempt = 0; attempt < 3; attempt++)
        {
            uint pathCount;
            uint modeCount;
            int code = GetDisplayConfigBufferSizes(
                QDC_ONLY_ACTIVE_PATHS,
                out pathCount,
                out modeCount);
            if (code != 0)
                throw new InvalidOperationException(
                    "GetDisplayConfigBufferSizes: " + code);

            PATH_INFO[] paths = new PATH_INFO[pathCount];
            MODE_INFO[] modes = new MODE_INFO[modeCount];
            code = QueryDisplayConfig(
                QDC_ONLY_ACTIVE_PATHS,
                ref pathCount,
                paths,
                ref modeCount,
                modes,
                IntPtr.Zero);

            if (code == ERROR_INSUFFICIENT_BUFFER)
                continue;
            if (code != 0)
                throw new InvalidOperationException(
                    "QueryDisplayConfig: " + code);

            for (int index = 0; index < pathCount; index++)
            {
                SOURCE_DEVICE_NAME source = new SOURCE_DEVICE_NAME();
                source.header.type = GET_SOURCE_NAME;
                source.header.size =
                    (uint)Marshal.SizeOf(typeof(SOURCE_DEVICE_NAME));
                source.header.adapterId =
                    paths[index].sourceInfo.adapterId;
                source.header.id = paths[index].sourceInfo.id;

                code = DisplayConfigGetDeviceInfo(ref source);
                if (code != 0) continue;

                TARGET_ADVANCED_COLOR_INFO color =
                    new TARGET_ADVANCED_COLOR_INFO();
                color.header.type = GET_ADVANCED_COLOR_INFO;
                color.header.size =
                    (uint)Marshal.SizeOf(
                        typeof(TARGET_ADVANCED_COLOR_INFO));
                color.header.adapterId =
                    paths[index].targetInfo.adapterId;
                color.header.id = paths[index].targetInfo.id;

                int colorResult =
                    DisplayConfigGetDeviceInfo(ref color);
                result.Add(new CodexHdrPathInfo
                {
                    GdiDeviceName = source.viewGdiDeviceName,
                    QueryResult = colorResult,
                    Supported =
                        colorResult == 0 && (color.value & 1) != 0,
                    Enabled =
                        colorResult == 0 && (color.value & 2) != 0,
                    WideColorEnforced =
                        colorResult == 0 && (color.value & 4) != 0,
                    ForceDisabled =
                        colorResult == 0 && (color.value & 8) != 0,
                    BitsPerColorChannel =
                        colorResult == 0
                            ? color.bitsPerColorChannel
                            : 0,
                    ColorEncoding =
                        colorResult == 0
                            ? color.colorEncoding
                            : -1
                });
            }

            return result;
        }

        throw new InvalidOperationException(
            "Active display configuration changed repeatedly.");
    }
}

public sealed class CodexDxgiOutputInfo
{
    public string DeviceName { get; set; }
    public uint BitsPerColor { get; set; }
    public int ColorSpace { get; set; }
    public float MaxLuminance { get; set; }
    public float MaxFullFrameLuminance { get; set; }
}

public static class CodexDxgiOutputReader
{
    private static readonly Guid IID_IDXGIFactory1 =
        new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
    private static readonly Guid IID_IDXGIOutput6 =
        new Guid("068346e8-aaec-4b84-add7-137f513f77a1");

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(
        LayoutKind.Sequential,
        CharSet = CharSet.Unicode)]
    private struct DXGI_OUTPUT_DESC1
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;

        public RECT DesktopCoordinates;
        public int AttachedToDesktop;
        public int Rotation;
        public IntPtr Monitor;
        public uint BitsPerColor;
        public int ColorSpace;
        public float RedPrimaryX;
        public float RedPrimaryY;
        public float GreenPrimaryX;
        public float GreenPrimaryY;
        public float BluePrimaryX;
        public float BluePrimaryY;
        public float WhitePointX;
        public float WhitePointY;
        public float MinLuminance;
        public float MaxLuminance;
        public float MaxFullFrameLuminance;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int EnumAdapters1Delegate(
        IntPtr instance,
        uint index,
        out IntPtr adapter);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int EnumOutputsDelegate(
        IntPtr instance,
        uint index,
        out IntPtr output);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int QueryInterfaceDelegate(
        IntPtr instance,
        ref Guid interfaceId,
        out IntPtr result);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetDesc1Delegate(
        IntPtr instance,
        out DXGI_OUTPUT_DESC1 description);

    [DllImport("dxgi.dll")]
    private static extern int CreateDXGIFactory1(
        ref Guid interfaceId,
        out IntPtr factory);

    private static T GetVtableDelegate<T>(
        IntPtr instance,
        int slot) where T : class
    {
        IntPtr vtable = Marshal.ReadIntPtr(instance);
        IntPtr function = Marshal.ReadIntPtr(
            vtable,
            slot * IntPtr.Size);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(
            function,
            typeof(T));
    }

    public static List<CodexDxgiOutputInfo> Read()
    {
        List<CodexDxgiOutputInfo> result =
            new List<CodexDxgiOutputInfo>();
        Guid factoryId = IID_IDXGIFactory1;
        IntPtr factory;
        int resultCode = CreateDXGIFactory1(
            ref factoryId,
            out factory);
        if (resultCode != 0)
            throw new InvalidOperationException(
                "CreateDXGIFactory1: " + resultCode);

        try
        {
            EnumAdapters1Delegate enumAdapters =
                GetVtableDelegate<EnumAdapters1Delegate>(
                    factory,
                    12);

            for (uint adapterIndex = 0; ; adapterIndex++)
            {
                IntPtr adapter;
                if (enumAdapters(
                        factory,
                        adapterIndex,
                        out adapter) != 0)
                    break;

                try
                {
                    EnumOutputsDelegate enumOutputs =
                        GetVtableDelegate<EnumOutputsDelegate>(
                            adapter,
                            7);

                    for (uint outputIndex = 0; ; outputIndex++)
                    {
                        IntPtr output;
                        if (enumOutputs(
                                adapter,
                                outputIndex,
                                out output) != 0)
                            break;

                        try
                        {
                            QueryInterfaceDelegate queryInterface =
                                GetVtableDelegate<QueryInterfaceDelegate>(
                                    output,
                                    0);
                            Guid output6Id = IID_IDXGIOutput6;
                            IntPtr output6;
                            if (queryInterface(
                                    output,
                                    ref output6Id,
                                    out output6) != 0)
                                continue;

                            try
                            {
                                GetDesc1Delegate getDesc1 =
                                    GetVtableDelegate<GetDesc1Delegate>(
                                        output6,
                                        27);
                                DXGI_OUTPUT_DESC1 description;
                                if (getDesc1(
                                        output6,
                                        out description) == 0)
                                {
                                    result.Add(
                                        new CodexDxgiOutputInfo
                                        {
                                            DeviceName =
                                                description.DeviceName,
                                            BitsPerColor =
                                                description.BitsPerColor,
                                            ColorSpace =
                                                description.ColorSpace,
                                            MaxLuminance =
                                                description.MaxLuminance,
                                            MaxFullFrameLuminance =
                                                description
                                                    .MaxFullFrameLuminance
                                        });
                                }
                            }
                            finally
                            {
                                Marshal.Release(output6);
                            }
                        }
                        finally
                        {
                            Marshal.Release(output);
                        }
                    }
                }
                finally
                {
                    Marshal.Release(adapter);
                }
            }
        }
        finally
        {
            Marshal.Release(factory);
        }

        return result;
    }
}

public sealed class CodexActiveDisplay
{
    public string AdapterName { get; set; }
    public string Model { get; set; }
    public string ProductCode { get; set; }
    public uint CurrentWidth { get; set; }
    public uint CurrentHeight { get; set; }
    public uint CurrentRefreshHz { get; set; }
    public uint BitsPerPixel { get; set; }
    public bool? HdrSupported { get; set; }
    public bool? HdrEnabled { get; set; }
    public bool? AdvancedColorEnabled { get; set; }
    public bool? WideColorEnforced { get; set; }
    public bool? AdvancedColorForceDisabled { get; set; }
    public uint AdvancedColorBitsPerColorChannel { get; set; }
    public int AdvancedColorEncoding { get; set; }
    public int HdrQueryResult { get; set; }
    public string DisplayColorSpace { get; set; }
    public int DxgiColorSpace { get; set; }
    public uint DxgiBitsPerColor { get; set; }
    public float MaxLuminance { get; set; }
    public float MaxFullFrameLuminance { get; set; }
}

public static class CodexActiveDisplayReader
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAY_DEVICE
    {
        public int cb;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;

        public int StateFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public uint dmDisplayOrientation;
        public uint dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;

        public ushort dmLogPixels;
        public uint dmBitsPerPel;
        public uint dmPelsWidth;
        public uint dmPelsHeight;
        public uint dmDisplayFlags;
        public uint dmDisplayFrequency;
        public uint dmICMMethod;
        public uint dmICMIntent;
        public uint dmMediaType;
        public uint dmDitherType;
        public uint dmReserved1;
        public uint dmReserved2;
        public uint dmPanningWidth;
        public uint dmPanningHeight;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplayDevices(
        string device,
        uint deviceIndex,
        ref DISPLAY_DEVICE displayDevice,
        uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool EnumDisplaySettingsEx(
        string deviceName,
        int modeNumber,
        ref DEVMODE devMode,
        uint flags);

    private static string ReadProductCode(string deviceId)
    {
        if (string.IsNullOrWhiteSpace(deviceId))
            return string.Empty;

        const string marker = "MONITOR\\";
        int start = deviceId.IndexOf(
            marker,
            StringComparison.OrdinalIgnoreCase);
        if (start < 0) return string.Empty;

        start += marker.Length;
        int end = deviceId.IndexOf('\\', start);
        return end < 0
            ? deviceId.Substring(start)
            : deviceId.Substring(start, end - start);
    }

    public static List<CodexActiveDisplay> Read()
    {
        List<CodexActiveDisplay> result =
            new List<CodexActiveDisplay>();
        HashSet<string> seen = new HashSet<string>(
            StringComparer.OrdinalIgnoreCase);
        Dictionary<string, CodexHdrPathInfo> hdrBySource =
            new Dictionary<string, CodexHdrPathInfo>(
                StringComparer.OrdinalIgnoreCase);
        Dictionary<string, CodexDxgiOutputInfo> dxgiByDevice =
            new Dictionary<string, CodexDxgiOutputInfo>(
                StringComparer.OrdinalIgnoreCase);

        try
        {
            foreach (CodexHdrPathInfo hdr in
                CodexDisplayConfigReader.Read())
            {
                if (!string.IsNullOrEmpty(hdr.GdiDeviceName))
                    hdrBySource[hdr.GdiDeviceName] = hdr;
            }
        }
        catch
        {
            // Monitor enumeration remains useful without HDR metadata.
        }

        try
        {
            foreach (CodexDxgiOutputInfo output in
                CodexDxgiOutputReader.Read())
            {
                if (!string.IsNullOrEmpty(output.DeviceName))
                    dxgiByDevice[output.DeviceName] = output;
            }
        }
        catch
        {
            // HDR output state remains unavailable if DXGI cannot be read.
        }

        for (uint adapterIndex = 0; ; adapterIndex++)
        {
            DISPLAY_DEVICE adapter = new DISPLAY_DEVICE();
            adapter.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));

            if (!EnumDisplayDevices(
                    null,
                    adapterIndex,
                    ref adapter,
                    0))
                break;

            if ((adapter.StateFlags & 1) == 0)
                continue;

            DEVMODE currentMode = new DEVMODE();
            currentMode.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            bool hasCurrentMode = EnumDisplaySettingsEx(
                adapter.DeviceName,
                -1,
                ref currentMode,
                0);
            CodexHdrPathInfo hdr = null;
            hdrBySource.TryGetValue(adapter.DeviceName, out hdr);
            CodexDxgiOutputInfo dxgi = null;
            dxgiByDevice.TryGetValue(adapter.DeviceName, out dxgi);

            bool isHdrColorSpace = dxgi != null &&
                (dxgi.ColorSpace == 1 ||
                 dxgi.ColorSpace == 12 ||
                 dxgi.ColorSpace == 13 ||
                 dxgi.ColorSpace == 14 ||
                 dxgi.ColorSpace == 16 ||
                 dxgi.ColorSpace == 18 ||
                 dxgi.ColorSpace == 19 ||
                 dxgi.ColorSpace == 25);

            for (uint monitorIndex = 0; ; monitorIndex++)
            {
                DISPLAY_DEVICE monitor = new DISPLAY_DEVICE();
                monitor.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));

                if (!EnumDisplayDevices(
                        adapter.DeviceName,
                        monitorIndex,
                        ref monitor,
                        0))
                    break;

                if ((monitor.StateFlags & 1) == 0)
                    continue;

                string productCode = ReadProductCode(monitor.DeviceID);
                string key = productCode + "|" + monitor.DeviceString;
                if (!seen.Add(key))
                    continue;

                result.Add(new CodexActiveDisplay
                {
                    AdapterName = adapter.DeviceString,
                    Model = monitor.DeviceString,
                    ProductCode = productCode,
                    CurrentWidth = hasCurrentMode
                        ? currentMode.dmPelsWidth
                        : 0,
                    CurrentHeight = hasCurrentMode
                        ? currentMode.dmPelsHeight
                        : 0,
                    CurrentRefreshHz =
                        hasCurrentMode &&
                        currentMode.dmDisplayFrequency > 1
                            ? currentMode.dmDisplayFrequency
                            : 0,
                    BitsPerPixel = hasCurrentMode
                        ? currentMode.dmBitsPerPel
                        : 0,
                    HdrSupported = hdr == null
                        ? (bool?)null
                        : hdr.QueryResult == 0
                            ? (bool?)hdr.Supported
                            : (bool?)null,
                    HdrEnabled = hdr == null
                        ? (bool?)null
                        : hdr.QueryResult == 0 && dxgi != null
                            ? (bool?)isHdrColorSpace
                            : (bool?)null,
                    AdvancedColorEnabled = hdr == null
                        ? (bool?)null
                        : hdr.QueryResult == 0
                            ? (bool?)hdr.Enabled
                            : (bool?)null,
                    WideColorEnforced = hdr == null
                        ? (bool?)null
                        : hdr.QueryResult == 0
                            ? (bool?)hdr.WideColorEnforced
                            : (bool?)null,
                    AdvancedColorForceDisabled = hdr == null
                        ? (bool?)null
                        : hdr.QueryResult == 0
                            ? (bool?)hdr.ForceDisabled
                            : (bool?)null,
                    AdvancedColorBitsPerColorChannel =
                        hdr == null ? 0 : hdr.BitsPerColorChannel,
                    AdvancedColorEncoding =
                        hdr == null ? -1 : hdr.ColorEncoding,
                    HdrQueryResult =
                        hdr == null ? -1 : hdr.QueryResult,
                    DisplayColorSpace =
                        dxgi == null
                            ? null
                            : dxgi.ColorSpace.ToString(),
                    DxgiColorSpace =
                        dxgi == null ? -1 : dxgi.ColorSpace,
                    DxgiBitsPerColor =
                        dxgi == null ? 0 : dxgi.BitsPerColor,
                    MaxLuminance =
                        dxgi == null ? 0 : dxgi.MaxLuminance,
                    MaxFullFrameLuminance =
                        dxgi == null
                            ? 0
                            : dxgi.MaxFullFrameLuminance
                });
            }
        }

        return result;
    }
}
