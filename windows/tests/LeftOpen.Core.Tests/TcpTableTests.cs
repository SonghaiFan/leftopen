using LeftOpen.Core;
using System.Reflection;

namespace LeftOpen.Core.Tests;

public class TcpTableTests
{
    [Theory]
    [InlineData(0x9193u, 37777)] // real-world case from the E2E test server
    [InlineData(0x5000u, 80)]    // 0x0050 network order
    [InlineData(0xBB01u, 443)]   // 0x01BB network order
    [InlineData(0x2273u, 29474)] // regression: unmasked << 8 once produced 0x227322
    public void PortFromNetworkOrder_SwapsBytesWithin16Bits(uint field, int expectedPort)
    {
        var method = typeof(TcpTable).GetMethod("PortFromNetworkOrder", BindingFlags.NonPublic | BindingFlags.Static);
        Assert.NotNull(method);

        var result = (int)method!.Invoke(null, [field])!;

        Assert.Equal(expectedPort, result);
        Assert.True(result is >= 1 and <= 65535, $"port {result} is out of range");
    }
}
