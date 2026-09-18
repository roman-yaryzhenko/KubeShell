using System;
using System.Collections.Generic;
using System.Text;

namespace KubeShell.Runtime;

/// <summary>
/// Canonical, injective encoding for execution-target identity components.
/// Values are length-prefixed, so separator characters inside kubeconfig paths cannot collapse
/// one ordered path list into another. The encoded value is an internal key, not a display path.
/// </summary>
public static class KubeTargetIdentityEncoding
{
    public static string Create(KubeTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        string[] paths = target.KubeConfigPaths;
        string?[] fields = new string?[paths.Length + 1];
        fields[0] = target.Context;
        for (int i = 0; i < paths.Length; i++) fields[i + 1] = paths[i];
        return EncodeFields(fields);
    }

    public static string EncodeFields(IEnumerable<string?> fields)
    {
        ArgumentNullException.ThrowIfNull(fields);
        string?[] values = new List<string?>(fields).ToArray();
        StringBuilder builder = new();
        builder.Append("kubeshell-id-v1;").Append(values.Length).Append(';');
        foreach (string? value in values)
        {
            if (value is null)
            {
                builder.Append("-1:");
                continue;
            }
            builder.Append(value.Length).Append(':').Append(value);
        }
        return builder.ToString();
    }
}
