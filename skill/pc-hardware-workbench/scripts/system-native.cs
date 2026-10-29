// Windows native probe declarations used by collect-windows.ps1.
// System, processor, firmware, memory, and battery native probes.
// This file is read-only and performs no network or configuration changes.

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class CodexProcessorTopologyReader
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SYSTEM_LOGICAL_PROCESSOR_INFORMATION
    {
        public UIntPtr ProcessorMask;
        public int Relationship;
        public ulong Reserved0;
        public ulong Reserved1;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetLogicalProcessorInformation(
        IntPtr buffer,
        ref uint returnedLength);

    public static int GetPhysicalCoreCount()
    {
        uint length = 0;
        GetLogicalProcessorInformation(IntPtr.Zero, ref length);
        if (length == 0)
            throw new InvalidOperationException(
                "Processor topology buffer size is unavailable.");

        IntPtr buffer = Marshal.AllocHGlobal((int)length);
        try
        {
            if (!GetLogicalProcessorInformation(buffer, ref length))
                throw new InvalidOperationException(
                    "Processor topology could not be read.");

            int entrySize = Marshal.SizeOf(
                typeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION));
            int physicalCores = 0;

            for (int offset = 0;
                 offset + entrySize <= length;
                 offset += entrySize)
            {
                SYSTEM_LOGICAL_PROCESSOR_INFORMATION entry =
                    (SYSTEM_LOGICAL_PROCESSOR_INFORMATION)
                    Marshal.PtrToStructure(
                        new IntPtr(buffer.ToInt64() + offset),
                        typeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION));

                if (entry.Relationship == 0)
                    physicalCores++;
            }

            return physicalCores;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}

public static class CodexFirmwareTypeReader
{
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFirmwareType(out uint firmwareType);

    public static uint Read()
    {
        uint firmwareType;
        if (!GetFirmwareType(out firmwareType))
            throw new InvalidOperationException(
                "GetFirmwareType failed: " +
                Marshal.GetLastWin32Error());
        return firmwareType;
    }
}

public static class CodexMemoryStatus
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public class MEMORYSTATUSEX
    {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);
}

public sealed class CodexMemoryModuleInfo
{
    public string Slot { get; set; }
    public string Bank { get; set; }
    public string Manufacturer { get; set; }
    public string PartNumber { get; set; }
    public ulong SizeBytes { get; set; }
    public int SpeedMTs { get; set; }
    public int ConfiguredSpeedMTs { get; set; }
}

public static class CodexSmbiosMemoryReader
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetSystemFirmwareTable(
        uint providerSignature,
        uint tableId,
        byte[] buffer,
        uint bufferSize);

    private static string ReadString(
        byte[] data,
        int structureStart,
        int structureLength,
        int stringEnd,
        int index)
    {
        if (index <= 0) return string.Empty;

        int position = structureStart + structureLength;
        int currentIndex = 1;

        while (position < stringEnd)
        {
            int end = position;
            while (end < stringEnd && data[end] != 0) end++;

            if (currentIndex == index)
                return Encoding.ASCII.GetString(
                    data,
                    position,
                    end - position).Trim();

            currentIndex++;
            position = end + 1;
        }

        return string.Empty;
    }

    public static List<CodexMemoryModuleInfo> Read()
    {
        const uint RSMB = 0x52534D42;
        uint size = GetSystemFirmwareTable(RSMB, 0, null, 0);
        if (size == 0)
            throw new InvalidOperationException(
                "SMBIOS firmware table is unavailable.");

        byte[] data = new byte[size];
        uint read = GetSystemFirmwareTable(RSMB, 0, data, size);
        if (read == 0)
            throw new InvalidOperationException(
                "SMBIOS firmware table could not be read.");

        int rawLength = BitConverter.ToInt32(data, 4);
        int tableEnd = Math.Min(data.Length, 8 + rawLength);
        int structureStart = 8;
        List<CodexMemoryModuleInfo> modules =
            new List<CodexMemoryModuleInfo>();

        while (structureStart + 4 <= tableEnd)
        {
            byte type = data[structureStart];
            byte length = data[structureStart + 1];
            if (length < 4) break;

            int formattedEnd = structureStart + length;
            if (formattedEnd > tableEnd) break;

            int stringEnd = formattedEnd;
            while (stringEnd + 1 < tableEnd &&
                   !(data[stringEnd] == 0 && data[stringEnd + 1] == 0))
                stringEnd++;

            int nextStructure = Math.Min(tableEnd, stringEnd + 2);

            if (type == 17 && length >= 0x1B)
            {
                ushort sizeCode =
                    BitConverter.ToUInt16(data, structureStart + 0x0C);
                ulong capacityBytes = 0;

                if (sizeCode == 0x7FFF && length >= 0x20)
                {
                    uint extendedSize =
                        BitConverter.ToUInt32(data, structureStart + 0x1C);
                    capacityBytes =
                        (ulong)(extendedSize & 0x7FFFFFFF) * 1024UL * 1024UL;
                }
                else if (sizeCode != 0 && sizeCode != 0xFFFF)
                {
                    capacityBytes = (ulong)sizeCode * 1024UL * 1024UL;
                }

                if (capacityBytes > 0)
                {
                    int speed =
                        BitConverter.ToUInt16(data, structureStart + 0x15);
                    int configuredSpeed = speed;

                    if (length >= 0x22)
                    {
                        int configured =
                            BitConverter.ToUInt16(
                                data,
                                structureStart + 0x20);
                        if (configured != 0 && configured != 0xFFFF)
                            configuredSpeed = configured;
                    }

                    modules.Add(new CodexMemoryModuleInfo
                    {
                        Slot = ReadString(
                            data,
                            structureStart,
                            length,
                            stringEnd,
                            data[structureStart + 0x10]),
                        Bank = ReadString(
                            data,
                            structureStart,
                            length,
                            stringEnd,
                            data[structureStart + 0x11]),
                        Manufacturer = ReadString(
                            data,
                            structureStart,
                            length,
                            stringEnd,
                            data[structureStart + 0x17]),
                        PartNumber = ReadString(
                            data,
                            structureStart,
                            length,
                            stringEnd,
                            data[structureStart + 0x1A]),
                        SizeBytes = capacityBytes,
                        SpeedMTs = speed == 0xFFFF ? -1 : speed,
                        ConfiguredSpeedMTs =
                            configuredSpeed == 0xFFFF
                                ? -1
                                : configuredSpeed
                    });
                }
            }

            if (nextStructure <= structureStart) break;
            structureStart = nextStructure;
        }

        return modules;
    }
}

public struct CodexSystemPowerStatus
{
    public byte ACLineStatus;
    public byte BatteryFlag;
    public byte BatteryLifePercent;
    public byte SystemStatusFlag;
    public uint BatteryLifeTime;
    public uint BatteryFullLifeTime;
}

public static class CodexSystemPowerStatusReader
{
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetSystemPowerStatus(
        out CodexSystemPowerStatus status);
}
