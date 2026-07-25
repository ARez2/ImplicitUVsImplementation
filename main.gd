@tool
extends Node3D
class_name MainScript

@export_range(0.001, 30.0, 0.001) var GlobalBlendingFactor := 0.046:
	set(v):
		if v != GlobalBlendingFactor:
			GlobalBlendingFactor = v
			precalc_dirty = true
# @export_range(0.0, 32.0, 0.001) var AlbedoBlendPower := 1.0
@export_range(0.0, 1.0, 0.001) var AlbedoBlendOffset := 0.211
@export_range(0.0, 1.0, 0.001) var ImplicitUVsBlending := 0.179
@export var ColorTex: Texture2D
@export_tool_button("Do a precalc!") var PrecalcButton = do_precalc
@export var PrintPrecalcResults := false
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
@export var VisualizeSeeds := false:
	set(v):
		if v != VisualizeSeeds:
			VisualizeSeeds = v
			if is_inside_tree():
				visualize_seeds($Scene)
@export var UpdateSeedsAfterPrecalc := false
# Transform3D gets converted to mat4
var scene_data: Array[Transform3D] = []
var num_scene_objects := 0
var seed_data: Array[Transform3D] = []
var merging_graph: MergingGraph

const COORDINATE_SYSTEM = preload("uid://bts105g652v5w")

# must be the same as in the shader
const NUM_SEEDS_PER_OBJ := 3
const NUM_MATRICES_PER_OBJ := 2
const MAX_NUM_OBJECTS := 16
const MAX_NUM_MERGE_NEIGHBORS := 16
const TOTAL_NR_SEEDS := NUM_SEEDS_PER_OBJ * MAX_NUM_OBJECTS

# compute shader stuff
var ready_to_run := false
var rd: RenderingDevice
var rids: Dictionary[String, RID] = {}
var non_freeing_rids: Dictionary[String, RID] = {}
var viewport_size: Vector2 = Vector2.ZERO
var DEFAULT_FORMAT: RDTextureFormat
var uniforms: Dictionary[String, RDUniform] = {}
var rid_freeing_queue: Array[RID] = []
func do_precalc():
	build_scene(true)

enum PrecalculationStage {
	PRECALC_FRAMES = 1,
	PRECALC_OFFSETS = 2,
	PRECALC_DONE = 0,
}
var PrecalcStage := PrecalculationStage.PRECALC_DONE
var precalc_dirty := false

const SIZE_VEC2 := 8
# because of std430 layout, a mat3 is 3x (vec3 + 4 byte padding)
const SIZE_MAT3 := 48
const SIZE_MAT4 := 64
var gdext := MyExtension.new()
const PRECALC_BUF_MATRICES_START := 16
const PRECALC_BUF_LOGMAPS_START := PRECALC_BUF_MATRICES_START + TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS * SIZE_MAT3
const PRECALC_BUF_SIZE := PRECALC_BUF_LOGMAPS_START + TOTAL_NR_SEEDS * MAX_NUM_MERGE_NEIGHBORS * SIZE_VEC2

func _ready() -> void:
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
func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		for rid_key in rids:
			var rid := rids[rid_key]
			if rid.is_valid() and not rid_freeing_queue.has(rid):
				rd.call_deferred("free_rid", rid)
		for rid in rid_freeing_queue:
			if rid.is_valid():
				rd.call_deferred("free_rid", rid)
		rid_freeing_queue.clear()
		#RenderingServer.free_rid(rd)


