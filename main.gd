@tool
extends Node3D
class_name MainScript

enum LogLevel {
	LOG_ERROR = 0,
	LOG_WARN = 1,
	LOG_INFO = 2
}
@export var Logging := LogLevel.LOG_ERROR:
	set(v):
		if v != Logging:
			Logging = v
			LogLvl = v
static var LogLvl := 0
@export_range(0.001, 30.0, 0.001) var GlobalBlendingFactor := 0.046:
	set(v):
		if v != GlobalBlendingFactor:
			GlobalBlendingFactor = v
			precalc_dirty = true
# @export_range(0.0, 32.0, 0.001) var AlbedoBlendPower := 1.0
@export_range(0.0, 1.0, 0.001) var AlbedoBlendOffset := 0.211
@export var ColorTex: Texture2D
@export_tool_button("Do a precalc!") var PrecalcButton = func(): build_scene(true)
@export var PrintPrecalcResults := false
@export_enum("No", "Visualize before precalc", "Visualize after precalc") var VisualizeSeeds := 0:
	set(v):
		if v != VisualizeSeeds:
			VisualizeSeeds = v
			if is_inside_tree():
				visualize_seeds($Scene)
# Transform3D gets converted to mat4
var scene_data: Array[Transform3D] = []
var num_scene_objects := 0

class Seed:
	var position: Vector3
	var e1: Vector3
	var e2: Vector3
	var offset: Vector2
	var enabled: bool
	var max_walk_dist: float
	
	func _init(_position: Vector3, _e1: Vector3, _e2: Vector3, _max_walk: float, _enabled: bool = true) -> void:
		self.position = _position
		self.e1 = _e1
		self.e2 = _e2
		self.offset = Vector2.ZERO
		self.enabled = _enabled
		#if _max_walk == null:
			#_max_walk = Def
		self.max_walk_dist = _max_walk
	
	func printer() -> String:
		return "Seed(" + str(self.position) + ", " + str(self.e1) + ", " + str(self.e2) + ", " + str(self.offset) + ", " + str(self.enabled) + ", " + str(self.max_walk_dist) + ")"
	
	func eq(other: Seed) -> bool:
		return self.position.is_equal_approx(other.position) and self.e1.is_equal_approx(other.e1) and self.e2.is_equal_approx(other.e2) and self.enabled == other.enabled and is_equal_approx(self.max_walk_dist, other.max_walk_dist)
	
var seed_data: Array[Seed] = []
# xyz = target direction (normalized, in tangent plane of seed), w = strength
var seed_data_targets: Array[Vector4] = []
# store how seed_data looked like right after scene_build because it changes after a precalculation
var seed_data_after_scenebuild: Array[Seed] = []
var merging_graph: MergingGraph
var ImplicitUVsBlending := 0.179

const COORDINATE_SYSTEM = preload("uid://bts105g652v5w")

# must be the same as in the shader
const NUM_SEEDS_PER_OBJ := 3
const NUM_MATRICES_PER_OBJ := 2
const MAX_NUM_OBJECTS := 16
const MAX_NUM_MERGE_NEIGHBORS := 16
const TOTAL_NR_SEEDS := NUM_SEEDS_PER_OBJ * MAX_NUM_OBJECTS

# compute shader stuff
var started_first_real_scenebuild := false
var ready_to_run := false
var rd: RenderingDevice
var rids: Dictionary[String, RID] = {}
var non_freeing_rids: Dictionary[String, RID] = {}
var viewport_size: Vector2 = Vector2.ZERO
var DEFAULT_FORMAT: RDTextureFormat
var DEPTH_FORMAT: RDTextureFormat
var uniforms: Dictionary[String, RDUniform] = {}
var rid_freeing_queue: Array[RID] = []
var output_texture: Texture2DRD
var depth_texture: Texture2DRD

enum PrecalculationStage {
	PRECALC_FRAMES = 1,
	PRECALC_OFFSETS = 2,
	PRECALC_DONE = 0,
}
var PrecalcStage := PrecalculationStage.PRECALC_DONE
var precalc_dirty := false

# because of std430 layout, a mat3 is 3x (vec3 + 4 byte padding)
const SIZE_VEC2 := 8
const SIZE_MAT3 := 48
const SIZE_MAT4 := 64
var gdext := MyExtension.new()
const PRECALC_BUF_MATRICES_START := 16
const PRECALC_BUF_LOGMAPS_START := PRECALC_BUF_MATRICES_START + TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS * SIZE_MAT3
const PRECALC_BUF_SIZE := PRECALC_BUF_LOGMAPS_START + TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS * SIZE_VEC2

func _ready() -> void:
	var material := %RaymarcherTexShower.get_surface_override_material(0).duplicate() as ShaderMaterial
	%RaymarcherTexShower.set_surface_override_material(0, material)

	output_texture = Texture2DRD.new()
	depth_texture = Texture2DRD.new()

	material.set_shader_parameter("tex", output_texture)
	material.set_shader_parameter("depth_tex", depth_texture)
	
	# do a first build of the scene so that at least theres some data there
	# another build will be called inside of setup_compute_shader()
	build_scene(true)
	RenderingServer.call_on_render_thread.call_deferred(setup_compute_shader)
	RenderingServer.connect("frame_pre_draw", run_compute_shader)


func _process(_delta: float) -> void:
	build_scene()
	if precalc_dirty:
		run_precalc()


