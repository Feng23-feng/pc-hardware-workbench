// Windows native probe declarations used by collect-windows.ps1.
// Storage device, descriptor, and volume-mapping native probes.
// This file is read-only and performs no network or configuration changes.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class CodexActiveDiskDevice
{
    public string Model { get; set; }
    public string Description { get; set; }
    public string Service { get; set; }
}

public static class CodexActiveDiskReader
{
    private const uint DIGCF_PRESENT = 0x00000002;
    private const uint SPDRP_DEVICEDESC = 0x00000000;
    private const uint SPDRP_SERVICE = 0x00000004;
    private const uint SPDRP_FRIENDLYNAME = 0x0000000C;
    private static readonly Guid DiskClass =
        new Guid("4d36e967-e325-11ce-bfc1-08002be10318");

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [DllImport(
        "setupapi.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(
        ref Guid classGuid,
        IntPtr enumerator,
        IntPtr parentWindow,
        uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInfo(
        IntPtr deviceInfoSet,
        uint memberIndex,
        ref SP_DEVINFO_DATA deviceInfoData);

    [DllImport(
        "setupapi.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    private static extern bool SetupDiGetDeviceRegistryProperty(
        IntPtr deviceInfoSet,
        ref SP_DEVINFO_DATA deviceInfoData,
        uint property,
        out uint propertyRegDataType,
        byte[] propertyBuffer,
        uint propertyBufferSize,
        out uint requiredSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(
        IntPtr deviceInfoSet);

    private static string GetProperty(
        IntPtr deviceInfoSet,
        ref SP_DEVINFO_DATA deviceInfoData,
        uint property)
    {
        uint propertyType;
        uint requiredSize;
        SetupDiGetDeviceRegistryProperty(
            deviceInfoSet,
            ref deviceInfoData,
            property,
            out propertyType,
            null,
            0,
            out requiredSize);

        if (requiredSize == 0) return string.Empty;

        byte[] buffer = new byte[requiredSize];
        if (!SetupDiGetDeviceRegistryProperty(
                deviceInfoSet,
                ref deviceInfoData,
                property,
                out propertyType,
                buffer,
                requiredSize,
                out requiredSize))
            return string.Empty;

        return Encoding.Unicode.GetString(buffer).TrimEnd('\0');
    }

    public static List<CodexActiveDiskDevice> Read()
    {
        List<CodexActiveDiskDevice> devices =
            new List<CodexActiveDiskDevice>();
        Guid classGuid = DiskClass;
        IntPtr deviceInfoSet = SetupDiGetClassDevs(
            ref classGuid,
            IntPtr.Zero,
            IntPtr.Zero,
            DIGCF_PRESENT);

        if (deviceInfoSet == IntPtr.Zero ||
            deviceInfoSet == new IntPtr(-1))
            return devices;

        try
        {
            for (uint index = 0; ; index++)
            {
                SP_DEVINFO_DATA deviceInfoData =
                    new SP_DEVINFO_DATA();
                deviceInfoData.cbSize =
                    (uint)Marshal.SizeOf(deviceInfoData);

                if (!SetupDiEnumDeviceInfo(
                        deviceInfoSet,
                        index,
                        ref deviceInfoData))
                    break;

                string friendlyName = GetProperty(
                    deviceInfoSet,
                    ref deviceInfoData,
                    SPDRP_FRIENDLYNAME);
                string description = GetProperty(
                    deviceInfoSet,
                    ref deviceInfoData,
                    SPDRP_DEVICEDESC);
                string service = GetProperty(
                    deviceInfoSet,
                    ref deviceInfoData,
                    SPDRP_SERVICE);

                devices.Add(new CodexActiveDiskDevice
                {
                    Model = friendlyName.Length > 0
                        ? friendlyName
                        : description,
                    Description = description,
                    Service = service
                });
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(deviceInfoSet);
        }

        return devices;
    }
}

public sealed class CodexPhysicalDiskDescriptor
{
    public uint DeviceNumber { get; set; }
    public string VendorId { get; set; }
    public string ProductId { get; set; }
    public string ProductRevision { get; set; }
    public uint BusType { get; set; }
}

public static class CodexPhysicalDiskDescriptorReader
{
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;
    private const uint StorageDeviceProperty = 0;
    private const uint PropertyStandardQuery = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct STORAGE_PROPERTY_QUERY
    {
        public uint PropertyId;
        public uint QueryType;
        public byte AdditionalParameters;
    }

    [DllImport(
        "kernel32.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device,
        uint ioControlCode,
        ref STORAGE_PROPERTY_QUERY inputBuffer,
        uint inputBufferSize,
        byte[] outputBuffer,
        uint outputBufferSize,
        out uint bytesReturned,
        IntPtr overlapped);

    private static string ReadString(byte[] data, int offset)
    {
        if (offset <= 0 || offset >= data.Length) return string.Empty;
        int end = offset;
        while (end < data.Length && data[end] != 0) end++;
        return Encoding.ASCII.GetString(
            data,
            offset,
            end - offset).Trim();
    }

    public static List<CodexPhysicalDiskDescriptor> Read()
    {
        List<CodexPhysicalDiskDescriptor> result =
            new List<CodexPhysicalDiskDescriptor>();

        for (uint diskNumber = 0; diskNumber < 64; diskNumber++)
        {
            string path = "\\\\.\\PhysicalDrive" + diskNumber;
            using (SafeFileHandle handle = CreateFile(
                path,
                0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                0,
                IntPtr.Zero))
            {
                if (handle.IsInvalid) continue;

                STORAGE_PROPERTY_QUERY query =
                    new STORAGE_PROPERTY_QUERY
                    {
                        PropertyId = StorageDeviceProperty,
                        QueryType = PropertyStandardQuery
                    };
                byte[] buffer = new byte[1024];
                uint returned;

                if (!DeviceIoControl(
                        handle,
                        IOCTL_STORAGE_QUERY_PROPERTY,
                        ref query,
                        (uint)Marshal.SizeOf(query),
                        buffer,
                        (uint)buffer.Length,
                        out returned,
                        IntPtr.Zero) ||
                    returned < 32)
                    continue;

                result.Add(new CodexPhysicalDiskDescriptor
                {
                    DeviceNumber = diskNumber,
                    VendorId = ReadString(
                        buffer,
                        BitConverter.ToInt32(buffer, 12)),
                    ProductId = ReadString(
                        buffer,
                        BitConverter.ToInt32(buffer, 16)),
                    ProductRevision = ReadString(
                        buffer,
                        BitConverter.ToInt32(buffer, 20)),
                    BusType = BitConverter.ToUInt32(buffer, 28)
                });
            }
        }

        return result;
    }
}

public sealed class CodexVolumeDiskMapping
{
    public string DriveLetter { get; set; }
    public uint DeviceNumber { get; set; }
    public uint PartitionNumber { get; set; }
    public bool Success { get; set; }
    public string Error { get; set; }
}

public static class CodexVolumeDiskMapper
{
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;
    private const uint IOCTL_STORAGE_GET_DEVICE_NUMBER = 0x002D1080;

    [StructLayout(LayoutKind.Sequential)]
    private struct STORAGE_DEVICE_NUMBER
    {
        public uint DeviceType;
        public uint DeviceNumber;
        public uint PartitionNumber;
    }

    [DllImport(
        "kernel32.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool DeviceIoControl(
        SafeFileHandle device,
        uint ioControlCode,
        IntPtr inputBuffer,
        uint inputBufferSize,
        out STORAGE_DEVICE_NUMBER outputBuffer,
        uint outputBufferSize,
        out uint bytesReturned,
        IntPtr overlapped);

    public static List<CodexVolumeDiskMapping> Read()
    {
        List<CodexVolumeDiskMapping> result =
            new List<CodexVolumeDiskMapping>();

        foreach (string drive in Environment.GetLogicalDrives())
        {
            string driveLetter = drive.TrimEnd('\\');
            CodexVolumeDiskMapping mapping =
                new CodexVolumeDiskMapping { DriveLetter = driveLetter };

            using (SafeFileHandle handle = CreateFile(
                "\\\\.\\" + driveLetter,
                0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                IntPtr.Zero,
                OPEN_EXISTING,
                0,
                IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    mapping.Error =
                        "CreateFile failed: " +
                        Marshal.GetLastWin32Error();
                    result.Add(mapping);
                    continue;
                }

                STORAGE_DEVICE_NUMBER number;
                uint returned;
                if (DeviceIoControl(
                        handle,
                        IOCTL_STORAGE_GET_DEVICE_NUMBER,
                        IntPtr.Zero,
                        0,
                        out number,
                        (uint)Marshal.SizeOf(
                            typeof(STORAGE_DEVICE_NUMBER)),
                        out returned,
                        IntPtr.Zero))
                {
                    mapping.DeviceNumber = number.DeviceNumber;
                    mapping.PartitionNumber = number.PartitionNumber;
                    mapping.Success = true;
                }
                else
                {
                    mapping.Error =
                        "DeviceIoControl failed: " +
                        Marshal.GetLastWin32Error();
                }
            }

            result.Add(mapping);
        }

        return result;
    }
}
