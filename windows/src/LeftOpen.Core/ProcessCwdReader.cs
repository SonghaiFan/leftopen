using System.Runtime.InteropServices;
using System.Text;

namespace LeftOpen.Core;

/// <summary>
/// Reads a process's current working directory straight out of its PEB
/// (RTL_USER_PROCESS_PARAMETERS.CurrentDirectory) — the Windows stand-in for
/// leftopen's <c>lsof -d cwd</c>. Works for same-user, non-elevated targets;
/// returns null on any failure (elevated/protected/protected/system processes,
/// exited pids, WOW64 edge cases), which the caller degrades gracefully.
/// </summary>
public static class ProcessCwdReader
{
    private const uint ProcessQueryInformation = 0x0400;
    private const uint ProcessVmRead = 0x0010;
    private const int ProcessBasicInformation = 0;
    private const int ProcessWow64Information = 26;

    // Offsets: ProcessParameters pointer within PEB, CurrentDirectory within params,
    // and the Buffer pointer within the UNICODE_STRING, for each bitness.
    private const int PebParamsOffsetX64 = 0x20;
    private const int PebParamsOffsetX86 = 0x10;
    private const int ParamsCurrentDirectoryOffsetX64 = 0x38;
    private const int ParamsCurrentDirectoryOffsetX86 = 0x24;
    private const int UnicodeStringBufferOffsetX64 = 0x8;
    private const int UnicodeStringBufferOffsetX86 = 0x4;

    public static string? TryReadCwd(int pid)
    {
        var process = OpenProcess(ProcessQueryInformation | ProcessVmRead, false, (uint)pid);
        if (process == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            // A 64-bit leftopen can read either bitness; a 32-bit leftopen (not shipped)
            // could only read 32-bit PEBs, which NtQueryInformationProcess returns anyway.
            var is64BitTarget = !TryGetWow64Peb(process, out var wow64Peb) || wow64Peb == 0;

            if (!TryGetPeb(process, out var peb) || peb == 0)
            {
                return null;
            }

            var paramsOffset = is64BitTarget ? PebParamsOffsetX64 : PebParamsOffsetX86;
            if (!TryReadPointer(process, peb + paramsOffset, is64BitTarget, out var processParameters) || processParameters == 0)
            {
                return null;
            }

            var cwdOffset = is64BitTarget ? ParamsCurrentDirectoryOffsetX64 : ParamsCurrentDirectoryOffsetX86;
            var dirStruct = processParameters + (nint)cwdOffset;

            var bufferOffset = is64BitTarget ? UnicodeStringBufferOffsetX64 : UnicodeStringBufferOffsetX86;
            if (!TryReadPointer(process, dirStruct + bufferOffset, is64BitTarget, out var buffer) || buffer == 0)
            {
                return null;
            }

            if (!TryReadUInt16(process, dirStruct, out var length) || length == 0)
            {
                return string.Empty;
            }

            var raw = ReadBytes(process, buffer, length);
            return raw == null ? null : Encoding.Unicode.GetString(raw);
        }
        catch
        {
            return null;
        }
    }

    private static bool TryGetPeb(IntPtr process, out nint peb)
    {
        var pbi = new long[6]; // PROCESS_BASIC_INFORMATION, 48 bytes on x64
        if (NtQueryInformationProcess(process, ProcessBasicInformation, pbi, pbi.Length * sizeof(long), out _) != 0)
        {
            peb = 0;
            return false;
        }

        peb = unchecked((nint)pbi[1]); // PebBaseAddress is the second pointer
        return peb != 0;
    }

    private static bool TryGetWow64Peb(IntPtr process, out nint wow64Peb)
    {
        var value = 0L;
        if (NtQueryInformationProcess(process, ProcessWow64Information, ref value, sizeof(long), out _) != 0)
        {
            wow64Peb = 0;
            return false;
        }

        wow64Peb = unchecked((nint)value);
        return true;
    }

    private static bool TryReadPointer(IntPtr process, nint address, bool is64Bit, out nint value)
    {
        if (is64Bit)
        {
            var buffer = new byte[8];
            if (!ReadProcessMemory(process, address, buffer, buffer.Length, out _))
            {
                value = 0;
                return false;
            }

            value = unchecked((nint)BitConverter.ToInt64(buffer, 0));
            return true;
        }

        var buffer32 = new byte[4];
        if (!ReadProcessMemory(process, address, buffer32, buffer32.Length, out _))
        {
            value = 0;
            return false;
        }

        value = unchecked((nint)BitConverter.ToUInt32(buffer32, 0));
        return true;
    }

    private static bool TryReadUInt16(IntPtr process, nint address, out ushort value)
    {
        var buffer = new byte[2];
        if (!ReadProcessMemory(process, address, buffer, buffer.Length, out _))
        {
            value = 0;
            return false;
        }

        value = BitConverter.ToUInt16(buffer, 0);
        return true;
    }

    private static byte[]? ReadBytes(IntPtr process, nint address, int length)
    {
        var buffer = new byte[length];
        return ReadProcessMemory(process, address, buffer, length, out _) ? buffer : null;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(
        IntPtr process,
        nint baseAddress,
        byte[] buffer,
        int size,
        out nint bytesRead);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr processHandle,
        int processInformationClass,
        long[] processInformation,
        int processInformationLength,
        out int returnLength);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr processHandle,
        int processInformationClass,
        ref long processInformation,
        int processInformationLength,
        out int returnLength);
}