# =========================== COMPUTE SHADER STUFF ===========================
var shutting_down := false
func _exit_tree() -> void:
	shutting_down = true
	ready_to_run = false
	set_process(false)

	if RenderingServer.frame_pre_draw.is_connected(run_compute_shader):
		RenderingServer.frame_pre_draw.disconnect(run_compute_shader)

	var owned_rids: Array[RID] = []
	for rid: RID in rids.values():
		if rid.is_valid() and not owned_rids.has(rid):
			owned_rids.append(rid)
	for rid: RID in rid_freeing_queue:
		if rid.is_valid() and not owned_rids.has(rid):
			owned_rids.append(rid)
	rids.clear()
	rid_freeing_queue.clear()
	non_freeing_rids.clear()

	if rd == null:
		return

	RenderingServer.call_on_render_thread(
		_release_compute_resources.bind(
			rd,
			owned_rids,
			output_texture,
			depth_texture
		)
	)

static func _release_compute_resources(
	device: RenderingDevice,
	owned_rids: Array[RID],
	color_tex: Texture2DRD,
	depth_tex: Texture2DRD
) -> void:
	if color_tex != null:
		color_tex.texture_rd_rid = RID()
	if depth_tex != null:
		depth_tex.texture_rd_rid = RID()
	for rid in owned_rids:
		device.free_rid(rid)


func setup_compute_shader():
	if shutting_down:
		return
	rd = RenderingServer.get_rendering_device()

	if Engine.is_editor_hint():
		viewport_size = Engine.get_singleton("EditorInterface").get_editor_viewport_3d().get_visible_rect().size
	else:
		viewport_size = get_viewport().get_visible_rect().size

	DEFAULT_FORMAT = new_texture_format(RenderingDevice.DataFormat.DATA_FORMAT_R32G32B32A32_SFLOAT)
	DEPTH_FORMAT = new_texture_format(RenderingDevice.DataFormat.DATA_FORMAT_R32_SFLOAT)

	if Engine.is_editor_hint():
		viewport_size = Engine.get_singleton("EditorInterface").get_editor_viewport_3d().get_visible_rect().size
	else:
		viewport_size = get_viewport().get_visible_rect().size

	var shader_file = load("res://shaders/sdf.glsl")
	var shader_spirv: RDShaderSPIRV = shader_file.get_spirv()
	rids["shader"] = rd.shader_create_from_spirv(shader_spirv)
	if not rids["shader"].is_valid():
		log_error("Shader RID invalid!")
	non_freeing_rids["pipeline"] = rd.compute_pipeline_create(rids["shader"])

	var lin = RDSamplerState.new()
	lin.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	lin.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	lin.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	lin.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lin.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lin.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	rids["linear_sampler"] = rd.sampler_create(lin)

	uniforms["output_img"] = create_output_image(DEFAULT_FORMAT, 0, "output_img")
	uniforms["depth_img"] = create_output_image(DEPTH_FORMAT, 5, "depth_img")
	uniforms["scene_data"] = create_scenedata_buffer(1)
	uniforms["camera_data"] = create_camera_data(2)
	texture_uniform(RenderingServer.texture_get_rd_texture(ColorTex.get_rid()), DEFAULT_FORMAT, 4, "color_texture")
	
	create_uniform_set0()

	var seed_buffer_uni = create_seed_buffer(0)
	var merging_graph_uni = create_merging_graph_buffer(1)
	var precalc_buffer_uni = create_precalc_buffer(2)
	non_freeing_rids["uniform_set_1"] = create_uniform_set([
		seed_buffer_uni,
		merging_graph_uni,
		precalc_buffer_uni
	], 1)
	seed_data.resize(TOTAL_NR_SEEDS)
	
	build_scene(true)
	ready_to_run = true


func run_compute_shader():
	if not ready_to_run or shutting_down:
		return
	#region other run stuff
	var new_viewport_size: Vector2
	if Engine.is_editor_hint():
		new_viewport_size = Engine.get_singleton("EditorInterface").get_editor_viewport_3d().get_visible_rect().size
	else:
		new_viewport_size = get_viewport().get_visible_rect().size
	var recreate_output := new_viewport_size != viewport_size
	viewport_size = new_viewport_size
	DEFAULT_FORMAT.width = int(viewport_size.x)
	DEFAULT_FORMAT.height = int(viewport_size.y)
	DEPTH_FORMAT.width = int(viewport_size.x)
	DEPTH_FORMAT.height = int(viewport_size.y)
	if recreate_output:
		recreate_output_images()
	var camera: Camera3D
	if Engine.is_editor_hint():
		camera = Engine.get_singleton("EditorInterface").get_editor_viewport_3d().get_camera_3d()
	else:
		camera = get_viewport().get_camera_3d()
	update_camera_data(camera)

	var push_constant = _create_push_constant([
		viewport_size,
		GlobalBlendingFactor,
		AlbedoBlendOffset,
		camera.global_position,
		Time.get_ticks_msec() / 1000.0,
		ImplicitUVsBlending,
		PrecalcStage
	])

	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, non_freeing_rids["pipeline"])
	rd.compute_list_bind_uniform_set(compute_list, non_freeing_rids["uniform_set_0"], 0)
	rd.compute_list_bind_uniform_set(compute_list, non_freeing_rids["uniform_set_1"], 1)
	rd.compute_list_set_push_constant(
		compute_list, push_constant, push_constant.size())
	rd.compute_list_dispatch(compute_list, int(
		viewport_size.x / 8), int(viewport_size.y / 8), 1)
	rd.compute_list_end()
	#endregion
	
	if PrecalcStage != PrecalculationStage.PRECALC_DONE:
		update_scenedata_buffer()
		update_merging_graph_buffer()
	handle_precalculation()
	
	var rids_freed := 0
	for rid in rid_freeing_queue:
		if rid.is_valid():
			rd.call_deferred("free_rid", rid)
		rids_freed += 1
	if rids_freed == rid_freeing_queue.size():
		rid_freeing_queue.clear()

	var output_rid: RID = rids["output_img"]
	var depth_rid: RID = rids["depth_img"]
	if output_texture.texture_rd_rid != output_rid:
		output_texture.texture_rd_rid = output_rid
	if depth_texture.texture_rd_rid != depth_rid:
		depth_texture.texture_rd_rid = depth_rid


