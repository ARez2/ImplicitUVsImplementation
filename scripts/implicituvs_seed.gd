@tool
extends Marker3D
class_name ImplicitUVsSeed

const GIZMO_EXTENTS := 0.1

@export var MaxWalkDist := 4.0
@export var Enabled := true:
	set(v):
		if v != Enabled:
			Enabled = v
			gizmo_extents = GIZMO_EXTENTS if v else 0.0
## If this is > 0, this seed will try to stay aligned this way
@export_range(0.0, 99.0, 0.001) var TargetStrength := 0.0
@export_enum("e1 vector (red)", "e2 vector (blue)") var TargetDir := 0


func _enter_tree() -> void:
	gizmo_extents = GIZMO_EXTENTS
	self.visibility_changed.connect(self.vis_changed)

func vis_changed():
	if visible and Enabled:
		gizmo_extents = GIZMO_EXTENTS
	elif not Enabled:
		gizmo_extents = 0.0
