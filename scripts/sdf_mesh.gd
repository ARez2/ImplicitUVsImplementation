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
@export_tool_button("Generate seeds for this mesh") var GenerateSeeds = self.generate_seeds

# Little utility to automatically name the new meshes by their mesh type
func _enter_tree() -> void:
	property_list_changed.connect(_on_inspector_edited_object_changed)
	# hide this mesh
	layers = 0

func _on_inspector_edited_object_changed():
	# Try to replace default names by the mesh type
	if name.to_lower().contains("meshinstance"):
		name = str(mesh.get_class().replace("Mesh", ""))


func create_seed(pos: Vector3, e1: Vector3, e2: Vector3):
	@warning_ignore("shadowed_global_identifier")
	var seed := ImplicitUVsSeed.new()
	seed.name = "ImplicitUVsSeed"
	self.add_child(seed, true)
	seed.owner = get_tree().edited_scene_root
	
	var x_axis := e1.normalized()
	var z_axis := (e2 - x_axis * e2.dot(x_axis)).normalized()
	seed.transform = Transform3D(Basis(x_axis, z_axis.cross(x_axis).normalized(), z_axis), pos)
	seed.scale = Vector3.ONE


func generate_seeds():
	for child in self.get_children():
		if child is ImplicitUVsSeed:
			child.free()
	
	var m := self.mesh
	
	if m is SphereMesh:
		create_seed(Vector3(0.0, 0.0, m.radius), Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0))
		create_seed(Vector3(0.0, 0.0, -m.radius), Vector3(1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0))
	elif m is BoxMesh:
		var half_size = Vector3(m.size.x, m.size.y, m.size.z) * 0.5
		var e1 := Vector3(-1.0, 0.0, 0.0)
		var e2 := Vector3(0.0, 0.0, 1.0)
		create_seed(Vector3(-half_size.x * 0.75, half_size.y, -half_size.z * 0.75), e1, e2)
		create_seed(Vector3(-half_size.x * 0.75, half_size.y, half_size.z * 0.75), e1, e2)
		create_seed(Vector3(half_size.x * 0.75, half_size.y, 0.0), e1, e2)
		
		# two seeds in the diagonal corners
		#seeds.append(create_seed(Vector3(-mesh_data.x * 0.75, mesh_data.y, -mesh_data.z * 0.75),
					 #Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector2.ZERO))
		#seeds.append(create_seed(Vector3(mesh_data.x * 0.75, mesh_data.y, mesh_data.z * 0.75),
					 #Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2.ZERO))

		# two seeds in the middle
		#seeds.append(create_seed(Vector3(-mesh_data.x * 0.95, mesh_data.y, 0.0),
					 #Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector2.ZERO))
		#seeds.append(create_seed(Vector3(mesh_data.x * 0.95, mesh_data.y, 0.0),
					 #Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2.ZERO))
		
		# testing with a slightly rotated basis: (it should optimize the frames to rotate it back)
		#seeds.append(create_seed(Vector3(mesh_data.x * 0.75, mesh_data.y, mesh_data.z * 0.75),
					 #Vector3(0.262, 0.0, 0.201).normalized(), Vector3(-0.201, 0.0, 0.262).normalized(), Vector2.ZERO))
	elif m is CylinderMesh:
		var middle_radius = (m.top_radius + m.bottom_radius) / 2.0
		
		var seeds_on_cyl := 3
		for i in range(seeds_on_cyl):
			var angle := i * (2.0 * PI / seeds_on_cyl)
			#printt(i, rad_to_deg(angle))
			var pos_x: float = middle_radius * sin(angle)
			var pos_y: float = 0.0
			var pos_z: float = middle_radius * cos(angle)
			var tangent_x = cos(angle)
			var tangent_z = -sin(angle)
			#if meshinst == $Scene/TreeScene/Branch and i == 1:
				#tangent_x *= -1
			create_seed(Vector3(pos_x, pos_y, pos_z), Vector3(tangent_x, 0.0, tangent_z), Vector3(0.0, 1.0, 0.0))

	elif m is TorusMesh:
		var major_radius: float = (m.outer_radius + m.inner_radius) / 2.0
		var minor_radius:  float = abs(m.inner_radius - m.outer_radius) / 2.0
		create_seed(Vector3(0.0, minor_radius, major_radius), Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0))
		create_seed(Vector3(0.0, minor_radius, -major_radius), Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0))
	