#region Precalc stuff
func run_precalc():
	if not ready_to_run:
		precalc_dirty = true
		return
	precalc_dirty = false
	PrecalcStage = PrecalculationStage.PRECALC_FRAMES
	update_seed_buffer()
	while PrecalcStage != PrecalculationStage.PRECALC_DONE:
		run_compute_shader()


func precalc_read_precalc_buffer_blendwidth() -> float:
	var buf := rd.buffer_get_data(rids["precalc_buffer"])
	# read the float at the beginning of the buffer to be the new blend width
	return buf.decode_float(0)

func precalc_read_precalc_buffer_matrices() -> Array[Transform3D]:
	var buf := rd.buffer_get_data(rids["precalc_buffer"])
	# prints("Buffer size:", buf.size())
	var matrices: Array[Transform3D] = []
	var matrices_end_byte := PRECALC_BUF_LOGMAPS_START - PRECALC_BUF_MATRICES_START
	# start at 16 because of float + 12 byte padding
	for i in range(PRECALC_BUF_MATRICES_START, matrices_end_byte, SIZE_MAT3):
		var vec1 := Vector3(buf.decode_float(i), buf.decode_float(i + 4), buf.decode_float(i + 8))
		var vec2 := Vector3(buf.decode_float(i + 16), buf.decode_float(i + 20), buf.decode_float(i + 24))
		var vec3 := Vector3(buf.decode_float(i + 32), buf.decode_float(i + 36), buf.decode_float(i + 40))
		matrices.append(Transform3D(vec1, vec2, vec3, Vector3.ZERO))
		#matrices.append(Transform3D(Vector3(vec1.x, vec2.x, vec3.x), Vector3(vec1.y, vec2.y, vec3.y), Vector3(vec1.z, vec2.z, vec3.z), Vector3.ZERO))
		# prints((i - 16) / buf.size() / SIZE_MAT3, [vec1, vec2, vec3])

	return matrices
	
func precalc_read_precalc_buffer_logmaps() -> Array[Vector2]:
	var buf := rd.buffer_get_data(rids["precalc_buffer"])
	var uvs: Array[Vector2] = []
	for i in range(PRECALC_BUF_LOGMAPS_START, PRECALC_BUF_SIZE, SIZE_VEC2):
		uvs.append(Vector2(buf.decode_float(i), buf.decode_float(i + 4)))

	return uvs


func precalc_read_and_apply_merging_graph_weights():
	var graph_buf := rd.buffer_get_data(rids["merging_graph_buffer"])
	var byte_start := (TOTAL_NR_SEEDS * 2 * 4) + (TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS * 4)
	for i in range(0, graph_buf.size() - byte_start, 4):
		var weight := graph_buf.decode_float(byte_start + i)
		if i == 0:
			#printt("Weight 0:", weight)
			pass
		@warning_ignore("integer_division")
		merging_graph.weights[i / 4] = weight



func precalc_apply_seed_pos_projections():
	var seed_buf := rd.buffer_get_data(rids["seed_buffer"])
	for i in range(0, seed_buf.size(), SIZE_MAT4):
		@warning_ignore("integer_division")
		var seed_idx := i / SIZE_MAT4
		# if seed is not active, skip
		if not seed_data[seed_idx].enabled:
			continue
		var seed_pos := Vector3(seed_buf.decode_float(i + 0), seed_buf.decode_float(i + 4), seed_buf.decode_float(i + 8))
		if seed_pos.is_finite():
			seed_data[seed_idx].position = seed_pos


func handle_precalculation():
	if PrecalcStage == PrecalculationStage.PRECALC_DONE:
		return
	
	# the stage we will transition to after this one
	var next_precalc_stage: PrecalculationStage
	
	precalc_read_and_apply_merging_graph_weights()
	
	var is_valid := true
	if PrecalcStage == PrecalculationStage.PRECALC_FRAMES:
		next_precalc_stage = PrecalculationStage.PRECALC_OFFSETS

		precalc_apply_seed_pos_projections()
		var matrices := precalc_read_precalc_buffer_matrices()
		var use_e1_as_ref := false
		var reference_seed_basis := seed_data[0].e1 if use_e1_as_ref else seed_data[0].e2
		var res := gdext.optimize_frames(merging_graph.offsets, merging_graph.neighbors, merging_graph.weights, matrices, reference_seed_basis)
		
		for ti in res:
			if not ti.is_finite():
				is_valid = false
				break
		
		if is_valid:
			if PrintPrecalcResults: log_info("Frames optimization result:")
			var seed_idx := 0
			for ti in res:
				# if seed not active: skip
				if not seed_data[seed_idx].enabled:
					seed_idx += 1
					continue
				
				if PrintPrecalcResults: log_info("seed: " + str(seed_idx), "ti: " + str(ti))
				if ti == Vector3.ZERO:
					if PrintPrecalcResults: log_info("    ti should not be zero! Skipping...")
					seed_idx += 1
					continue
				
				var seed_pos := seed_data[seed_idx].position
				var e1 := seed_data[seed_idx].e1
				var e2 := seed_data[seed_idx].e2
				
				@warning_ignore("integer_division")
				# object index of that seed
				var obj_idx := (seed_idx / NUM_SEEDS_PER_OBJ) * NUM_MATRICES_PER_OBJ
				var pos_to_seed := scene_data[obj_idx].inverse().origin.direction_to(seed_pos)
				# is it possible that this is not the exact normal? Maybe better do it in shader?
				var n := e1.cross(e2)
				if n.dot(pos_to_seed) < 0.0:
					n = e2.cross(e1)
				var ti_proj := project_onto_tangentplane(ti, n).normalized()
				if use_e1_as_ref:
					seed_data[seed_idx].e1 = ti_proj
					# e2 = n x e1 (sec. 4.4)
					seed_data[seed_idx].e2 = n.cross(ti_proj)
				else:
					seed_data[seed_idx].e2 = ti_proj
					seed_data[seed_idx].e1 = (-n).cross(ti_proj)
				
				seed_idx += 1
			if PrintPrecalcResults: log_info()
		
	elif PrecalcStage == PrecalculationStage.PRECALC_OFFSETS:
		next_precalc_stage = PrecalculationStage.PRECALC_DONE
		
		var logmaps := precalc_read_precalc_buffer_logmaps()
		var res := gdext.optimize_offsets(merging_graph.offsets, merging_graph.neighbors, merging_graph.weights, logmaps)
		
		for off in res:
			if not off.is_finite():
				is_valid = false
				break
		
		if is_valid:
			if PrintPrecalcResults: log_info("Offsets optimization result:")
			var seed_idx := 0
			for off in res:
				# if seed not active: skip
				if not seed_data[seed_idx].enabled:
					seed_idx += 1
					continue
				
				if PrintPrecalcResults: log_info("seed: " + str(seed_idx), "offset: " + str(off))
				seed_data[seed_idx].offset = off
				
				seed_idx += 1
			if PrintPrecalcResults: log_info()
		
			var has_defect := false
			for i in range(TOTAL_NR_SEEDS):
				var range_start = merging_graph.offsets[i * 2]
				var range_end = merging_graph.offsets[i * 2 + 1]
				var offset_i := res[i]
				var logmap_pi_pj := logmaps[range_start]
				for j in range(range_start, range_end):
					var neigh := merging_graph.neighbors[j]
					var offset_j := res[neigh]
					has_defect = has_defect or logmap_pi_pj.dot(offset_i - offset_j) < 0.0
			if has_defect:
				log_info("Detected defect in global UV")
	
	if is_valid:
		# no matter the precalc stage, we always want to update the seed buffer
		update_seed_buffer()
	else:
		log_warn("Optimization result is not valid!")
	
	PrecalcStage = next_precalc_stage
	if PrecalcStage == PrecalculationStage.PRECALC_DONE:
		ImplicitUVsBlending = precalc_read_precalc_buffer_blendwidth()
		visualize_seeds($Scene)


