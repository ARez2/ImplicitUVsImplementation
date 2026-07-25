@tool
extends MeshInstance3D
class_name SDFMesh

enum SDFMode {
	Union = 1,
	Difference = 2,
	Intersect = 3
}

@export var Mode: SDFMode = SDFMode.Union
@export_range(0.0001, 30.0, 0.001) var BlendingFactor := 1.0


# Little utility to automatically name the new meshes by their mesh type
func _enter_tree() -> void:
	property_list_changed.connect(_on_inspector_edited_object_changed)

func _on_inspector_edited_object_changed():
	# Try to replace default names by the mesh type
	if name.to_lower().contains("meshinstance"):
		name = str(mesh.get_class().replace("Mesh", ""))