func setup_compute_shader():
	rd = RenderingServer.get_rendering_device()

	if Engine.is_editor_hint():
		viewport_size = Engine.get_singleton("EditorInterface").get_editor_viewport_3d().get_visible_rect().size
	else:
		viewport_size = get_viewport().get_visible_rect().size

	DEFAULT_FORMAT = new_texture_format(
		RenderingDevice.DataFormat.DATA_FORMAT_R32G32B32A32_SFLOAT)

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

	uniforms["output_img"] = create_output_image(DEFAULT_FORMAT, 0)
	uniforms["scene_data"] = create_scenedata_buffer(1)
	uniforms["camera_data"] = create_camera_data(2)
	uniforms["color_texture"] = texture_uniform(
		RenderingServer.texture_get_rd_texture(ColorTex.get_rid()), DEFAULT_FORMAT, 4)
	
	non_freeing_rids["uniform_set_0"] = create_uniform_set([
		uniforms["output_img"],
		uniforms["scene_data"],
		uniforms["camera_data"],
		uniforms["color_texture"]
	], 0)

	var seed_buffer_uni = create_seed_buffer(0)
	var merging_graph_uni = create_merging_graph_buffer(1)
	var precalc_buffer_uni = create_precalc_buffer(2)
	non_freeing_rids["uniform_set_1"] = create_uniform_set([
		seed_buffer_uni,
		merging_graph_uni,
		precalc_buffer_uni
	], 1)
	ready_to_run = true
	build_scene(true)


func run_compute_shader():
	if !ready_to_run:
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
	if recreate_output:
		recreate_output_image(DEFAULT_FORMAT)
	var camera: Camera3D
	if Engine.is_editor_hint():
		camera = Engine.get_singleton("EditorInterface").get_editor_viewport_3d().get_camera_3d()
	else:
		camera = get_viewport().get_camera_3d()
	update_camera_data()

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

	if %RaymarcherTexShower.get_surface_override_material(0).get_shader_parameter("tex") is not Texture2DRD:
		var tex := Texture2DRD.new()
		tex.texture.texture_rd_rid = uniforms["output_img"].get_ids()[0]
		%RaymarcherTexShower.get_surface_override_material(0).set_shader_parameter("tex", tex)
	else:
		var tex: Texture2DRD = %RaymarcherTexShower.get_surface_override_material(0).get_shader_parameter("tex")
		tex.texture_rd_rid = uniforms["output_img"].get_ids()[0]
		%RaymarcherTexShower.get_surface_override_material(0).set_shader_parameter("tex", tex)


#region Precalc stuff
func run_precalc():
	if not ready_to_run:
		precalc_dirty = true
		return
	precalc_dirty = false
	PrecalcStage = PrecalculationStage.PRECALC_FRAMES
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
		if not bool(seed_data[seed_idx].origin.z):
			continue
		var seed_pos := Vector3(seed_buf.decode_float(i + 0), seed_buf.decode_float(i + 4), seed_buf.decode_float(i + 8))
		if seed_pos.is_finite():
			seed_data[seed_idx].basis.x = seed_pos


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
		var reference_seed_basis := seed_data[0].basis.y # e1 of first seed (e2 would be basis.z)
		var res := gdext.optimize_frames(merging_graph.offsets, merging_graph.neighbors, merging_graph.weights, matrices, reference_seed_basis)
		
		for ti in res:
			if not ti.is_finite():
				is_valid = false
				break
		
		if is_valid:
			log_info("Frames optimization result:")
			var seed_idx := 0
			for ti in res:
				# if seed not active: skip
				if not bool(seed_data[seed_idx].origin.z):
					seed_idx += 1
					continue
				
				log_info("seed: " + str(seed_idx), "ti: " + str(ti))
				if ti == Vector3.ZERO:
					log_info("    ti should not be zero! Skipping...")
					seed_idx += 1
					continue
				
				var seed_pos := seed_data[seed_idx].basis.x
				var e1 := seed_data[seed_idx].basis.y
				var e2 := seed_data[seed_idx].basis.z
				
				@warning_ignore("integer_division")
				# object index of that seed
				var obj_idx := (seed_idx / NUM_SEEDS_PER_OBJ) * NUM_MATRICES_PER_OBJ
				var pos_to_seed := scene_data[obj_idx].inverse().origin.direction_to(seed_pos)
				# is it possible that this is not the exact normal? Maybe better do it in shader?
				var n := e1.cross(e2)
				if n.dot(pos_to_seed) < 0.0:
					n = e2.cross(e1)
				var ti_proj := project_onto_tangentplane(ti, n).normalized()
				if UpdateSeedsAfterPrecalc:
					seed_data[seed_idx].basis.y = ti_proj
					# e2 = n x e1 (sec. 4.4)
					seed_data[seed_idx].basis.z = n.cross(ti_proj)
				
				seed_idx += 1
			log_info()
		
	elif PrecalcStage == PrecalculationStage.PRECALC_OFFSETS:
		next_precalc_stage = PrecalculationStage.PRECALC_DONE
		
		var logmaps := precalc_read_precalc_buffer_logmaps()
		var res := gdext.optimize_offsets(merging_graph.offsets, merging_graph.neighbors, merging_graph.weights, logmaps)
		
		for off in res:
			if not off.is_finite():
				is_valid = false
				break
		
		if is_valid:
			log_info("Offsets optimization result:")
			var seed_idx := 0
			for off in res:
				# if seed not active: skip
				if not bool(seed_data[seed_idx].origin.z):
					seed_idx += 1
					continue
				
				log_info("seed: " + str(seed_idx), "offset: " + str(off))
				seed_data[seed_idx].origin.x = off.x
				seed_data[seed_idx].origin.y = off.y
				seed_idx += 1
			log_info()
		
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
				log_warn("Detected defect in global UV")
	
	if is_valid:
		# no matter the precalc stage, we always want to update the seed buffer
		update_seed_buffer()
	else:
		log_warn("Optimization result is not valid!")
	
	PrecalcStage = next_precalc_stage
	if PrecalcStage == PrecalculationStage.PRECALC_DONE:
		ImplicitUVsBlending = precalc_read_precalc_buffer_blendwidth()
		if UpdateSeedsAfterPrecalc:
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