func project_onto_tangentplane(dir: Vector3, n: Vector3) -> Vector3:
	return dir - n * dir.dot(n)

#endregion


#region COMPUTE_SHADER_HELPERS
func get_view_matrix_data(camera: Camera3D) -> PackedFloat32Array:
	var view := camera.get_camera_transform()
	return PackedFloat32Array([
		# column 0
		view.basis.x.x, view.basis.x.y, view.basis.x.z, 0.0,
		# column 1
		view.basis.y.x, view.basis.y.y, view.basis.y.z, 0.0,
		# column 2
		view.basis.z.x, view.basis.z.y, view.basis.z.z, 0.0,
		# column 3
		view.origin.x, view.origin.y, view.origin.z, 1.0
	])


func get_inv_projection_matrix_data(
	camera: Camera3D,
	render_size: Vector2
) -> PackedFloat32Array:
	var aspect := render_size.x / render_size.y
	var keep_width := camera.keep_aspect == Camera3D.KEEP_WIDTH
	var projection := Projection()

	match camera.projection:
		Camera3D.PROJECTION_PERSPECTIVE:
			projection = Projection.create_perspective(
				camera.fov, aspect,
				camera.near, camera.far, keep_width
			)
		Camera3D.PROJECTION_ORTHOGONAL:
			projection = Projection.create_orthogonal_aspect(
				camera.size, aspect,
				camera.near, camera.far, keep_width
			)
		Camera3D.PROJECTION_FRUSTUM:
			projection = Projection.create_frustum_aspect(
				camera.size, aspect, camera.frustum_offset,
				camera.near, camera.far, keep_width
			)

	var inv := projection.inverse()
	return PackedFloat32Array([
		inv.x.x, inv.x.y, inv.x.z, inv.x.w,
		inv.y.x, inv.y.y, inv.y.z, inv.y.w,
		inv.z.x, inv.z.y, inv.z.z, inv.z.w,
		inv.w.x, inv.w.y, inv.w.z, inv.w.w,
	])


func create_camera_data(binding: int) -> RDUniform:
	var camera: Camera3D
	if Engine.is_editor_hint():
		camera = Engine.get_singleton("EditorInterface").get_editor_viewport_3d().get_camera_3d()
	else:
		camera = get_viewport().get_camera_3d()
	var inv_proj_data := get_inv_projection_matrix_data(camera, viewport_size).to_byte_array()
	var view_data := get_view_matrix_data(camera).to_byte_array()
	var data := PackedByteArray()
	data.append_array(inv_proj_data)
	data.append_array(view_data)
	rids["camera_data"] = rd.uniform_buffer_create(data.size(), data)
	var uni := RDUniform.new()
	uni.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	uni.binding = binding
	uni.add_id(rids["camera_data"])
	return uni


func update_camera_data(camera: Camera3D):
	if viewport_size.x <= 0 or viewport_size.y <= 0:
		return
	var inv_proj_data := get_inv_projection_matrix_data(camera, viewport_size).to_byte_array()
	var view_data := get_view_matrix_data(camera).to_byte_array()
	var data := PackedByteArray()
	data.append_array(inv_proj_data)
	data.append_array(view_data)
	rd.buffer_update(rids["camera_data"], 0, data.size(), data)


func create_scenedata_buffer(binding: int) -> RDUniform:
	var data := get_scenedata_data()
	rids["scenedata_buffer"] = rd.storage_buffer_create(data.size(), data)
	var uni := RDUniform.new()
	uni.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uni.binding = binding
	uni.add_id(rids["scenedata_buffer"])
	return uni


func update_scenedata_buffer():
	var data := get_scenedata_data()
	rd.buffer_update(rids["scenedata_buffer"], 0, data.size(), data)


