using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Net.Http;
using System.Text.RegularExpressions;
using LeftOpen.Core;

namespace LeftOpen.Tray;

/// <summary>
/// Per-row icon resolution, following the original's tier order (ProcessIconView.swift):
///   1. the executable's own icon — but only when the executable IS the app, not a
///      shared runtime like node.exe (whose icon says nothing about the project);
///   2. the icon the project ships itself (Tauri/Electron, Next.js, public/static/assets,
///      bare favicon.*, plus whatever its index.html declares);
///   3. the favicon served by the running dev server itself;
///   4. a symbol for the runtime (node/python/go/java/ruby…), coloured like the original;
///   5. a category symbol (project / app / system / unknown).
/// Symbols come from Segoe MDL2 Assets — Windows' system symbol font, the counterpart
/// of the SF Symbols the original relies on.
/// </summary>
internal static partial class AppIcons
{
    /// <summary>
    /// The original's projectIconCandidates, minus formats Windows cannot decode
    /// (.icns, .svg — the macOS build loads those through AppKit).
    /// </summary>
    private static readonly string[] ProjectIconCandidates =
    [
        // Tauri / Electron app icons
        "src-tauri/icons/icon.png", "app-icon.png",
        "build/icon.png", "buildResources/icon.png", "resources/icon.png",
        // Next.js app router
        "app/apple-icon.png", "app/icon.png", "app/favicon.ico",
        "src/app/apple-icon.png", "src/app/icon.png", "src/app/favicon.ico",
        // Vite / CRA / Nuxt / Astro (`public/`), SvelteKit (`static/`)
        "public/apple-touch-icon.png", "public/icon.png", "public/logo.png",
        "public/favicon.png", "public/favicon.ico",
        "static/apple-touch-icon.png", "static/favicon.png", "static/favicon.ico",
        "assets/favicon.png", "assets/favicon.ico",
        // Bare roots
        "favicon.png", "favicon.ico", "icon.png",
    ];

