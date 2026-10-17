@tool
extends Node
class_name ImplicitUVsLink

@export var SeedA: ImplicitUVsSeed:
	set(v):
		if v != SeedA:
			SeedA = v
			update_configuration_warnings()
@export var SeedB: ImplicitUVsSeed:
	set(v):
		if v != SeedB:
			SeedB = v
			update_configuration_warnings()
@export_tool_button("Switch seeds (just visually)") var Switch := self.switch_seeds
@export var Enabled := true


func _get_configuration_warnings():
	var warnings = []
	if not is_instance_valid(SeedA) or not SeedA:
		warnings.append("Please select a valid node for SeedA!")
	if not is_instance_valid(SeedB) or not SeedB:
		warnings.append("Please select a valid node for SeedB!")
	if is_instance_valid(SeedA) and is_instance_valid(SeedB) and SeedA == SeedB:
		warnings.append("Please select two different nodes as seeds!")
	return warnings

func switch_seeds():
	var tmp := SeedA
	SeedA = SeedB
	SeedB = tmp