func get_scenedata_data() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(16)  # 12 byte padding (because of mat4 alignment)
	bytes.encode_s32(0, num_scene_objects)
	for trans in scene_data:
		bytes.append_array(encode_transform(trans))
	return bytes


func encode_transform(trans: Transform3D) -> PackedByteArray:
	return PackedFloat32Array([
		# column 0
		trans.basis.x.x, trans.basis.x.y, trans.basis.x.z, 0.0,
		# column 1
		trans.basis.y.x, trans.basis.y.y, trans.basis.y.z, 0.0,
		# column 2
		trans.basis.z.x, trans.basis.z.y, trans.basis.z.z, 0.0,
		# column 3
		trans.origin.x, trans.origin.y, trans.origin.z, 1.0
	]).to_byte_array()



func create_seed_buffer(binding: int) -> RDUniform:
	var data := get_seed_data()
	rids["seed_buffer"] = rd.storage_buffer_create(data.size(), data)
	var uni := RDUniform.new()
	uni.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uni.binding = binding
	uni.add_id(rids["seed_buffer"])
	return uni


func update_seed_buffer():
	if not rids.has("seed_buffer"):
		push_warning("Seed buffer not found in rids Dictionary?!")
		return
	var data := get_seed_data()
	rd.buffer_update(rids["seed_buffer"], 0, data.size(), data)


func get_seed_data() -> PackedByteArray:
	var bytes := PackedByteArray()
	@warning_ignore("shadowed_global_identifier")
	for seed in seed_data:
		bytes.append_array(encode_seed(seed))
	return bytes

@warning_ignore("shadowed_global_identifier")
func encode_seed(seed: Seed) -> PackedByteArray:
	return PackedFloat32Array([
		# column 0
		seed.position.x, seed.position.y, seed.position.z, 0.0,
		# column 1
		seed.e1.x, seed.e1.y, seed.e1.z, 0.0,
		# column 2
		seed.e2.x, seed.e2.y, seed.e2.z, 0.0,
		# column 3
		seed.offset.x, seed.offset.y, float(seed.enabled), seed.max_walk_dist
	]).to_byte_array()




func create_merging_graph_buffer(binding: int) -> RDUniform:
	var bytes := get_merging_graph_data()
	rids["merging_graph_buffer"] = rd.storage_buffer_create(
		bytes.size(), bytes)
	var uni := RDUniform.new()
	uni.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uni.binding = binding
	uni.add_id(rids["merging_graph_buffer"])
	return uni


func update_merging_graph_buffer():
	var bytes := get_merging_graph_data()
	rd.buffer_update(rids["merging_graph_buffer"], 0, bytes.size(), bytes)


func get_merging_graph_data() -> PackedByteArray:
	var bytes := PackedByteArray()

	var offsets := PackedByteArray()
	offsets.resize(TOTAL_NR_SEEDS * 2 * 4)
	var byte_offset := 0
	for v in merging_graph.offsets:
		offsets.encode_s32(byte_offset, v)
		byte_offset += 4
	byte_offset = 0

	var neighbors := PackedByteArray()
	neighbors.resize(TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS * 4)
	for v in merging_graph.neighbors:
		neighbors.encode_s32(byte_offset, v)
		byte_offset += 4
	byte_offset = 0

	var weights := PackedByteArray()
	weights.resize(TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS * 4)
	for v in merging_graph.weights:
		weights.encode_float(byte_offset, v)
		byte_offset += 4
	byte_offset = 0

	bytes.append_array(offsets)
	bytes.append_array(neighbors)
	bytes.append_array(weights)
	return bytes


func create_precalc_buffer(binding: int) -> RDUniform:
	var bytes := PackedByteArray()
	bytes.resize(PRECALC_BUF_SIZE)
	rids["precalc_buffer"] = rd.storage_buffer_create(bytes.size(), bytes)
	var uni := RDUniform.new()
	uni.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uni.binding = binding
	uni.add_id(rids["precalc_buffer"])
	return uni


# Creates a new image on the RD and returns its uniform
func create_output_image(format: RDTextureFormat, binding: int, imgname: StringName) -> RDUniform:
	var image_rid = rd.texture_create(format, RDTextureView.new())
	rd.texture_clear(image_rid, Color(0.0, 0.0, 0.0, 0), 0, 1, 0, 1)
	rids[imgname] = image_rid
	var image_uni := RDUniform.new()
	image_uni.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uni.binding = binding
	image_uni.add_id(image_rid)
	return image_uni


func recreate_output_images():
	if rids.has("output_img"):
		rid_freeing_queue.append(rids["output_img"])
	if rids.has("depth_img"):
		rid_freeing_queue.append(rids["depth_img"])

	var image_rid = rd.texture_create(DEFAULT_FORMAT, RDTextureView.new())
	rd.texture_clear(image_rid, Color(0.0, 0.0, 0.0, 0), 0, 1, 0, 1)
	rids["output_img"] = image_rid
	uniforms["output_img"].clear_ids()
	uniforms["output_img"].add_id(image_rid)
	
	var depth_image_rid = rd.texture_create(DEPTH_FORMAT, RDTextureView.new())
	rd.texture_clear(depth_image_rid, Color(0.0, 0.0, 0.0, 0), 0, 1, 0, 1)
	rids["depth_img"] = depth_image_rid
	uniforms["depth_img"].clear_ids()
	uniforms["depth_img"].add_id(depth_image_rid)
	
	create_uniform_set0()


func create_uniform_set0():
	if non_freeing_rids.has("uniform_set_0"):
		var old_set: RID = non_freeing_rids["uniform_set_0"]
		if rd.uniform_set_is_valid(old_set):
			rd.free_rid(old_set)
	non_freeing_rids["uniform_set_0"] = create_uniform_set([
		uniforms["output_img"],
		uniforms["depth_img"],
		uniforms["scene_data"],
		uniforms["camera_data"],
		uniforms["color_texture"]
	], 0)


