package kube

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	"k8s.io/apimachinery/pkg/runtime"
)

const schemaSafetyDepth = 64

func explainSchema(ctx context.Context, s *session, req protocol.SchemaRequest) (protocol.SchemaResponse, error) {
	if req.Resource.Resource == "" {
		return protocol.SchemaResponse{}, fmt.Errorf("schema resource is required")
	}
	if req.MaxDepth < 0 {
		return protocol.SchemaResponse{}, fmt.Errorf("schema maxDepth must be non-negative")
	}

	resolved, err := resolve(ctx, s, req.Execution, req.Resource, false)
	if err != nil {
		return protocol.SchemaResponse{}, err
	}
	bundle, err := s.bundle(req.Execution, false)
	if err != nil {
		return protocol.SchemaResponse{}, err
	}
	paths, err := bundle.openAPI.PathsWithContext(ctx)
	if err != nil {
		return protocol.SchemaResponse{}, fmt.Errorf("fetch OpenAPI v3 paths: %w", err)
	}

	path := "api/" + resolved.gvr.Version
	if resolved.gvr.Group != "" {
		path = "apis/" + resolved.gvr.Group + "/" + resolved.gvr.Version
	}
	groupVersion, ok := paths[path]
	if !ok {
		return protocol.SchemaResponse{}, fmt.Errorf("OpenAPI v3 has no schema path %q", path)
	}
	data, err := groupVersion.SchemaWithContext(ctx, runtime.ContentTypeJSON)
	if err != nil {
		return protocol.SchemaResponse{}, fmt.Errorf("fetch OpenAPI v3 schema %q: %w", path, err)
	}
	var document map[string]any
	if err := json.Unmarshal(data, &document); err != nil {
		return protocol.SchemaResponse{}, fmt.Errorf("decode OpenAPI v3 schema %q: %w", path, err)
	}

	root, err := schemaForGVK(document, resolved.gvk.Group, resolved.gvk.Version, resolved.gvk.Kind)
	if err != nil {
		return protocol.SchemaResponse{}, err
	}
	focus := root
	fieldPath := strings.Trim(strings.TrimSpace(req.FieldPath), ".")
	if fieldPath != "" {
		for _, segment := range strings.Split(fieldPath, ".") {
			focus, err = schemaProperty(document, focus, segment)
			if err != nil {
				return protocol.SchemaResponse{}, fmt.Errorf("schema field %q: %w", fieldPath, err)
			}
		}
	}

	focus = resolveSchemaRef(document, focus)
	typeName, format := schemaType(document, focus)
	fields := buildSchemaFields(document, focus, fieldPath, req.Recursive, req.MaxDepth, 0, map[string]bool{})
	return protocol.SchemaResponse{
		GVR:         protocol.GVR{Group: resolved.gvr.Group, Version: resolved.gvr.Version, Resource: resolved.gvr.Resource},
		Kind:        resolved.gvk.Kind,
		FieldPath:   fieldPath,
		Type:        typeName,
		Format:      format,
		Description: stringValue(focus["description"]),
		Fields:      fields,
	}, nil
}

func schemaForGVK(document map[string]any, group, version, kind string) (map[string]any, error) {
	components, ok := document["components"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("OpenAPI v3 document has no components")
	}
	schemas, ok := components["schemas"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("OpenAPI v3 document has no component schemas")
	}
	for _, name := range sortedKeys(schemas) {
		schema, ok := schemas[name].(map[string]any)
		if !ok {
			continue
		}
		gvks, ok := schema["x-kubernetes-group-version-kind"].([]any)
		if !ok {
			continue
		}
		for _, raw := range gvks {
			entry, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			if stringValue(entry["group"]) == group && stringValue(entry["version"]) == version && stringValue(entry["kind"]) == kind {
				return schema, nil
			}
		}
	}
	return nil, fmt.Errorf("OpenAPI v3 schema for %s/%s %s was not found", group, version, kind)
}

func schemaProperty(document map[string]any, schema map[string]any, name string) (map[string]any, error) {
	schema = schemaObject(document, schema)
	properties, ok := schema["properties"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("type has no fields")
	}
	raw, ok := properties[name]
	if !ok {
		return nil, fmt.Errorf("field %q was not found", name)
	}
	property, ok := raw.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("field %q has an invalid OpenAPI schema", name)
	}
	return property, nil
}

