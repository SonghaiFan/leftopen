using System.Runtime.InteropServices;
using System.Security.Principal;

namespace LeftOpen.Core;

/// <summary>
/// Resolves the user SID that owns a process, via its access token — the Windows
/// equivalent of leftopen's verified uid. Returns null when the process is elevated,
/// protected, or already gone (the caller treats that as "unverified, refuse to close").
/// </summary>
public static class ProcessIdentity
{
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint TokenQuery = 0x0008;
    private const int TokenUser = 1;

    public static string? GetOwnerSid(int pid)
    {
        var process = OpenProcess(ProcessQueryLimitedInformation, false, (uint)pid);
        if (process == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            if (!OpenProcessToken(process, TokenQuery, out var token))
            {
                return null;
            }

            try
            {
                return GetTokenUserSid(token);
            }
            finally
            {
                CloseHandle(token);
            }
        }
        finally
        {
            CloseHandle(process);
        }
    }

    public static string? ResolveOwnerName(string? sid)
    {
        if (string.IsNullOrEmpty(sid))
        {
            return null;
        }

        try
        {
            return new SecurityIdentifier(sid).Translate(typeof(NTAccount)).Value;
        }
        catch
        {
            return null;
        }
    }

    private static string? GetTokenUserSid(IntPtr token)
    {
        var length = 0;
        GetTokenInformation(token, TokenUser, IntPtr.Zero, 0, ref length);
        if (length <= 0)
        {
            return null;
        }

        var buffer = Marshal.AllocHGlobal(length);
        try
        {
            if (!GetTokenInformation(token, TokenUser, buffer, length, ref length))
            {
                return null;
            }

            // TOKEN_USER { SID_AND_ATTRIBUTES { PVOID Sid; ULONG Attributes; } }
            var sid = Marshal.ReadIntPtr(buffer);
            if (sid == IntPtr.Zero)
            {
                return null;
            }

            return ConvertSidToStringSid(sid, out var sidString) ? sidString : null;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint pid);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint access, out IntPtr tokenHandle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(
        IntPtr tokenHandle,
        int tokenInformationClass,
        IntPtr tokenInformation,
        int tokenInformationLength,
        ref int returnLength);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertSidToStringSid(IntPtr sid, out string stringSid);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);
}