func get_inv_projection_matrix_data(camera: Camera3D) -> PackedFloat32Array:
	var proj := camera.get_camera_projection().inverse()
	return PackedFloat32Array([
		proj.x.x, proj.x.y, proj.x.z, proj.x.w,
		proj.y.x, proj.y.y, proj.y.z, proj.y.w,
		proj.z.x, proj.z.y, proj.z.z, proj.z.w,
		proj.w.x, proj.w.y, proj.w.z, proj.w.w,
	])


func create_camera_data(binding: int) -> RDUniform:
	var camera: Camera3D
	if Engine.is_editor_hint():
		camera = Engine.get_singleton("EditorInterface").get_editor_viewport_3d().get_camera_3d()
	else:
		camera = get_viewport().get_camera_3d()
	var inv_proj_data := get_inv_projection_matrix_data(camera).to_byte_array()
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


func update_camera_data():
	var camera: Camera3D
	if Engine.is_editor_hint():
		camera = Engine.get_singleton("EditorInterface").get_editor_viewport_3d().get_camera_3d()
	else:
		camera = get_viewport().get_camera_3d()
	var inv_proj_data := get_inv_projection_matrix_data(camera).to_byte_array()
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


func create_seed_buffer(binding: int) -> RDUniform:
	var data := get_seed_data()
	rids["seed_buffer"] = rd.storage_buffer_create(data.size(), data)
	var uni := RDUniform.new()
	uni.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uni.binding = binding
	uni.add_id(rids["seed_buffer"])
	return uni


func update_seed_buffer():
	var data := get_seed_data()
	rd.buffer_update(rids["seed_buffer"], 0, data.size(), data)


func get_seed_data() -> PackedByteArray:
	var bytes := PackedByteArray()
	for trans in seed_data:
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
func create_output_image(format: RDTextureFormat, binding: int) -> RDUniform:
	var image_rid = rd.texture_create(format, RDTextureView.new())
	rd.texture_clear(image_rid, Color(0.0, 0.0, 0.0, 0), 0, 1, 0, 1)
	rids["output_image"] = image_rid
	var image_uni := RDUniform.new()
	image_uni.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uni.binding = binding
	image_uni.add_id(image_rid)
	return image_uni