# Creates a texture on the RD with a sampler and returns its uniform
func texture_uniform(texture_rid, format: RDTextureFormat, binding: int, uname: StringName):
	if rids.has("texture" + "_" + uname):
		rd.free_rid(rids["texture" + "_" + uname])
		rids.erase("texture" + "_" + uname)
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	if texture_rid == null:
		texture_rid = rd.texture_create(format, RDTextureView.new())
		rids["texture" + "_" + uname] = texture_rid
		rd.texture_clear(texture_rid, Color(0.0, 0.0, 0.0, 0), 0, 1, 0, 1)
	uniform.add_id(rids["linear_sampler"])
	uniform.add_id(texture_rid)
	
	uniforms[uname] = uniform


func create_uniform_set(uniform_list: Array[RDUniform], set_binding: int) -> RID:
	var set_rid = rd.uniform_set_create(uniform_list, rids["shader"], set_binding)
	return set_rid


func new_texture_format(format: RenderingDevice.DataFormat) -> RDTextureFormat:
	var tex_format: RDTextureFormat = RDTextureFormat.new()
	tex_format.format = format
	tex_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tex_format.width = int(viewport_size.x)
	tex_format.height = int(viewport_size.y)
	tex_format.depth = 1
	tex_format.array_layers = 1
	tex_format.mipmaps = 1
	tex_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT + RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT + \
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + \
		RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	# if true and Engine.is_editor_hint():
	tex_format.usage_bits += RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	return tex_format


func _create_push_constant(values: Array[Variant]) -> PackedByteArray:
	# var push_constant := PackedByteArray()
	var push_constant := PackedByteArray()
	push_constant.resize(128)
	var byte_offset := 0
	for v in values:
		if v is float:
			push_constant.encode_float(byte_offset, v)
			byte_offset += 4
		elif v is int:
			push_constant.encode_s32(byte_offset, v)
			byte_offset += 4
		elif v is Vector2:
			push_constant.encode_float(byte_offset, v.x)
			byte_offset += 4
			push_constant.encode_float(byte_offset, v.y)
			byte_offset += 4
		elif v is Vector2i:
			push_constant.encode_s32(byte_offset, v.x)
			byte_offset += 4
			push_constant.encode_s32(byte_offset, v.y)
			byte_offset += 4
		elif v is Vector3:
			push_constant.encode_float(byte_offset, v.x)
			byte_offset += 4
			push_constant.encode_float(byte_offset, v.y)
			byte_offset += 4
			push_constant.encode_float(byte_offset, v.z)
			byte_offset += 4
		elif v is Vector4:
			push_constant.encode_float(byte_offset, v.x)
			byte_offset += 4
			push_constant.encode_float(byte_offset, v.y)
			byte_offset += 4
			push_constant.encode_float(byte_offset, v.z)
			byte_offset += 4
			push_constant.encode_float(byte_offset, v.w)
			byte_offset += 4
		elif v is Color:
			push_constant.encode_float(byte_offset, v.r)
			byte_offset += 4
			push_constant.encode_float(byte_offset, v.g)
			byte_offset += 4
			push_constant.encode_float(byte_offset, v.b)
			byte_offset += 4
			push_constant.encode_float(byte_offset, v.a)
			byte_offset += 4
		elif v is bool:
			push_constant.encode_s32(byte_offset, int(v))
			byte_offset += 4
		else:
			log_error("Value " + str(v) +
					   "could not be encoded in push constant")
		# byte_offset += len
	# if byte_offset <= 16:
		# push_constant.resize(16)
	# elif byte_offset > 32 and byte_offset <= 48:
		# push_constant.resize(48)
	# else:
	# printt(byte_offset, push_constant.size())
	push_constant.resize(byte_offset)
	# push_constant.resize(nearest_po2(byte_offset))

	return push_constant
#endregion

# =========================== BUILDING THE SCENE ===========================
func build_scene(force_update: bool=false):
	if !is_inside_tree():
		return
	var node_to_seedidx_mapping: Dictionary[ImplicitUVsSeed, int] = {}
	# we only collect the link nodes in the collect_scene_data function and then
	# use the node_to_seedidx_mapping to build the merging graph
	var seed_links: Array[ImplicitUVsLink] = []
	
	var new_num_objects := 0
	var new_scene_data: Array[Transform3D]
	new_scene_data.resize(MAX_NUM_OBJECTS * NUM_MATRICES_PER_OBJ)
	var new_seed_data: Array[Seed]
	new_seed_data.resize(TOTAL_NR_SEEDS)
	seed_data.resize(TOTAL_NR_SEEDS)
	new_num_objects = collect_scene_data($Scene, new_num_objects, new_scene_data, new_seed_data, node_to_seedidx_mapping, seed_links)
	
	var new_graph := MergingGraph.new()
	for link in seed_links:
		if not is_instance_valid(link.SeedA) or not is_instance_valid(link.SeedB):
			continue
		if node_to_seedidx_mapping.has(link.SeedA) and node_to_seedidx_mapping.has(link.SeedB):
			var a_idx := node_to_seedidx_mapping[link.SeedA]
			var b_idx := node_to_seedidx_mapping[link.SeedB]
			
			if not new_seed_data[a_idx].enabled:
				log_warn("Seed A of link '", link.name, "' is not enabled!")
				continue
			if not new_seed_data[b_idx].enabled:
				log_warn("Seed B of link '", link.name, "' is not enabled!")
				continue
			new_graph.insert_edge(a_idx, b_idx)
	
	# in collect_scene_data, we only make sure that each object has NUM_SEEDS_PER_OBJ seeds, but dont assure
	# that there is TOTAL_NR_SEEDS (for example if there arent enough objects)
	var num_seeds_left = TOTAL_NR_SEEDS - new_num_objects * NUM_SEEDS_PER_OBJ
	for i in range(TOTAL_NR_SEEDS - num_seeds_left, TOTAL_NR_SEEDS):
		new_seed_data[i] = inactive_seed()
	
	if force_update or \
		new_num_objects != num_scene_objects or \
		new_scene_data != scene_data or \
		not seed_arrays_eq(new_seed_data, seed_data_after_scenebuild) or \
		not new_graph.eq(merging_graph):

		log_info("Rebuilt scene")
		num_scene_objects = new_num_objects
		scene_data = new_scene_data
		if ready_to_run:
			update_scenedata_buffer()
		# we need to do this in order to copy it
		for i in range(TOTAL_NR_SEEDS):
			var s: Seed = new_seed_data[i]
			seed_data[i] = Seed.new(s.position, s.e1, s.e2, s.max_walk_dist, s.enabled)
		seed_data_after_scenebuild = new_seed_data
		merging_graph = new_graph
		merging_graph.build()
		visualize_seeds($Scene)
		run_precalc()