    /// <summary>Runtime executables that must not lend their own icon to a project row.</summary>
    private static readonly HashSet<string> RuntimeHostNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "node", "bun", "deno", "npm", "yarn", "pnpm", "ts-node",
        "python", "pythonw", "python3", "py", "uvicorn", "gunicorn", "flask", "jupyter",
        "dotnet", "java", "javaw", "gradle", "kotlin",
        "go", "dlv", "cargo", "rustc", "ruby", "rails", "puma",
    };

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMilliseconds(1500) };

    public static Image Resolve(
        string? executablePath,
        string? projectRoot,
        int port,
        Category category,
        string command,
        int size)
    {
        // Tier 1 — the executable's own icon, when it represents an actual application.
        if (!string.IsNullOrEmpty(executablePath) &&
            !RuntimeHostNames.Contains(Path.GetFileNameWithoutExtension(executablePath)))
        {
            if (TryExeIcon(executablePath, size) is { } exeIcon)
            {
                return exeIcon;
            }
        }

        // Tier 2 — an icon the project ships itself.
        if (!string.IsNullOrEmpty(projectRoot) && TryProjectIcon(projectRoot, size) is { } projectIcon)
        {
            return projectIcon;
        }

        // Tier 3 — the favicon the running server serves (or declares in its HTML).
        if (port is > 0 and <= 65535 && TryLiveFavicon(port, size) is { } liveIcon)
        {
            return liveIcon;
        }

        // Tier 4 — runtime symbol, coloured the way the original colours its SF Symbols.
        if (TryRuntimeSymbol(command, executablePath, size) is { } runtimeIcon)
        {
            return runtimeIcon;
        }

        // Tier 5 — category symbol.
        return category switch
        {
            Category.Project => Glyph('\uE8B7', Color.FromArgb(0x2B, 0x6C, 0xD6), size),        // folder
            Category.Application => Glyph('\uE713', Color.FromArgb(0x6B, 0x6B, 0x6B), size),    // gear
            Category.SystemService => Glyph('\uE713', Color.FromArgb(0x6B, 0x6B, 0x6B), size),  // gear
            _ => Glyph('\uE756', Color.FromArgb(0x6B, 0x6B, 0x6B), size),                       // command prompt
        };
    }

    private static Image? TryExeIcon(string executablePath, int size)
    {
        try
        {
            if (!File.Exists(executablePath))
            {
                return null;
            }

            using var icon = Icon.ExtractAssociatedIcon(executablePath);
            return icon == null ? null : new Bitmap(icon.ToBitmap(), size, size);
        }
        catch
        {
            return null;
        }
    }

    private static Image? TryProjectIcon(string projectRoot, int size)
    {
        foreach (var candidate in CandidatesWithHtmlIcons(projectRoot))
        {
            var path = Path.Combine(projectRoot, candidate);
            if (!File.Exists(path))
            {
                continue;
            }

            try
            {
                using var image = Image.FromFile(path);
                return new Bitmap(image, size, size);
            }
            catch
            {
                // Unreadable or unsupported image — try the next candidate.
            }
        }

        return null;
    }

    private static IEnumerable<string> CandidatesWithHtmlIcons(string projectRoot)
    {
        // A Vite/Tauri project declares its own favicon in index.html; honour that first,
        // exactly like the original does.
        var indexHtml = Path.Combine(projectRoot, "index.html");
        if (File.Exists(indexHtml))
        {
            string html;
            try
            {
                html = File.ReadAllText(indexHtml);
            }
            catch
            {
                html = string.Empty;
            }

            foreach (var relative in DeclaredIconPaths(html))
            {
                yield return relative;
                yield return Path.Combine("public", relative);
            }
        }

        foreach (var candidate in ProjectIconCandidates)
        {
            yield return candidate;
        }
    }

    private static IEnumerable<string> DeclaredIconPaths(string html)
    {
        foreach (Match match in IconLinkRegex().Matches(html))
        {
            var href = match.Groups["href"].Value;
            if (href.StartsWith("http", StringComparison.OrdinalIgnoreCase) ||
                href.StartsWith("//", StringComparison.Ordinal))
            {
                continue;
            }

            var relative = href.Split('?')[0].TrimStart('/');
            if (relative.Length > 0 && !relative.Contains(".."))
            {
                yield return relative;
            }
        }
    }

    private static Image? TryLiveFavicon(int port, int size)
    {
        try
        {
            var bytes = FetchBytes($"http://127.0.0.1:{port}/favicon.ico");
            if (bytes == null)
            {
                // No /favicon.ico: ask the served HTML what it declares.
                var html = FetchText($"http://127.0.0.1:{port}/");
                if (html != null)
                {
                    foreach (var relative in DeclaredIconPaths(html))
                    {
                        bytes = FetchBytes($"http://127.0.0.1:{port}/{relative}");
                        if (bytes != null)
                        {
                            break;
                        }
                    }
                }
            }

            if (bytes == null)
            {
                return null;
            }

            using var stream = new MemoryStream(bytes);
            using var image = Image.FromStream(stream);
            return new Bitmap(image, size, size);
        }
        catch
        {
            return null;
        }
    }

    private static byte[]? FetchBytes(string url)
    {
        try
        {
            using var response = Http.GetAsync(url).GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            var bytes = response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult();
            return bytes.Length == 0 ? null : bytes;
        }
        catch
        {
            return null;
        }
    }

    private static string? FetchText(string url)
    {
        try
        {
            using var response = Http.GetAsync(url).GetAwaiter().GetResult();
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            var content = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            return content.Length > 512 * 1024 ? content[..(512 * 1024)] : content;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Runtime symbols with the original's colours (node green, python blue, …).</summary>
    private static Image? TryRuntimeSymbol(string command, string? executablePath, int size)
    {
        var target = $"{Path.GetFileNameWithoutExtension(command)} {Path.GetFileNameWithoutExtension(executablePath)}".ToLowerInvariant();

        if (Contains(target, "node", "bun", "deno", "npm", "yarn", "pnpm", "ts-node"))
        {
            return Glyph('\uE943', Color.FromArgb(89, 166, 64), size);      // code, green
        }

        if (Contains(target, "python", "uvicorn", "gunicorn", "flask", "fastapi", "django", "jupyter"))
        {
            return Glyph('\uE943', Color.FromArgb(59, 120, 173), size);     // code, blue
        }

        if (Contains(target, "cargo", "rustc"))
        {
            return Glyph('\uE713', Color.FromArgb(224, 89, 41), size);      // gear, orange
        }

        if (Contains(target, "go", "dlv"))
        {
            return Glyph('\uE943', Color.FromArgb(0, 168, 209), size);      // code, cyan
        }

        if (Contains(target, "java", "gradle", "kotlin"))
        {
            return Glyph('\uE943', Color.FromArgb(224, 64, 38), size);      // code, red-brown
        }

        if (Contains(target, "ruby", "rails", "puma"))
        {
            return Glyph('\uE943', Color.FromArgb(204, 38, 38), size);      // code, red
        }

        if (Contains(target, "postgres", "pg_ctl"))
        {
            return Glyph('\uE943', Color.FromArgb(51, 99, 148), size);
        }

        if (Contains(target, "redis", "valkey", "keydb"))
        {
            return Glyph('\uE943', Color.FromArgb(217, 51, 46), size);
        }

        if (Contains(target, "mysql", "mariadb"))
        {
            return Glyph('\uE943', Color.FromArgb(237, 148, 38), size);
        }

        return null;

        static bool Contains(string haystack, params string[] needles) =>
            needles.Any(needle => haystack.Contains(needle, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Renders a Segoe MDL2 Assets glyph (Windows' system symbol font).</summary>
    private static Image Glyph(char glyph, Color color, int size)
    {
        var bitmap = new Bitmap(size, size, PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bitmap);
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        using var font = new Font("Segoe MDL2 Assets", size * 0.72f, FontStyle.Regular, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(color);
        var text = glyph.ToString();
        var measured = g.MeasureString(text, font);
        g.DrawString(text, font, brush, (size - measured.Width) / 2f, (size - measured.Height) / 2f);
        return bitmap;
    }

    /// <summary>Matches &lt;link rel="…icon…" href="…"&gt; in either attribute order.</summary>
    [GeneratedRegex(
        """<link[^>]*rel\s*=\s*["'][^"']*(?:icon|apple-touch-icon)[^"']*["'][^>]*?href\s*=\s*["'](?<href>[^"']+)["']|<link[^>]*href\s*=\s*["'](?<href>[^"']+)["'][^>]*?rel\s*=\s*["'][^"']*(?:icon|apple-touch-icon)[^"']*["']""",
        RegexOptions.IgnoreCase)]
    private static partial Regex IconLinkRegex();
}
