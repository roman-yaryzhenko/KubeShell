using System.Text;

namespace KubeShell.Serialization;

/// <summary>
/// Small deterministic line diff used by manifest comparison. It deliberately has no Kubernetes
/// semantics; callers normalize Kubernetes documents before passing them here. Keeping the renderer
/// managed avoids using the platform diff executable or kubectl for presentation-only work.
/// </summary>
public static class KubeTextDiff
{
    public static string Unified(string left, string right, string leftName = "live", string rightName = "merged")
    {
        ArgumentNullException.ThrowIfNull(left);
        ArgumentNullException.ThrowIfNull(right);
        string[] a = Lines(left);
        string[] b = Lines(right);
        int[,] lcs = BuildLcs(a, b);
        StringBuilder output = new();
        output.Append("--- ").AppendLine(leftName);
        output.Append("+++ ").AppendLine(rightName);
        output.AppendLine("@@");

        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (string.Equals(a[i], b[j], StringComparison.Ordinal))
            {
                output.Append(' ').AppendLine(a[i]);
                i++; j++;
            }
            else if (lcs[i + 1, j] >= lcs[i, j + 1])
            {
                output.Append('-').AppendLine(a[i++]);
            }
            else
            {
                output.Append('+').AppendLine(b[j++]);
            }
        }
        while (i < a.Length) output.Append('-').AppendLine(a[i++]);
        while (j < b.Length) output.Append('+').AppendLine(b[j++]);
        return output.ToString();
    }

    private static string[] Lines(string value) =>
        value.Replace("\r\n", "\n", StringComparison.Ordinal).TrimEnd('\n').Split('\n');

    private static int[,] BuildLcs(string[] a, string[] b)
    {
        int[,] table = new int[a.Length + 1, b.Length + 1];
        for (int i = a.Length - 1; i >= 0; i--)
        for (int j = b.Length - 1; j >= 0; j--)
            table[i, j] = string.Equals(a[i], b[j], StringComparison.Ordinal)
                ? table[i + 1, j + 1] + 1
                : Math.Max(table[i + 1, j], table[i, j + 1]);
        return table;
    }
}
