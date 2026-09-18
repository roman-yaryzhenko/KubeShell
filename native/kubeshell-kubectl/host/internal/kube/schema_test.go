package kube

import "testing"

func TestSchemaHelpersBuildRecursiveFieldTree(t *testing.T) {
	document := map[string]any{
		"components": map[string]any{
			"schemas": map[string]any{
				"example.Widget": map[string]any{
					"type": "object",
					"x-kubernetes-group-version-kind": []any{map[string]any{
						"group": "example.io", "version": "v1", "kind": "Widget",
					}},
					"required": []any{"spec"},
					"properties": map[string]any{
						"spec": map[string]any{"$ref": "#/components/schemas/example.WidgetSpec"},
					},
				},
				"example.WidgetSpec": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"replicas": map[string]any{"type": "integer", "format": "int32"},
						"template": map[string]any{
							"type": "object",
							"properties": map[string]any{
								"image": map[string]any{"type": "string", "description": "Container image."},
							},
						},
					},
				},
			},
		},
	}

	root, err := schemaForGVK(document, "example.io", "v1", "Widget")
	if err != nil {
		t.Fatalf("schemaForGVK: %v", err)
	}
	fields := buildSchemaFields(document, root, "", true, 0, 0, map[string]bool{})
	if len(fields) != 1 || fields[0].Name != "spec" || !fields[0].Required {
		t.Fatalf("unexpected root fields: %#v", fields)
	}
	if len(fields[0].Children) != 2 {
		t.Fatalf("expected two spec children, got %#v", fields[0].Children)
	}

	var imagePath string
	for _, child := range fields[0].Children {
		if child.Name == "template" && len(child.Children) == 1 {
			imagePath = child.Children[0].Path
		}
	}
	if imagePath != "spec.template.image" {
		t.Fatalf("unexpected recursive image path %q", imagePath)
	}

	focus, err := schemaProperty(document, root, "spec")
	if err != nil {
		t.Fatalf("schemaProperty(spec): %v", err)
	}
	focus, err = schemaProperty(document, focus, "replicas")
	if err != nil {
		t.Fatalf("schemaProperty(spec.replicas): %v", err)
	}
	typeName, format := schemaType(document, focus)
	if typeName != "integer" || format != "int32" {
		t.Fatalf("unexpected type %q/%q", typeName, format)
	}
}

func TestSchemaHelpersStopReferenceCycles(t *testing.T) {
	document := map[string]any{
		"components": map[string]any{
			"schemas": map[string]any{
				"example.Node": map[string]any{
					"type": "object",
					"properties": map[string]any{
						"child": map[string]any{"$ref": "#/components/schemas/example.Node"},
					},
				},
			},
		},
	}
	root := document["components"].(map[string]any)["schemas"].(map[string]any)["example.Node"].(map[string]any)
	fields := buildSchemaFields(document, root, "", true, 0, 0, map[string]bool{})
	if len(fields) != 1 || fields[0].Name != "child" {
		t.Fatalf("unexpected fields: %#v", fields)
	}
	if len(fields[0].Children) != 1 || fields[0].Children[0].Name != "child" {
		t.Fatalf("expected one recursive level before cycle guard, got %#v", fields[0].Children)
	}
	if len(fields[0].Children[0].Children) != 0 {
		t.Fatalf("cycle guard did not stop recursion: %#v", fields[0].Children[0].Children)
	}
}
