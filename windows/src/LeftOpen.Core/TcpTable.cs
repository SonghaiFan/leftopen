using System.Net;
using System.Runtime.InteropServices;

namespace LeftOpen.Core;

/// <summary>A raw listening-socket row from the Windows TCP table: one PID, one port, one bound address.</summary>
public sealed record TcpListenerRow(int Pid, int Port, string Address);

/// <summary>
/// Enumerates TCP listeners with owning PIDs via the same native API netstat uses
/// (<see cref="GetExtendedTcpTable"/>), avoiding text parsing and sub-process overhead.
/// </summary>
public static class TcpTable
{
    private const int AfInet = 2;
    private const int AfInet6 = 23;
    private const int TcpStateListen = 2;

    public static IReadOnlyList<TcpListenerRow> GetListeners()
    {
        var rows = new List<TcpListenerRow>();
        AppendRows(rows, AfInet, isIpv6: false);
        AppendRows(rows, AfInet6, isIpv6: true);
        return rows;
    }

    private static void AppendRows(List<TcpListenerRow> rows, int addressFamily, bool isIpv6)
    {
        var raw = QueryTcpTable(addressFamily);
        if (raw.Length == 0)
        {
            return;
        }

        var count = (int)BitConverter.ToUInt32(raw, 0);
        var offset = sizeof(uint); // dwNumEntries
        var rowSize = isIpv6 ? Marshal.SizeOf<MibTcp6RowOwnerPid>() : Marshal.SizeOf<MibTcpRowOwnerPid>();

        for (var i = 0; i < count; i++)
        {
            if (isIpv6)
            {
                var row = BytesToStruct<MibTcp6RowOwnerPid>(raw, offset + i * rowSize);
                if (row.State != TcpStateListen)
                {
                    continue;
                }

                var address = new IPAddress(row.LocalAddr!, (long)row.LocalScopeId).ToString();
                rows.Add(new TcpListenerRow((int)row.OwningPid, PortFromNetworkOrder(row.LocalPort), address));
            }
            else
            {
                var row = BytesToStruct<MibTcpRowOwnerPid>(raw, offset + i * rowSize);
                if (row.State != TcpStateListen)
                {
                    continue;
                }

                var address = new IPAddress(row.LocalAddr).ToString();
                rows.Add(new TcpListenerRow((int)row.OwningPid, PortFromNetworkOrder(row.LocalPort), address));
            }
        }
    }

    internal static int PortFromNetworkOrder(uint portField)
    {
        // dwLocalPort's low 16 bits hold the port in network byte order; swap the
        // two bytes and keep the result in 16 bits (an unmasked << 8 lets the
        // original low byte leak into bits 16-23, producing impossible ports).
        var networkPort = (ushort)(portField & 0xFFFF);
        return ((networkPort & 0xFF) << 8) | (networkPort >> 8);
    }

    private static byte[] QueryTcpTable(int addressFamily)
    {
        var size = 0;
        var result = GetExtendedTcpTable(IntPtr.Zero, ref size, false, addressFamily, TcpTableClassOwnerPidAll, 0);
        if (result != ErrorInsufficientBuffer || size <= 0)
        {
            return Array.Empty<byte>();
        }

        var buffer = Marshal.AllocHGlobal(size);
        try
        {
            result = GetExtendedTcpTable(buffer, ref size, false, addressFamily, TcpTableClassOwnerPidAll, 0);
            if (result != 0)
            {
                return Array.Empty<byte>();
            }

            var raw = new byte[size];
            Marshal.Copy(buffer, raw, 0, size);
            return raw;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static T BytesToStruct<T>(byte[] bytes, int offset) where T : struct
    {
        var handle = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        try
        {
            return Marshal.PtrToStructure<T>(handle.AddrOfPinnedObject() + offset);
        }
        finally
        {
            handle.Free();
        }
    }

    private const uint ErrorInsufficientBuffer = 122;
    private const int TcpTableClassOwnerPidAll = 5;

    [DllImport("iphlpapi.dll")]
    private static extern uint GetExtendedTcpTable(
        IntPtr pTcpTable,
        ref int dwSize,
        bool bOrder,
        int ulAf,
        int tableClass,
        uint reserved);

    [StructLayout(LayoutKind.Sequential)]
    private struct MibTcpRowOwnerPid
    {
        public uint State;
        public uint LocalAddr;
        public uint LocalPort;
        public uint RemoteAddr;
        public uint RemotePort;
        public uint OwningPid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MibTcp6RowOwnerPid
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[]? LocalAddr;
        public uint LocalScopeId;
        public uint LocalPort;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[]? RemoteAddr;
        public uint RemoteScopeId;
        public uint RemotePort;
        public uint State;
        public uint OwningPid;
    }
}