func recreate_output_image(format: RDTextureFormat):
	if rids.has("output_image"):
		rid_freeing_queue.append(rids["output_image"])

	var image_rid = rd.texture_create(format, RDTextureView.new())
	rd.texture_clear(image_rid, Color(0.0, 0.0, 0.0, 0), 0, 1, 0, 1)
	rids["output_image"] = image_rid
	uniforms["output_img"].clear_ids()
	uniforms["output_img"].add_id(image_rid)
	
	non_freeing_rids["uniform_set_0"] = create_uniform_set([
		uniforms["output_img"],
		uniforms["scene_data"],
		uniforms["camera_data"],
		uniforms["color_texture"]
	], 0)


# Creates a texture on the RD with a sampler and returns its uniform
func texture_uniform(texture_rid, format: RDTextureFormat, binding: int) -> RDUniform:
	var input_tex_uniform := RDUniform.new()
	input_tex_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	input_tex_uniform.binding = binding
	if texture_rid == null:
		texture_rid = rd.texture_create(format, RDTextureView.new())
		rids["texture" + str(binding) + "_" + str(format.format)] = texture_rid
		rd.texture_clear(texture_rid, Color(0.0, 0.0, 0.0, 0), 0, 1, 0, 1)
	input_tex_uniform.add_id(rids["linear_sampler"])
	input_tex_uniform.add_id(texture_rid)
	return input_tex_uniform


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
	var new_num_objects := 0
	var new_scene_data: Array[Transform3D]
	new_scene_data.resize(MAX_NUM_OBJECTS * NUM_MATRICES_PER_OBJ)
	var new_seed_data: Array[Transform3D]
	new_seed_data.resize(TOTAL_NR_SEEDS)
	var new_graph := MergingGraph.new()
	new_num_objects = collect_scene_data($Scene, new_num_objects, new_scene_data, new_seed_data, new_graph)

	if force_update or new_num_objects != num_scene_objects or new_scene_data != scene_data:
		log_info("Rebuilt scene")
		num_scene_objects = new_num_objects
		scene_data = new_scene_data
		seed_data = new_seed_data
		merging_graph = new_graph
		merging_graph.build()
		visualize_seeds($Scene)
		run_precalc()