func collect_scene_data(
	parent: Node,
	num_sdfs: int,
	new_scene_data: Array[Transform3D],
	new_seed_data: Array[Seed],
	node_to_seedidx_mapping: Dictionary[ImplicitUVsSeed, int],
	seed_links: Array[ImplicitUVsLink]) -> int:
	if num_sdfs > MAX_NUM_OBJECTS:
		log_warn("Maximum number of objects reached!")
		return num_sdfs
	if parent is CoordinateSystem:
		return num_sdfs
	for node in parent.get_children():
		if not node or (node.has_method("is_visible_in_tree") and not node.is_visible_in_tree()):
			continue

		if node is not SDFMesh and node.get_child_count() > 0:
			num_sdfs = collect_scene_data(node, num_sdfs, new_scene_data, new_seed_data, node_to_seedidx_mapping, seed_links)
			continue
		
		if node is ImplicitUVsLink and node.Enabled:
			seed_links.append(node)
			continue
		if node is ImplicitUVsSeed: # this gets handled by the SDFMeshes children loop below
			continue
		
		var meshinst = node as SDFMesh # no need to check, as this will always apply
		if not meshinst:
			continue
		var m: Mesh = meshinst.mesh
	
		var seeds: Array[Seed] = []
		var seed_targets: Array[Vector4] = []
		var seed_nodes: Array[ImplicitUVsSeed] = []
		# process all the seeds of this SDF mesh
		for child in meshinst.get_children():
			@warning_ignore("shadowed_global_identifier")
			var seed = child as ImplicitUVsSeed
			if not seed:
				continue
			if not seed.Enabled:
				seed_nodes.append(seed)
				continue
			seed_nodes.append(seed)
			var e1: Vector3 = seed.global_basis.x.normalized()
			var e2: Vector3 = seed.global_basis.z.normalized()
			seeds.append( Seed.new(seed.global_position, e1, e2, seed.MaxWalkDist, seed.Enabled) )
		
		var mesh_type := 0
		var mesh_data := Vector3.ZERO
		if m is SphereMesh:
			mesh_type = 1
			mesh_data = Vector3(m.radius, 0.0, 0.0)
		elif m is BoxMesh:
			mesh_type = 2
			mesh_data = Vector3(m.size.x, m.size.y, m.size.z) * 0.5
		elif m is CylinderMesh:
			mesh_type = 3
			mesh_data = Vector3(m.top_radius, m.bottom_radius, m.height)

		elif m is TorusMesh:
			mesh_type = 4
			mesh_data = Vector3(m.outer_radius, m.inner_radius, 0.0)

		assert (seeds.size() <= NUM_SEEDS_PER_OBJ)
		
		# fill seeds with inactive seeds (in case we didnt use up 
		# all NUM_SEEDS_PER_OBJ for that object)
		for i in range(NUM_SEEDS_PER_OBJ - seeds.size()):
			seeds.append( inactive_seed() )
			seed_nodes.append(null)
		
		var active_seedidx := 0
		for i in range(NUM_SEEDS_PER_OBJ):
			if not seed_nodes[i] or not seed_nodes[i].Enabled:
				continue
			var global_seedidx := num_sdfs * NUM_SEEDS_PER_OBJ + active_seedidx
			node_to_seedidx_mapping[seed_nodes[i]] = global_seedidx
			active_seedidx += 1

		# Used to transform the 3D sampling position in world space back to SDF local space
		var inverse_transform: Transform3D = meshinst.global_transform.affine_inverse()
		new_scene_data[num_sdfs * NUM_MATRICES_PER_OBJ] = inverse_transform
		var sdf_mode := int(meshinst.Mode)
		var blending_factor: float = meshinst.BlendingFactor
		var data := Transform3D(Vector3(float(mesh_type), float(sdf_mode), blending_factor), mesh_data, Vector3.ZERO, Vector3.ZERO)
		new_scene_data[num_sdfs * NUM_MATRICES_PER_OBJ + 1] = data

		for i in range(NUM_SEEDS_PER_OBJ):
			var global_seedidx := num_sdfs * NUM_SEEDS_PER_OBJ + i
			new_seed_data[global_seedidx] = seeds[i]
		num_sdfs += 1
		# Parent has now been stored. Visit its descendants exactly once.
		num_sdfs = collect_scene_data(
			meshinst,
			num_sdfs,
			new_scene_data,
			new_seed_data,
			node_to_seedidx_mapping,
			seed_links
		)

	return num_sdfs


func inactive_seed() -> Seed:
	return Seed.new(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, 0.0, false)


func seed_arrays_eq(arrayA: Array[Seed], arrayB: Array[Seed]) -> bool:
	if arrayA.size() != arrayB.size():
		return false
	for i in range(arrayA.size()):
		var a := arrayA[i]
		var b := arrayB[i]
		if not a.eq(b):
			return false
	return true


