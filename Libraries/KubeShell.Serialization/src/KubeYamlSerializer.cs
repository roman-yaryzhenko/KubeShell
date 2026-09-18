using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using YamlDotNet.Core;
using YamlDotNet.RepresentationModel;

namespace KubeShell.Serialization;

/// <summary>
/// Kubernetes-facing YAML conversion kept in managed code. The wire boundary remains JSON; this
/// helper handles YAML streams locally so no kubectl process or Go IPC call is needed for syntax
/// conversion. String scalars are emitted quoted to prevent YAML implicit typing on round-trip.
/// </summary>
public static partial class KubeYamlSerializer
{
    public static IReadOnlyList<string> ToJsonDocuments(string yaml)
    {
        ArgumentNullException.ThrowIfNull(yaml);
        YamlStream stream = new();
        using StringReader reader = new(yaml);
        stream.Load(reader);

        List<string> documents = new(stream.Documents.Count);
        foreach (YamlDocument document in stream.Documents)
        {
            JsonNode? node = ToJsonNode(document.RootNode);
            documents.Add(node?.ToJsonString(JsonOptions) ?? "null");
        }
        return documents;
    }

    public static string ToYaml(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        using JsonDocument document = JsonDocument.Parse(json);
        YamlStream stream = new(new YamlDocument(ToYamlNode(document.RootElement)));
        using StringWriter writer = new(CultureInfo.InvariantCulture);
        stream.Save(writer, assignAnchors: false);
        return writer.ToString();
    }

    /// <summary>Returns semantically equivalent JSON with object properties sorted ordinally.</summary>
    public static string CanonicalizeJson(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        using JsonDocument document = JsonDocument.Parse(json);
        using MemoryStream buffer = new();
        using (Utf8JsonWriter writer = new(buffer, new JsonWriterOptions { Indented = false }))
            WriteCanonical(document.RootElement, writer);
        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }

    private static void WriteCanonical(JsonElement element, Utf8JsonWriter writer)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (JsonProperty property in element.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteCanonical(property.Value, writer);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (JsonElement item in element.EnumerateArray()) WriteCanonical(item, writer);
                writer.WriteEndArray();
                break;
            default:
                element.WriteTo(writer);
                break;
        }
    }

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = false
    };

    private static JsonNode? ToJsonNode(YamlNode node) => node switch
    {
        YamlMappingNode map => ToJsonObject(map),
        YamlSequenceNode sequence => ToJsonArray(sequence),
        YamlScalarNode scalar => ToJsonScalar(scalar),
        _ => throw new FormatException($"Unsupported YAML node type {node.GetType().Name}.")
    };

    private static JsonObject ToJsonObject(YamlMappingNode map)
    {
        JsonObject result = new();
        foreach ((YamlNode rawKey, YamlNode rawValue) in map.Children)
        {
            if (rawKey is not YamlScalarNode key || key.Value is null)
                throw new FormatException("Kubernetes YAML mappings require scalar string keys.");
            result[key.Value] = ToJsonNode(rawValue);
        }
        return result;
    }

    private static JsonArray ToJsonArray(YamlSequenceNode sequence)
    {
        JsonArray result = new();
        foreach (YamlNode child in sequence.Children) result.Add(ToJsonNode(child));
        return result;
    }

    private static JsonNode? ToJsonScalar(YamlScalarNode scalar)
    {
        string value = scalar.Value ?? string.Empty;
        string tag = scalar.Tag.ToString();
        if (tag.EndsWith(":null", StringComparison.Ordinal)) return null;
        if (tag.EndsWith(":str", StringComparison.Ordinal)) return JsonValue.Create(value);
        if (tag.EndsWith(":bool", StringComparison.Ordinal)) return JsonValue.Create(ParseBoolean(value));
        if (tag.EndsWith(":int", StringComparison.Ordinal) && TryParseInteger(value, out long taggedInteger)) return JsonValue.Create(taggedInteger);
        if (tag.EndsWith(":float", StringComparison.Ordinal) && double.TryParse(value.Replace("_", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out double taggedFloat) && double.IsFinite(taggedFloat)) return JsonValue.Create(taggedFloat);

        if (scalar.Style is ScalarStyle.SingleQuoted or ScalarStyle.DoubleQuoted or ScalarStyle.Literal or ScalarStyle.Folded)
            return JsonValue.Create(value);

        string normalized = value.Trim();
        if (normalized.Length == 0) return JsonValue.Create(string.Empty);
        if (normalized is "~" || normalized.Equals("null", StringComparison.OrdinalIgnoreCase)) return null;
        if (TryParseBoolean(normalized, out bool boolean)) return JsonValue.Create(boolean);
        if (TryParseInteger(normalized, out long integer)) return JsonValue.Create(integer);
        if (DecimalFloat().IsMatch(normalized) && double.TryParse(normalized.Replace("_", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out double floating) && double.IsFinite(floating))
            return JsonValue.Create(floating);
        return JsonValue.Create(value);
    }

    private static YamlNode ToYamlNode(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => ToYamlMapping(element),
        JsonValueKind.Array => ToYamlSequence(element),
        JsonValueKind.String => new YamlScalarNode(element.GetString() ?? string.Empty) { Style = ScalarStyle.DoubleQuoted },
        JsonValueKind.Number => new YamlScalarNode(element.GetRawText()),
        JsonValueKind.True => new YamlScalarNode("true"),
        JsonValueKind.False => new YamlScalarNode("false"),
        JsonValueKind.Null or JsonValueKind.Undefined => new YamlScalarNode("null"),
        _ => throw new FormatException($"Unsupported JSON value kind {element.ValueKind}.")
    };

    private static YamlMappingNode ToYamlMapping(JsonElement element)
    {
        YamlMappingNode result = new();
        foreach (JsonProperty property in element.EnumerateObject())
            result.Add(new YamlScalarNode(property.Name), ToYamlNode(property.Value));
        return result;
    }

    private static YamlSequenceNode ToYamlSequence(JsonElement element)
    {
        YamlSequenceNode result = new();
        foreach (JsonElement item in element.EnumerateArray()) result.Add(ToYamlNode(item));
        return result;
    }

    private static bool ParseBoolean(string value) =>
        TryParseBoolean(value, out bool result)
            ? result
            : throw new FormatException($"Invalid YAML boolean scalar {value}.");

    private static bool TryParseBoolean(string value, out bool result)
    {
        switch (value.Trim().ToLowerInvariant())
        {
            case "true": case "yes": case "on": result = true; return true;
            case "false": case "no": case "off": result = false; return true;
            default: result = false; return false;
        }
    }

    private static bool TryParseInteger(string value, out long result)
    {
        string text = value.Replace("_", "").Trim();
        bool negative = text.StartsWith("-", StringComparison.Ordinal);
        string unsigned = negative || text.StartsWith("+", StringComparison.Ordinal) ? text[1..] : text;
        int numberBase = 10;
        if (unsigned.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) { numberBase = 16; unsigned = unsigned[2..]; }
        else if (unsigned.StartsWith("0o", StringComparison.OrdinalIgnoreCase)) { numberBase = 8; unsigned = unsigned[2..]; }
        try
        {
            long parsed = Convert.ToInt64(unsigned, numberBase);
            result = negative ? -parsed : parsed;
            return true;
        }
        catch (FormatException)
        {
            result = 0;
            return false;
        }
        catch (OverflowException)
        {
            result = 0;
            return false;
        }
    }

    [GeneratedRegex(@"^[+-]?(?:[0-9][0-9_]*\.[0-9_]*|[0-9][0-9_]*[eE][+-]?[0-9]+|\.[0-9_]+)(?:[eE][+-]?[0-9]+)?$", RegexOptions.CultureInvariant)]
    private static partial Regex DecimalFloat();
}