func schemaObject(document map[string]any, schema map[string]any) map[string]any {
	schema = resolveSchemaRef(document, schema)
	if stringValue(schema["type"]) == "array" {
		if items, ok := schema["items"].(map[string]any); ok {
			return resolveSchemaRef(document, items)
		}
	}
	return schema
}

func resolveSchemaRef(document map[string]any, schema map[string]any) map[string]any {
	ref, _ := schema["$ref"].(string)
	if ref == "" || !strings.HasPrefix(ref, "#/") {
		return schema
	}
	var current any = document
	for _, encoded := range strings.Split(strings.TrimPrefix(ref, "#/"), "/") {
		segment := strings.ReplaceAll(strings.ReplaceAll(encoded, "~1", "/"), "~0", "~")
		object, ok := current.(map[string]any)
		if !ok {
			return schema
		}
		current, ok = object[segment]
		if !ok {
			return schema
		}
	}
	if resolved, ok := current.(map[string]any); ok {
		return resolved
	}
	return schema
}

func buildSchemaFields(
	document map[string]any,
	schema map[string]any,
	parentPath string,
	recursive bool,
	maxDepth int,
	depth int,
	refStack map[string]bool,
) []protocol.SchemaField {
	schema = schemaObject(document, schema)
	properties, ok := schema["properties"].(map[string]any)
	if !ok {
		return nil
	}
	required := stringSet(schema["required"])
	result := make([]protocol.SchemaField, 0, len(properties))
	for _, name := range sortedKeys(properties) {
		raw, ok := properties[name].(map[string]any)
		if !ok {
			continue
		}
		path := name
		if parentPath != "" {
			path = parentPath + "." + name
		}
		typeName, format := schemaType(document, raw)
		resolved := resolveSchemaRef(document, raw)
		field := protocol.SchemaField{
			Name:        name,
			Path:        path,
			Type:        typeName,
			Format:      format,
			Description: stringValue(resolved["description"]),
			Required:    required[name],
			Enum:        enumStrings(resolved["enum"]),
		}

		if recursive && shouldDescend(depth+1, maxDepth) {
			ref := refValue(raw)
			if ref == "" || !refStack[ref] {
				nextStack := cloneBoolMap(refStack)
				if ref != "" {
					nextStack[ref] = true
				}
				field.Children = buildSchemaFields(document, raw, path, true, maxDepth, depth+1, nextStack)
			}
		}
		result = append(result, field)
	}
	return result
}

func shouldDescend(depth, maxDepth int) bool {
	if depth >= schemaSafetyDepth {
		return false
	}
	return maxDepth == 0 || depth < maxDepth
}

func schemaType(document map[string]any, schema map[string]any) (string, string) {
	resolved := resolveSchemaRef(document, schema)
	typeName := stringValue(resolved["type"])
	format := stringValue(resolved["format"])
	if typeName == "array" {
		if items, ok := resolved["items"].(map[string]any); ok {
			itemType, itemFormat := schemaType(document, items)
			if itemType == "" {
				itemType = "object"
			}
			typeName = "array<" + itemType + ">"
			if format == "" {
				format = itemFormat
			}
		}
	}
	if typeName == "" {
		if _, ok := resolved["properties"]; ok {
			typeName = "object"
		}
	}
	return typeName, format
}

func stringValue(value any) string {
	if value == nil {
		return ""
	}
	if text, ok := value.(string); ok {
		return text
	}
	return fmt.Sprint(value)
}

func stringSet(value any) map[string]bool {
	result := map[string]bool{}
	for _, item := range anySlice(value) {
		if text, ok := item.(string); ok {
			result[text] = true
		}
	}
	return result
}

func enumStrings(value any) []string {
	items := anySlice(value)
	if len(items) == 0 {
		return nil
	}
	result := make([]string, 0, len(items))
	for _, item := range items {
		result = append(result, fmt.Sprint(item))
	}
	return result
}

func anySlice(value any) []any {
	if value == nil {
		return nil
	}
	items, _ := value.([]any)
	return items
}

func sortedKeys(values map[string]any) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func refValue(schema map[string]any) string {
	ref, _ := schema["$ref"].(string)
	if ref != "" {
		return ref
	}
	if stringValue(schema["type"]) == "array" {
		if items, ok := schema["items"].(map[string]any); ok {
			ref, _ = items["$ref"].(string)
		}
	}
	return ref
}

func cloneBoolMap(input map[string]bool) map[string]bool {
	out := make(map[string]bool, len(input))
	for key, value := range input {
		out[key] = value
	}
	return out
}