const MERGE_ALL_SEEDS_ON_SAME_OBJECT := false
const MERGE_ALL_SEEDS_BETWEEN_OBJECTS := false
const PRINT_SEED_CONNECTIONS := true
func collect_scene_data(parent: Node, num_objects: int, new_scene_data: Array[Transform3D], new_seed_data: Array[Transform3D], graph: MergingGraph) -> int:
	for node in parent.get_children():
		if not node.is_visible_in_tree():
			continue
		var meshinst = node as SDFMesh
		if !meshinst and node.get_child_count() > 0:
			num_objects += collect_scene_data(node, num_objects,
											  new_scene_data, new_seed_data, graph)
			continue
		var m: Mesh = meshinst.mesh
		var sdf_mode := int(meshinst.Mode)
		var blending_factor: float = meshinst.BlendingFactor
		# Used to transform the 3D sampling position in world space back to SDF local space
		var inverse_transform: Transform3D = meshinst.global_transform.affine_inverse()
		var trans: Transform3D = meshinst.global_transform

		var mesh_type := 0
		var mesh_data := Vector3.ZERO
		var seeds := Array()

		if m is SphereMesh:
			mesh_type = 1
			mesh_data = Vector3(m.radius, 0.0, 0.0)
			seeds.append(create_seed(Vector3(0.0, 0.0, m.radius), Vector3(
				-1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector2.ZERO))
			seeds.append(create_seed(Vector3(0.0, 0.0, -m.radius),
						 Vector3(1.0, 0.0, 0.0), Vector3(0.0, 1.0, 0.0), Vector2.ZERO))
			graph.insert_edge(0, 1)
			graph.insert_edge(1, 0)
		elif m is BoxMesh:
			mesh_type = 2
			mesh_data = Vector3(m.size.x, m.size.y, m.size.z) * 0.5
			## two seeds in the diagonal corners
			#seeds.append(create_seed(Vector3(-mesh_data.x * 0.75, mesh_data.y, -mesh_data.z * 0.75),
						 #Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector2.ZERO))
			#seeds.append(create_seed(Vector3(mesh_data.x * 0.75, mesh_data.y, mesh_data.z * 0.75),
						 #Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2.ZERO))
			
			
			
			## triple seed:
			seeds.append(create_seed(Vector3(-mesh_data.x * 0.75, mesh_data.y, -mesh_data.z * 0.75),
						 Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector2.ZERO))
			seeds.append(create_seed(Vector3(-mesh_data.x * 0.75, mesh_data.y, mesh_data.z * 0.75),
						 Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2.ZERO))
			seeds.append(create_seed(Vector3(mesh_data.x * 0.75, mesh_data.y, 0.0),
						 Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2.ZERO))
						
			
			# On a plane, merge all the seeds
			graph.insert_edge(0, 1)
			graph.insert_edge(1, 2)
			graph.insert_edge(2, 0)
			## two seeds in the middle
			#seeds.append(create_seed(Vector3(-mesh_data.x * 0.95, mesh_data.y, 0.0),
						 #Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector2.ZERO))
			#seeds.append(create_seed(Vector3(mesh_data.x * 0.95, mesh_data.y, 0.0),
						 #Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2.ZERO))
			
			## testing with a slightly rotated basis: (it should optimize the frames to rotate it back)
			#seeds.append(create_seed(Vector3(mesh_data.x * 0.75, mesh_data.y, mesh_data.z * 0.75),
						 #Vector3(0.262, 0.0, 0.201).normalized(), Vector3(-0.201, 0.0, 0.262).normalized(), Vector2.ZERO))
		elif m is CylinderMesh:
			mesh_type = 3
			mesh_data = Vector3(m.top_radius, m.bottom_radius, m.height * 0.5)
			var middle_radius = (m.top_radius + m.bottom_radius) / 2.0

			const seeds_on_cyl := 3
			for i in range(seeds_on_cyl):
				var angle := i * (2.0 * PI / seeds_on_cyl)
				var pos_x: float = middle_radius * sin(angle)
				var pos_z: float = middle_radius * cos(angle)
				var tangent_x = cos(angle)
				var tangent_z = -sin(angle)
				seeds.append(create_seed(Vector3(pos_x, 0.0, pos_z), Vector3(
					tangent_x, 0.0, tangent_z), Vector3(0.0, 1.0, 0.0), Vector2.ZERO))
				
				# Merge: A -> B, B -> C (but not C -> A as that'd be a cycle)
				graph.insert_edge(0, 1)
				graph.insert_edge(1, 2)
		
		elif m is TorusMesh:
			mesh_type = 4
			mesh_data = Vector3(m.outer_radius, m.inner_radius, 0.0)
			var major_radius: float = (m.outer_radius + m.inner_radius) / 2.0
			var minor_radius:  float = abs(m.inner_radius - m.outer_radius) / 2.0
			seeds.append(create_seed(Vector3(0.0, minor_radius, major_radius), Vector3(
				1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2.ZERO))
			#seeds.append(create_seed(Vector3(0.0, -minor_radius, -major_radius),
						 #Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2.ZERO))
			seeds.append(create_seed(Vector3(0.0, minor_radius, -major_radius),
						 Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector2.ZERO))
			
			graph.insert_edge(0, 1)
			graph.insert_edge(1, 0)

		assert (seeds.size() <= NUM_SEEDS_PER_OBJ)
		
		
		# Transform the seeds from object-local to world space using the nodes transform
		for i in range(seeds.size()):
			var t: Transform3D = seeds[i]
			# transform the local space position into global space using the objects transform
			# directions are transformed using only the basis, so transform origins dont affect them
			seeds[i] = create_seed(trans * t.basis.x, trans.basis * t.basis.y, trans.basis *
								   t.basis.z, Vector2(t.origin.x, t.origin.y), bool(t.origin.z))


		# fill seeds with inactive seeds (in case we didnt use up 
		# all NUM_SEEDS_PER_OBJ for that object)
		for i in range(NUM_SEEDS_PER_OBJ - seeds.size()):
			seeds.append(create_seed(Vector3.ZERO, Vector3.ZERO,
						 Vector3.ZERO, Vector2.ZERO, false))

		var data := Transform3D(Vector3(float(mesh_type), float(sdf_mode), blending_factor), mesh_data, Vector3.ZERO, Vector3.ZERO)
		new_scene_data[num_objects * NUM_MATRICES_PER_OBJ] = inverse_transform
		new_scene_data[num_objects * NUM_MATRICES_PER_OBJ + 1] = data

		for i in range(NUM_SEEDS_PER_OBJ):
			new_seed_data[num_objects * NUM_SEEDS_PER_OBJ + i] = seeds[i]

		num_objects += 1

	# Connect each seed with every other seed on every other object
	if MERGE_ALL_SEEDS_BETWEEN_OBJECTS:
		for i in range(num_objects):
			for j in range(num_objects):
				if i == j:
					continue
				for s1 in range(NUM_SEEDS_PER_OBJ):
					var seed1_idx := i * NUM_SEEDS_PER_OBJ + s1
					if not bool(new_seed_data[seed1_idx].origin.z):
						continue
					for s2 in range(NUM_SEEDS_PER_OBJ):
						var seed2_idx := j * NUM_SEEDS_PER_OBJ + s2
						if not bool(new_seed_data[seed2_idx].origin.z):
							continue
						if PRINT_SEED_CONNECTIONS:
							log_info("Seed merge: ", seed1_idx, seed2_idx)
						graph.insert_edge(seed1_idx, seed2_idx)
						graph.insert_edge(seed2_idx, seed1_idx)
	
	# FIXME
	if $Scene/PlaneAndSphere.visible:
		graph.insert_edge(0, NUM_SEEDS_PER_OBJ + 1)
		graph.insert_edge(1, NUM_SEEDS_PER_OBJ + 1)
		graph.insert_edge(2, NUM_SEEDS_PER_OBJ + 1)

	return num_objects


func visualize_seeds(root_node: Node):
	if !root_node:
		return
	for node in root_node.get_children():
		var meshinst = node as SDFMesh
		if meshinst:
			for child in node.get_children():
				child.free()
	
	var idx := -1
	for node in root_node.get_children():
		var meshinst = node as SDFMesh
		if !meshinst and node.get_child_count() > 0 and node.is_visible_in_tree():
			visualize_seeds(node)
			continue
		
		if !VisualizeSeeds or !node.is_visible_in_tree():
			continue
		idx += 1
		
		var seed_idx := 0
		for i in range(idx * NUM_SEEDS_PER_OBJ, idx * NUM_SEEDS_PER_OBJ + NUM_SEEDS_PER_OBJ):
			var seed := seed_data[i]
			if not bool(seed.origin.z):
				seed_idx += 1
				continue
			var coords: Node3D = COORDINATE_SYSTEM.instantiate()
			node.add_child(coords)
			coords.owner = self
			coords.global_position = seed.basis.x
			var n := seed.basis.y.cross(seed.basis.z)
			
			coords.global_basis.x = seed.basis.y.normalized()
			coords.global_basis.y = n
			coords.global_basis.z = seed.basis.z.normalized()
			coords.get_node("Y").hide()
			var coords_scale := 0.33
			if meshinst.mesh is CylinderMesh:
				coords_scale = min((meshinst.mesh.top_radius + meshinst.mesh.bottom_radius) / 2.0, 0.33)
			coords.scale *= coords_scale
			coords.name = "CoordinateSystem " + str(seed_idx)
			seed_idx += 1
		


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


func create_seed(pos: Vector3, e1: Vector3, e2: Vector3, offset: Vector2, active: bool=true) -> Transform3D:
	return Transform3D(pos, e1, e2, Vector3(offset.x, offset.y, float(active)))


static func log_info(...args):
	if LogLvl >= LogLevel.LOG_INFO:
		printt.callv(args)

static func log_warn(...args):
	if LogLvl >= LogLevel.LOG_WARN:
		push_warning.callv(args)

static func log_error(...args):
	if LogLvl >= LogLevel.LOG_ERROR:
		push_error.callv(args)