func visualize_seeds(root_node: Node) -> void:
	if not is_instance_valid(root_node):
		return

	# Clear old visualizations, including those under hidden meshes.
	_clear_seed_visualizations(root_node)

	if VisualizeSeeds == 0:
		return

	var meshes: Array[SDFMesh] = []
	_collect_visible_sdf_meshes(root_node, meshes)

	for mesh_idx in range(meshes.size()):
		var meshinst := meshes[mesh_idx]
		var coords_scale: float = 0.5
		var cylinder := meshinst.mesh as CylinderMesh
		if cylinder != null:
			coords_scale = clampf((cylinder.top_radius + cylinder.bottom_radius) * 0.5, 0.1, 0.5)

		# Your collector packs enabled seeds into consecutive slots.
		var enabled_seed_idx := 0

		for child in meshinst.get_children():
			var seed_node := child as ImplicitUVsSeed
			if seed_node == null or not seed_node.Enabled:
				continue

			var local_seed_idx := enabled_seed_idx
			enabled_seed_idx += 1
			var seed_state: Seed = null

			if VisualizeSeeds != 1:
				if local_seed_idx >= NUM_SEEDS_PER_OBJ:
					push_warning(
						"Too many enabled seeds on %s" % meshinst.name
					)
					break

				var global_seed_idx := (
					mesh_idx * NUM_SEEDS_PER_OBJ + local_seed_idx
				)
				if global_seed_idx >= seed_data.size():
					continue

				seed_state = seed_data[global_seed_idx]
				if seed_state == null or not seed_state.enabled:
					continue

			var coords: Node3D = COORDINATE_SYSTEM.instantiate()
			coords.name = "CoordinateSystem_%d" % local_seed_idx
			seed_node.add_child(coords)
			coords.owner = self
			coords.get_node("Y").hide()

			if VisualizeSeeds == 1:
				# Before precalc: inherit the seed marker's transform.
				coords.scale = Vector3.ONE * coords_scale
			else:
				# After precalc: use the computed world-space frame.
				var e1 := seed_state.e1.normalized()
				var e2 := seed_state.e2.normalized()
				var frame := Basis(
					e1,
					e2.cross(e1).normalized(),
					e2
				)
				coords.global_transform = Transform3D(
					frame.scaled(Vector3.ONE * coords_scale),
					seed_state.position
				)


func _collect_visible_sdf_meshes(
	node: Node,
	meshes: Array[SDFMesh]
) -> void:
	if node is ImplicitUVsLink or node is ImplicitUVsSeed:
		return

	if node is Node3D and not node.is_visible_in_tree():
		return

	if node is SDFMesh:
		meshes.append(node)

	for child in node.get_children():
		_collect_visible_sdf_meshes(child, meshes)


func _clear_seed_visualizations(node: Node) -> void:
	for child in node.get_children():
		if node is ImplicitUVsSeed and child is CoordinateSystem:
			child.free()
		else:
			_clear_seed_visualizations(child)

class MergingGraph:
	# the data used to build the lists
	var data: Dictionary[int, Dictionary] = {}
	var num_nodes: int
	var offsets: Array[int] = []
	var neighbors: Array[int] = []
	var weights: Array[float] = []

	func _init() -> void:
		offsets.resize(TOTAL_NR_SEEDS * 2)

	func insert_edge(from: int, to: int):
		if !data.has(from) or !data.has(to):
			if !data.has(from):
				data[from] = {}
			if !data.has(to):
				data[to] = {}
		else:
			if (data[from ].size() >= MAX_NUM_MERGE_NEIGHBORS):
				MainScript.log_error("Cannot add another edge, as seed ", from , " has already reached its maximum neighbor count")
				return
		data[from][to] = 1.0
		data[to][from] = 1.0

	func build():
		var cycle := self.detect_cycles()
		if cycle != Vector2i.ZERO:
			MainScript.log_warn("Merging graph contains a cycle. Cycle closed at: ", cycle.x , " -> ", cycle.y)
		offsets.clear()
		offsets.resize(TOTAL_NR_SEEDS * 2)
		neighbors.clear()
		weights.clear()
		num_nodes = data.size()
		var cur_offset = 0
		for i in range(TOTAL_NR_SEEDS):
			var edges = data.get(i)
			offsets[i * 2] = cur_offset
			if edges:
				var num_edges: int = edges.size()
				cur_offset += num_edges
				for edge_end in edges.keys():
					neighbors.append(edge_end)
					weights.append(edges[edge_end])
			offsets[i * 2 + 1] = cur_offset
		# needs to happen here, since we want to use append for ease of use
		neighbors.resize(TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS)
		weights.resize(TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS)
	
	func detect_cycles() -> Vector2i:
		var visited: Array[int] = []
		for node in data.keys():
			if not visited.has(node):
				var c := cycle_helper(node, -1, visited)
				if c != Vector2i.ZERO:
					return c
		return Vector2i.ZERO
	
	func cycle_helper(node: int, parent: int, visited: Array[int]) -> Vector2i:
		visited.append(node)
		
		if data.has(node):
			for neigh in data[node].keys():
				if !visited.has(neigh):
					var c := cycle_helper(neigh, node, visited)
					if c != Vector2i.ZERO:
						return c
				elif neigh != parent:
					return Vector2i(parent, neigh)
		
		return Vector2i.ZERO
	
	func eq(other: MergingGraph) -> bool:
		return self.data.recursive_equal(other.data, 12)


static func log_info(...args):
	if LogLvl >= LogLevel.LOG_INFO:
		printt.callv(args)

static func log_warn(...args):
	if LogLvl >= LogLevel.LOG_WARN:
		push_warning.callv(args)

static func log_error(...args):
	if LogLvl >= LogLevel.LOG_ERROR:
		push_error.callv(args)
