extends Node3D

const PLAYER_SCRIPT = preload("res://player.gd")
const PORT := 24560
const MAX_PLAYERS := 8
const ITEM_GAP_M := 0.65
const DUST_SELL_PRICE := 5
const COMPACTED_DUST_SELL_PRICE := 30
const SPACEPORT_FEE_RATE := 0.10
var players: Dictionary = {}
var status_label: Label
var money := 1000
var dust := 0
var compacted_dust := 0
var selected_building := ""
var machine_timer := 0.0
var extractor_timers: Dictionary = {}
var conveyor_items: Array[Dictionary] = []
var flow_events: Array[Dictionary] = []
var machine_upgrade_level := 0
var belt_upgrade_level := 0
var pressed_yield_remainder := 0.0
var balance_label: Label
var production_label: Label
var settings_panel: PanelContainer
var pause_overlay: ColorRect
var pause_panel: PanelContainer
var build_overlay: ColorRect
var build_panel: PanelContainer
var network_overlay: ColorRect
var building_overlay: ColorRect
var building_info: Label
var focused_building: Node3D
var upgrade_machine_button: Button
var upgrade_belt_button: Button
var dismantle_button: Button
var belt_stats_label: Label
var hud_status: Label
var remap_action := ""
var restoring_save := false
var build_preview: MeshInstance3D
var preview_valid := false
var preview_position := Vector3.ZERO
var preview_yaw := 0.0
var conveyor_start := Vector3.ZERO
var preview_endpoint := Vector3.ZERO
var conveyor_start_set := false
var preview_branch_source: Node3D
var conveyor_branch_source: Node3D
var conveyor_branch_anchor := Vector3.ZERO
var key_labels := {"move_forward": "W", "move_back": "S", "move_left": "A", "move_right": "D", "jump": "Space"}

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_inputs()
	_build_world()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_spawn_player(multiplayer.get_unique_id())
	_build_hud()
	_build_build_menu()
	_build_network_menu()
	_build_pause_menu()
	_build_building_ui()
	_update_economy_ui()

func _process(delta: float) -> void:
	if get_tree().paused:
		return
	_update_build_preview()
	_simulate_conveyor_factory(delta)
	machine_timer += delta
	if machine_timer >= 5.0:
		machine_timer = 0.0
		var now := Time.get_ticks_msec() / 1000.0
		var recent_events: Array[Dictionary] = []
		for event in flow_events:
			if now - float(event["time"]) <= 60.0:
				recent_events.append(event)
		flow_events = recent_events

func _setup_inputs() -> void:
	var bindings := {"move_forward": KEY_W, "move_back": KEY_S, "move_left": KEY_A, "move_right": KEY_D, "jump": KEY_SPACE}
	var config := ConfigFile.new()
	var config_status := config.load("user://settings.cfg")
	for action in bindings:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		var event := InputEventKey.new()
		event.physical_keycode = int(config.get_value("controls", action, bindings[action])) if config_status == OK else bindings[action]
		InputMap.action_add_event(action, event)

func _build_world() -> void:
	var world_env := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.19, 0.25, 0.39)
	sky_mat.sky_horizon_color = Color(0.78, 0.43, 0.29)
	sky_mat.ground_bottom_color = Color(0.15, 0.09, 0.08)
	sky_mat.ground_horizon_color = Color(0.60, 0.27, 0.17)
	sky.sky_material = sky_mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.53, 0.43)
	env.ambient_light_energy = 0.65
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -32, 0)
	sun.light_color = Color(1.0, 0.72, 0.52)
	sun.light_energy = 1.4
	add_child(sun)

	var floor_body := StaticBody3D.new()
	floor_body.name = "MarsGround"
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(300, 300)
	floor_mesh.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.46, 0.20, 0.12)
	ground_mat.roughness = 1.0
	floor_mesh.material_override = ground_mat
	floor_body.add_child(floor_mesh)
	var floor_shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(300, 1, 300)
	floor_shape.shape = box
	floor_shape.position.y = -0.5
	floor_body.add_child(floor_shape)
	add_child(floor_body)

	# Distant low mesas and scattered rocks make the first-person view feel grounded.
	for i in range(32):
		var rock := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = randf_range(0.5, 2.4)
		mesh.height = mesh.radius * 1.4
		rock.mesh = mesh
		rock.position = Vector3(randf_range(-75, 75), mesh.radius * 0.45 - 0.1, randf_range(-75, 75))
		rock.scale = Vector3(randf_range(1.0, 2.8), randf_range(0.45, 1.0), randf_range(0.8, 2.2))
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.31 + randf() * 0.15, 0.12 + randf() * 0.07, 0.08)
		mat.roughness = 1.0
		rock.material_override = mat
		add_child(rock)

	# Distant volcanic peaks frame the playable area.
	for i in range(12):
		var angle := TAU * float(i) / 12.0
		var height := randf_range(26.0, 46.0)
		var peak := MeshInstance3D.new()
		var peak_mesh := CylinderMesh.new()
		peak_mesh.top_radius = randf_range(1.0, 3.0)
		peak_mesh.bottom_radius = randf_range(14.0, 24.0)
		peak_mesh.height = height
		peak_mesh.radial_segments = 7
		peak.mesh = peak_mesh
		peak.position = Vector3(cos(angle) * 85.0, height * 0.45, sin(angle) * 85.0)
		var peak_mat := StandardMaterial3D.new()
		peak_mat.albedo_color = Color(0.30, 0.12, 0.10)
		peak_mat.roughness = 1.0
		peak.material_override = peak_mat
		add_child(peak)

	_build_spaceport()

func _build_spaceport() -> void:
	var station := StaticBody3D.new()
	station.name = "Spaceport"
	station.position = Vector3(0, 0, -16)
	station.add_to_group("sell_stations")
	station.set_meta("building_kind", "Spaceport")
	var shell := MeshInstance3D.new()
	var shell_mesh := BoxMesh.new()
	shell_mesh.size = Vector3(7, 3, 5)
	shell.mesh = shell_mesh
	shell.position.y = 1.5
	var shell_material := StandardMaterial3D.new()
	shell_material.albedo_color = Color(0.55, 0.58, 0.60)
	shell_material.metallic = 0.45
	shell_material.roughness = 0.42
	shell.material_override = shell_material
	station.add_child(shell)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(7, 3, 5)
	collision.shape = shape
	collision.position.y = 1.5
	station.add_child(collision)
	for x in [-4.5, 4.5]:
		var tower := MeshInstance3D.new()
		var tower_mesh := BoxMesh.new()
		tower_mesh.size = Vector3(2, 2, 2)
		tower.mesh = tower_mesh
		tower.position = Vector3(x, 1, 0)
		var tower_material := StandardMaterial3D.new()
		tower_material.albedo_color = Color(0.37, 0.52, 0.58)
		tower_material.metallic = 0.55
		tower.material_override = tower_material
		station.add_child(tower)
	var sign := MeshInstance3D.new()
	var sign_mesh := BoxMesh.new()
	sign_mesh.size = Vector3(3.2, 0.4, 2.5)
	sign.mesh = sign_mesh
	sign.position = Vector3(0, 3.3, 0)
	var sign_material := StandardMaterial3D.new()
	sign_material.albedo_color = Color(0.18, 0.48, 0.65)
	sign_material.emission_enabled = true
	sign_material.emission = Color(0.04, 0.18, 0.28)
	sign.material_override = sign_material
	station.add_child(sign)
	# A brightly marked dock sits on the outpost's front side (+Z).
	_add_machine_box(station, Vector3(0, 0.05, 3.55), Vector3(2.1, 0.10, 1.0), Color(0.18, 0.84, 0.76))
	_add_machine_box(station, Vector3(-0.78, 0.20, 3.55), Vector3(0.10, 0.28, 1.0), Color(0.94, 0.67, 0.20))
	_add_machine_box(station, Vector3(0.78, 0.20, 3.55), Vector3(0.10, 0.28, 1.0), Color(0.94, 0.67, 0.20))
	add_child(station)

func _add_box(pos: Vector3, size: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.position = pos
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = size
	mesh_instance.mesh = box_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.metallic = 0.22
	mat.roughness = 0.45
	mesh_instance.material_override = mat
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	add_child(body)

func _build_player() -> void:
	_build_network_menu()

func add_conveyor(pos: Vector3, yaw: float, segment_length: float = 2.4, free_of_charge: bool = false) -> Node3D:
	if not free_of_charge and money < 10:
		_update_status("Nicht genug Geld fuer ein Foerderband (10 cr).")
		return null
	if not free_of_charge:
		money -= 10
	var belt := StaticBody3D.new()
	belt.name = "ConveyorSegment"
	belt.add_to_group("buildable")
	belt.add_to_group("conveyor_segments")
	belt.set_meta("building_kind", "Foerderband")
	belt.position = Vector3(pos.x, 0.15, pos.z)
	belt.rotation.y = yaw
	belt.set_meta("direction", Vector3(0, 0, -1).rotated(Vector3.UP, yaw))
	belt.set_meta("length", segment_length)
	var base := MeshInstance3D.new()
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(1.0, 0.16, segment_length)
	base.mesh = base_mesh
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.17, 0.23, 0.27)
	steel.metallic = 0.72
	base.material_override = steel
	belt.add_child(base)
	var belt_surface := MeshInstance3D.new()
	var surface_mesh := BoxMesh.new()
	surface_mesh.size = Vector3(0.78, 0.045, segment_length * 0.94)
	belt_surface.mesh = surface_mesh
	belt_surface.position.y = 0.105
	var rubber := StandardMaterial3D.new()
	rubber.albedo_color = Color(0.055, 0.075, 0.08)
	rubber.roughness = 0.92
	belt_surface.material_override = rubber
	belt.add_child(belt_surface)
	for x in [-0.48, 0.48]:
		var rail := MeshInstance3D.new()
		var rail_mesh := BoxMesh.new()
		rail_mesh.size = Vector3(0.08, 0.28, segment_length)
		rail.mesh = rail_mesh
		rail.position = Vector3(x, 0.12, 0)
		rail.material_override = steel
		belt.add_child(rail)
	for z in [-segment_length * 0.34, 0.0, segment_length * 0.34]:
		var roller := MeshInstance3D.new()
		var roller_mesh := CylinderMesh.new()
		roller_mesh.top_radius = 0.09
		roller_mesh.bottom_radius = 0.09
		roller_mesh.height = 0.92
		roller.mesh = roller_mesh
		roller.rotation.z = deg_to_rad(90)
		roller.position = Vector3(0, 0.12, z)
		roller.material_override = steel
		belt.add_child(roller)
	for z in [-segment_length * 0.32, segment_length * 0.32]:
		for x in [-0.36, 0.36]:
			var support := MeshInstance3D.new()
			var support_mesh := BoxMesh.new()
			support_mesh.size = Vector3(0.10, 0.30, 0.10)
			support.mesh = support_mesh
			support.position = Vector3(x, -0.22, z)
			support.material_override = steel
			belt.add_child(support)
	var collision := CollisionShape3D.new()
	var belt_shape := BoxShape3D.new()
	belt_shape.size = Vector3(1.0, 0.16, segment_length)
	collision.shape = belt_shape
	belt.add_child(collision)
	add_child(belt)
	_update_economy_ui()
	return belt

func _split_belt_for_branch(belt: Node3D, anchor: Vector3, branch_direction: Vector3) -> Node3D:
	var direction := (belt.get_meta("direction") as Vector3).normalized()
	var old_entry := _belt_entry(belt)
	var old_length := float(belt.get_meta("length"))
	var split_distance := clampf((anchor - old_entry).dot(direction), 0.45, old_length - 0.45)
	var input_length := split_distance
	var straight_length := old_length - split_distance
	var yaw := atan2(-direction.x, -direction.z)
	var input_belt := add_conveyor(old_entry + direction * (input_length * 0.5), yaw, input_length, true)
	var straight_belt := add_conveyor(anchor + direction * (straight_length * 0.5), yaw, straight_length, true)
	if input_belt == null or straight_belt == null:
		if is_instance_valid(input_belt):
			input_belt.queue_free()
		if is_instance_valid(straight_belt):
			straight_belt.queue_free()
		return null
	for index in range(conveyor_items.size()):
		var item: Dictionary = conveyor_items[index]
		if item.get("belt") != belt:
			continue
		var old_progress := float(item.get("progress", 0.0))
		var distance := old_progress * old_length
		if distance <= split_distance:
			item["belt"] = input_belt
			item["progress"] = distance / input_length
		else:
			item["belt"] = straight_belt
			item["progress"] = (distance - split_distance) / straight_length
		conveyor_items[index] = item
	var splitter := _create_splitter_visual(anchor, yaw, branch_direction)
	splitter.set_meta("input_belt", input_belt)
	splitter.set_meta("straight_belt", straight_belt)
	splitter.set_meta("output_belts", [straight_belt])
	belt.queue_free()
	return splitter

func _create_splitter_visual(anchor: Vector3, yaw: float, branch_direction: Vector3) -> Node3D:
	var splitter := Node3D.new()
	splitter.name = "AutoSplitter"
	splitter.position = Vector3(anchor.x, 0.15, anchor.z)
	splitter.rotation.y = yaw
	splitter.add_to_group("splitter_visuals")
	splitter.set_meta("next_output", 0)
	var dark := Color(0.08, 0.13, 0.16)
	var steel := Color(0.42, 0.54, 0.58)
	var amber := Color(0.95, 0.60, 0.16)
	_add_machine_box(splitter, Vector3(0, -0.02, 0), Vector3(1.45, 0.18, 1.45), dark)
	_add_machine_box(splitter, Vector3(0, 0.10, 0), Vector3(0.92, 0.16, 2.35), steel)
	_add_machine_cylinder(splitter, Vector3(0, 0.20, 0), 0.48, 0.28, Color(0.16, 0.30, 0.34))
	_add_machine_cylinder(splitter, Vector3(0, 0.37, 0), 0.31, 0.12, amber)
	var local_side := Vector3(1, 0, 0).rotated(Vector3.UP, yaw)
	var side_sign := 1.0 if branch_direction.dot(local_side) >= 0.0 else -1.0
	_add_machine_box(splitter, Vector3(side_sign * 0.75, 0.09, 0), Vector3(1.55, 0.14, 0.82), steel)
	for x in [-0.60, 0.60]:
		_add_machine_box(splitter, Vector3(x, 0.21, 0), Vector3(0.10, 0.08, 2.15), amber)
	_add_machine_box(splitter, Vector3(side_sign * 1.25, 0.21, 0), Vector3(0.08, 0.08, 0.62), amber)
	add_child(splitter)
	return splitter

func _find_splitter_for_input(belt: Node3D, exit_point: Vector3) -> Node3D:
	for node in get_tree().get_nodes_in_group("splitter_visuals"):
		var splitter := node as Node3D
		if splitter.get_meta("input_belt", null) == belt and splitter.global_position.distance_to(exit_point) < 0.6:
			return splitter
	return null

func _choose_splitter_output(splitter: Node3D) -> Node3D:
	var outputs: Array = splitter.get_meta("output_belts", [])
	if outputs.is_empty():
		return null
	var next_index := int(splitter.get_meta("next_output", 0)) % outputs.size()
	for offset in range(outputs.size()):
		var index := (next_index + offset) % outputs.size()
		var belt := outputs[index] as Node3D
		if is_instance_valid(belt) and _belt_has_space(belt, 0.0):
			splitter.set_meta("next_output", (index + 1) % outputs.size())
			return belt
	return null

func _belt_entry(belt: Node3D) -> Vector3:
	return belt.global_position - (belt.get_meta("direction") as Vector3) * float(belt.get_meta("length")) * 0.5

func _belt_exit(belt: Node3D) -> Vector3:
	return belt.global_position + (belt.get_meta("direction") as Vector3) * float(belt.get_meta("length")) * 0.5

func _extractor_outlet(extractor: Node3D) -> Vector3:
	return extractor.global_position + Vector3(0, -0.70, -1.0)

func _press_intake(press: Node3D) -> Vector3:
	return press.global_position + Vector3(0, -0.72, 1.25)

func _press_outlet(press: Node3D) -> Vector3:
	return press.global_position + Vector3(0, -0.72, -1.25)

func _spaceport_intake(station: Node3D) -> Vector3:
	return station.global_position + Vector3(0, 0.15, 4.25)

func _snap_conveyor_point(raw_point: Vector3, is_start: bool) -> Vector3:
	var candidates: Array[Vector3] = []
	for node in get_tree().get_nodes_in_group("conveyor_segments"):
		var belt := node as Node3D
		candidates.append(_belt_exit(belt) if is_start else _belt_entry(belt))
	if is_start:
		for node in get_tree().get_nodes_in_group("dust_extractors"):
			candidates.append(_extractor_outlet(node))
		for node in get_tree().get_nodes_in_group("dust_presses"):
			candidates.append(_press_outlet(node))
	else:
		for node in get_tree().get_nodes_in_group("dust_presses"):
			candidates.append(_press_intake(node))
		for node in get_tree().get_nodes_in_group("sell_stations"):
			candidates.append(_spaceport_intake(node))
	var best := Vector3(round(raw_point.x), 0.0, round(raw_point.z))
	var best_distance := 2.6
	for candidate in candidates:
		var distance := Vector2(candidate.x - raw_point.x, candidate.z - raw_point.z).length()
		if distance < best_distance:
			best = Vector3(candidate.x, 0.0, candidate.z)
			best_distance = distance
	return best

func _find_branch_attachment(raw_point: Vector3) -> Dictionary:
	var best_belt: Node3D = null
	var best_anchor := Vector3.ZERO
	var best_distance := 0.65
	for node in get_tree().get_nodes_in_group("conveyor_segments"):
		var belt := node as Node3D
		var direction := (belt.get_meta("direction") as Vector3).normalized()
		var entry := _belt_entry(belt)
		var length := float(belt.get_meta("length"))
		if length <= 0.9:
			continue
		var along := clampf((raw_point - entry).dot(direction), 0.45, length - 0.45)
		var anchor := entry + direction * along
		var distance := Vector2(raw_point.x - anchor.x, raw_point.z - anchor.z).length()
		if distance < best_distance:
			best_distance = distance
			best_belt = belt
			best_anchor = anchor
	if best_belt == null:
		return {}
	best_anchor.y = 0.15
	return {"belt": best_belt, "anchor": best_anchor}

func _branch_endpoint(raw_point: Vector3) -> Vector3:
	var base_direction := (conveyor_branch_source.get_meta("direction") as Vector3).normalized()
	base_direction.y = 0.0
	var side_a := base_direction.rotated(Vector3.UP, PI * 0.5).normalized()
	var side_b := -side_a
	var offset := raw_point - conveyor_branch_anchor
	offset.y = 0.0
	var direction := side_a if offset.dot(side_a) >= offset.dot(side_b) else side_b
	var length := maxf(2.4, absf(offset.dot(direction)))
	return conveyor_branch_anchor + direction * length

func _is_allowed_conveyor_overlap(collider: Object, start: Vector3, finish: Vector3) -> bool:
	if not collider is Node:
		return false
	var node := collider as Node
	if node.is_in_group("conveyor_segments"):
		return true
	if node.is_in_group("dust_extractors"):
		return Vector2(node.global_position.x - start.x, node.global_position.z - start.z).length() < 2.8
	if node.is_in_group("dust_presses"):
		return Vector2(node.global_position.x - finish.x, node.global_position.z - finish.z).length() < 2.8
	if node.is_in_group("sell_stations"):
		return Vector2(_spaceport_intake(node).x - finish.x, _spaceport_intake(node).z - finish.z).length() < 2.8
	return false

func _find_belt_at_entry(point: Vector3, excluded: Node = null) -> Node3D:
	var closest: Node3D = null
	var best_distance := 2.0
	for node in get_tree().get_nodes_in_group("conveyor_segments"):
		if node == excluded or not is_instance_valid(node):
			continue
		var belt := node as Node3D
		var distance := _belt_entry(belt).distance_to(point)
		if distance < best_distance:
			best_distance = distance
			closest = belt
	return closest

func _find_belt_exiting_at(point: Vector3, excluded: Node = null) -> Node3D:
	var closest: Node3D = null
	var best_distance := 2.0
	for node in get_tree().get_nodes_in_group("conveyor_segments"):
		if node == excluded:
			continue
		var belt := node as Node3D
		var distance := _belt_exit(belt).distance_to(point)
		if distance < best_distance:
			best_distance = distance
			closest = belt
	return closest

func _spawn_dust_item(belt: Node3D, extractor: Node3D) -> void:
	var item := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.17
	mesh.height = 0.30
	item.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.88, 0.49, 0.22)
	material.roughness = 0.85
	item.material_override = material
	add_child(item)
	var entry := _belt_entry(belt)
	item.global_position = entry + Vector3(0, 0.36, 0)
	conveyor_items.append({"visual": item, "belt": belt, "progress": 0.0, "item_type": "dust"})
	flow_events.append({"time": Time.get_ticks_msec() / 1000.0, "building": extractor.get_instance_id()})
	dust += 1
	_update_economy_ui()

func _spawn_compacted_item(belt: Node3D) -> void:
	if not _belt_has_space(belt, 0.0):
		return
	var item := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.30, 0.24, 0.30)
	item.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.34, 0.72, 0.77)
	material.metallic = 0.30
	material.roughness = 0.65
	item.material_override = material
	add_child(item)
	item.global_position = _belt_entry(belt) + Vector3(0, 0.36, 0)
	conveyor_items.append({"visual": item, "belt": belt, "progress": 0.0, "item_type": "compacted_dust"})

func _belt_has_space(belt: Node3D, at_progress: float) -> bool:
	if not is_instance_valid(belt):
		return false
	var length := float(belt.get_meta("length"))
	for item in conveyor_items:
		if item.get("belt") == belt and absf(float(item.get("progress", 0.0)) - at_progress) * length < ITEM_GAP_M:
			return false
	return true

func _limit_belt_progress(belt: Node3D, item_index: int, candidate: float) -> float:
	var length := float(belt.get_meta("length"))
	var current := float(conveyor_items[item_index].get("progress", 0.0))
	var allowed := candidate
	for other_index in range(conveyor_items.size()):
		if other_index == item_index:
			continue
		var other: Dictionary = conveyor_items[other_index]
		if other.get("belt") == belt:
			var other_progress := float(other.get("progress", 0.0))
			if other_progress > current:
				allowed = minf(allowed, other_progress - ITEM_GAP_M / length)
	return maxf(current, allowed)

func _find_press_at(point: Vector3) -> Node3D:
	for node in get_tree().get_nodes_in_group("dust_presses"):
		var press := node as Node3D
		var intake := press.global_position + Vector3(0, -0.72, 1.25)
		if intake.distance_to(point) <= 2.2:
			return press
	return null

func _remove_conveyor_item(index: int) -> void:
	var visual = conveyor_items[index].get("visual")
	if is_instance_valid(visual):
		visual.queue_free()
	conveyor_items.remove_at(index)

func _simulate_conveyor_factory(delta: float) -> void:
	for extractor in get_tree().get_nodes_in_group("dust_extractors"):
		var instance_id := extractor.get_instance_id()
		var remaining := float(extractor_timers.get(instance_id, 1.0)) - delta
		if remaining <= 0.0:
			var outlet: Vector3 = extractor.global_position + Vector3(0, -0.70, -1.0)
			var belt := _find_belt_at_entry(outlet)
			if belt != null and conveyor_items.size() < 40 and _belt_has_space(belt, 0.0):
				_spawn_dust_item(belt, extractor)
				remaining = 2.0 / (1.0 + 0.5 * float(machine_upgrade_level))
			else:
				remaining = 0.25
		extractor_timers[instance_id] = remaining
	_flush_press_outputs()
	for index in range(conveyor_items.size() - 1, -1, -1):
		var item: Dictionary = conveyor_items[index]
		var belt = item.get("belt")
		if not is_instance_valid(belt):
			_remove_conveyor_item(index)
			continue
		var belt_length := float(belt.get_meta("length"))
		var progress := float(item.get("progress", 0.0)) + delta * _current_belt_speed() / belt_length
		if progress >= 1.0:
			var exit_point := _belt_exit(belt)
			var splitter := _find_splitter_for_input(belt, exit_point)
			var next_belt := _choose_splitter_output(splitter) if splitter != null else _find_belt_at_entry(exit_point, belt)
			if next_belt != null and _belt_has_space(next_belt, 0.0):
				item["belt"] = next_belt
				progress = 0.0
			else:
				var receiving_station := _find_sell_station_at(exit_point)
				if receiving_station != null:
					_sell_conveyor_item(index, item)
					continue
				var receiving_press := _find_press_at(exit_point) if str(item.get("item_type", "dust")) == "dust" else null
				if receiving_press != null:
					flow_events.append({"time": Time.get_ticks_msec() / 1000.0, "building": receiving_press.get_instance_id()})
					pressed_yield_remainder += 1.0 + 0.5 * float(machine_upgrade_level)
					var produced := int(floor(pressed_yield_remainder))
					pressed_yield_remainder -= float(produced)
					compacted_dust += produced
					dust = maxi(0, dust - 1)
					_remove_conveyor_item(index)
					_update_economy_ui()
					continue
				progress = 1.0
		progress = _limit_belt_progress(item["belt"], index, progress)
		item["progress"] = progress
		conveyor_items[index] = item
		var entry := _belt_entry(item["belt"])
		var exit := _belt_exit(item["belt"])
		(item["visual"] as Node3D).global_position = entry.lerp(exit, progress) + Vector3(0, 0.36, 0)
	_flush_press_outputs()

func _flush_press_outputs() -> void:
	for press in get_tree().get_nodes_in_group("dust_presses"):
		var belt := _find_belt_at_entry(_press_outlet(press))
		while compacted_dust > 0 and belt != null and conveyor_items.size() < 40 and _belt_has_space(belt, 0.0):
			compacted_dust -= 1
			_spawn_compacted_item(belt)
	_update_economy_ui()

func _find_sell_station_at(point: Vector3) -> Node3D:
	for node in get_tree().get_nodes_in_group("sell_stations"):
		var station := node as Node3D
		if _spaceport_intake(station).distance_to(point) <= 2.2:
			return station
	return null

func _sell_conveyor_item(index: int, item: Dictionary) -> void:
	var item_type := str(item.get("item_type", "dust"))
	var gross_price := COMPACTED_DUST_SELL_PRICE if item_type == "compacted_dust" else DUST_SELL_PRICE
	var net_price := gross_price - int(round(float(gross_price) * SPACEPORT_FEE_RATE))
	if item_type == "dust":
		dust = maxi(0, dust - 1)
	money += net_price
	_remove_conveyor_item(index)
	_update_economy_ui()
	_update_status("Spaceport sold %s for %d cr after 10%% service fee." % ["compacted dust" if item_type == "compacted_dust" else "dust", net_price])

func place_building(kind: String, pos: Vector3) -> void:
	var cost := 150 if kind.begins_with("Staubf") else (250 if kind == "Staubpresse" else 500)
	if not restoring_save and money < cost:
		_update_status("Nicht genug Geld für %s. Benötigt: %d cr." % [kind, cost])
		return
	if not restoring_save:
		money -= cost
	var body := StaticBody3D.new()
	body.name = kind
	body.add_to_group("buildable")
	body.set_meta("building_kind", kind)
	body.position = Vector3(round(pos.x / 2.0) * 2.0, 1.0, round(pos.z / 2.0) * 2.0)
	_build_machine_model(body, kind)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(2.0, 2.0, 2.0)
	collision.shape = box
	body.add_child(collision)
	if kind.begins_with("Staubf"):
		body.add_to_group("dust_extractors")
	elif kind == "Staubpresse":
		body.add_to_group("dust_presses")
	else:
		body.add_to_group("upgrade_stations")
	add_child(body)
	selected_building = ""
	_update_economy_ui()

func _build_machine_model(parent: Node3D, kind: String) -> void:
	var extractor := kind == "Staubfoerderer"
	var upgrade_station := kind == "UpgradeStation"
	var shell_color := Color(0.72, 0.29, 0.12) if extractor else (Color(0.35, 0.25, 0.58) if upgrade_station else Color(0.24, 0.37, 0.43))
	var steel := Color(0.46, 0.58, 0.62)
	var dark := Color(0.10, 0.15, 0.18)
	_add_machine_box(parent, Vector3(0, -0.78, 0), Vector3(2.15, 0.30, 2.15), dark)
	_add_machine_box(parent, Vector3(0, 0, 0), Vector3(1.70, 1.38, 1.55), shell_color)
	_add_machine_box(parent, Vector3(0, 0.72, 0), Vector3(1.92, 0.16, 1.78), steel)
	for x in [-0.82, 0.82]:
		for z in [-0.72, 0.72]:
			_add_machine_box(parent, Vector3(x, -0.12, z), Vector3(0.12, 1.36, 0.12), dark)
	var lamp_material := StandardMaterial3D.new()
	lamp_material.albedo_color = Color(0.20, 0.93, 0.75)
	lamp_material.emission_enabled = true
	lamp_material.emission = Color(0.04, 0.42, 0.28)
	_add_machine_box(parent, Vector3(0.55, 0.28, -0.79), Vector3(0.25, 0.14, 0.05), Color.WHITE, lamp_material)
	if extractor:
		_add_machine_box(parent, Vector3(0, 0.94, 0), Vector3(1.25, 0.22, 1.15), Color(0.38, 0.21, 0.13))
		_add_machine_cylinder(parent, Vector3(0, 1.25, 0), 0.50, 0.42, shell_color)
		_add_machine_box(parent, Vector3(0, -0.55, -0.35), Vector3(1.25, 0.24, 0.22), steel)
		for x in [-0.42, 0.42]:
			_add_machine_cylinder(parent, Vector3(x, -0.69, 0.62), 0.16, 0.42, steel)
	elif upgrade_station:
		_add_machine_box(parent, Vector3(0, 0.86, 0), Vector3(1.36, 0.42, 0.16), Color(0.13, 0.79, 0.91))
		_add_machine_cylinder(parent, Vector3(0, 1.20, 0), 0.14, 0.48, steel)
		_add_machine_box(parent, Vector3(0, 0.10, 0.87), Vector3(1.12, 0.72, 0.10), Color(0.08, 0.13, 0.18))
		_add_machine_box(parent, Vector3(0, 0.10, 0.94), Vector3(0.82, 0.46, 0.035), Color(0.15, 0.85, 0.89), lamp_material)
	else:
		_add_machine_cylinder(parent, Vector3(0, 1.04, 0), 0.30, 0.62, steel)
		_add_machine_box(parent, Vector3(0, 0.72, 0), Vector3(1.28, 0.14, 1.15), shell_color)
		_add_machine_box(parent, Vector3(0, -0.36, -0.92), Vector3(0.92, 0.28, 0.62), dark)
		_add_machine_box(parent, Vector3(0, -0.55, -1.12), Vector3(0.74, 0.12, 0.30), Color(0.93, 0.58, 0.17))
		_add_machine_box(parent, Vector3(0, -0.34, 1.00), Vector3(0.72, 0.34, 0.10), Color(0.77, 0.34, 0.14))
		_add_port_label(parent, "IN", Vector3(0, -0.34, 1.06), Color(1.0, 0.79, 0.53), true)
		_add_machine_box(parent, Vector3(0, -0.34, -1.00), Vector3(0.72, 0.34, 0.10), Color(0.09, 0.43, 0.49))
		_add_port_label(parent, "OUT", Vector3(0, -0.34, -1.06), Color(0.65, 0.98, 0.94), false)
	for i in range(4):
		_add_machine_box(parent, Vector3(-0.60 + i * 0.4, -0.48, 0.797), Vector3(0.18, 0.07, 0.035), Color(0.96, 0.70, 0.19))

func _add_port_label(parent: Node3D, caption: String, pos: Vector3, color: Color, faces_positive_z: bool) -> void:
	var label := Label3D.new()
	label.text = caption
	label.position = pos
	label.rotation.y = PI if faces_positive_z else 0.0
	label.font_size = 64
	label.pixel_size = 0.0045
	label.modulate = color
	label.outline_size = 8
	label.outline_modulate = Color(0.025, 0.045, 0.055)
	parent.add_child(label)

func _add_machine_box(parent: Node3D, pos: Vector3, size: Vector3, color: Color, override_material: Material = null) -> void:
	var detail := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	detail.mesh = mesh
	detail.position = pos
	if override_material != null:
		detail.material_override = override_material
	else:
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.metallic = 0.48
		material.roughness = 0.38
		detail.material_override = material
	parent.add_child(detail)

func _add_machine_cylinder(parent: Node3D, pos: Vector3, radius: float, height: float, color: Color) -> void:
	var detail := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius * 1.12
	mesh.height = height
	mesh.radial_segments = 12
	detail.mesh = mesh
	detail.position = pos
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.metallic = 0.68
	material.roughness = 0.28
	detail.material_override = material
	parent.add_child(detail)
func mine_rock(rock: Node3D) -> void:
	if is_instance_valid(rock) and rock.name.begins_with("OreRock"):
		rock.queue_free()
		_update_status("Stein abgebaut. Rohstoffinventar folgt im nächsten Update.")

func _spawn_player(peer_id: int) -> void:
	if players.has(peer_id):
		return
	var player := CharacterBody3D.new()
	player.name = "Player_%s" % peer_id
	player.set_script(PLAYER_SCRIPT)
	player.position = Vector3(float(players.size() % 4) * 2.0, 1.05, 4.0 + float(players.size() / 4) * 2.0)
	player.set_multiplayer_authority(peer_id)
	add_child(player)
	players[peer_id] = player

func _on_peer_connected(peer_id: int) -> void:
	if multiplayer.is_server():
		_spawn_player(peer_id)
		for existing_id in players:
			if existing_id != peer_id:
				_spawn_player_remote.rpc_id(peer_id, int(existing_id))
		_spawn_player_remote.rpc(peer_id)

@rpc("authority", "call_local", "reliable")
func _spawn_player_remote(peer_id: int) -> void:
	_spawn_player(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	if players.has(peer_id):
		players[peer_id].queue_free()
		players.erase(peer_id)
	_update_status("Spieler %s hat die Sitzung verlassen." % peer_id)

func _on_connected_to_server() -> void:
	_update_status("Verbunden mit Host. Spieler-ID: %s" % multiplayer.get_unique_id())
	_spawn_player_remote.rpc_id(1, multiplayer.get_unique_id())

func _on_connection_failed() -> void:
	_update_status("Verbindung fehlgeschlagen. Prüfe IP und Firewall.")
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func _on_server_disconnected() -> void:
	_update_status("Verbindung zum Host getrennt.")
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func _host_game() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(PORT, MAX_PLAYERS - 1)
	if error != OK:
		_update_status("Host konnte nicht starten (Fehler %s)." % error)
		return
	multiplayer.multiplayer_peer = peer
	_update_status("Host aktiv auf Port %s. Deine ID: 1" % PORT)

func _join_game(address: String) -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client(address.strip_edges(), PORT)
	if error != OK:
		_update_status("Verbindung konnte nicht gestartet werden (Fehler %s)." % error)
		return
	multiplayer.multiplayer_peer = peer
	_update_status("Verbinde mit %s:%s …" % [address, PORT])

func _update_status(message: String) -> void:
	if is_instance_valid(status_label):
		status_label.text = message
	if is_instance_valid(hud_status):
		hud_status.text = message

func _build_network_menu() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 25
	add_child(layer)
	network_overlay = ColorRect.new()
	network_overlay.color = Color(0.015, 0.035, 0.055, 0.82)
	network_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	network_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	network_overlay.visible = false
	network_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	layer.add_child(network_overlay)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -240
	panel.offset_top = -185
	panel.offset_right = 240
	panel.offset_bottom = 185
	panel.add_theme_stylebox_override("panel", _menu_style(Color(0.045, 0.075, 0.105, 0.99), Color(0.25, 0.74, 0.82)))
	network_overlay.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)
	var heading := Label.new()
	heading.text = "MULTIPLAYER SESSION"
	heading.add_theme_font_size_override("font_size", 26)
	column.add_child(heading)
	var host_button := Button.new()
	host_button.text = "Host a session"
	host_button.pressed.connect(_host_game)
	column.add_child(host_button)
	var address := LineEdit.new()
	address.placeholder_text = "Host IP address"
	address.text = "127.0.0.1"
	column.add_child(address)
	var join_button := Button.new()
	join_button.text = "Join session"
	join_button.pressed.connect(func(): _join_game(address.text))
	column.add_child(join_button)
	status_label = Label.new()
	status_label.text = "Up to 8 players"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status_label)
	var back := Button.new()
	back.text = "Back to pause menu"
	back.pressed.connect(func(): network_overlay.visible = false; pause_overlay.visible = true)
	column.add_child(back)

func _open_network_menu() -> void:
	pause_overlay.visible = false
	network_overlay.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "UPDATE 9  /  DUST FACTORY"
	title.position = Vector2(24, 20)
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1.0, 0.78, 0.59))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(title)
	var hint := Label.new()
	hint.text = "WASD move  |  E use building  |  X dismantle  |  B build menu  |  ESC pause"
	hint.position = Vector2(24, 55)
	hint.add_theme_font_size_override("font_size", 15)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hint)
	balance_label = Label.new()
	balance_label.position = Vector2(24, 84)
	balance_label.add_theme_font_size_override("font_size", 18)
	balance_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(balance_label)
	production_label = Label.new()
	production_label.position = Vector2(24, 110)
	production_label.add_theme_font_size_override("font_size", 16)
	production_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(production_label)
	hud_status = Label.new()
	hud_status.position = Vector2(24, 142)
	hud_status.add_theme_font_size_override("font_size", 16)
	hud_status.add_theme_color_override("font_color", Color(0.55, 0.88, 0.90))
	hud_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud_status)
	var cross := Label.new()
	cross.text = "+"
	cross.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	cross.position = Vector2(-7, -15)
	cross.add_theme_font_size_override("font_size", 26)
	cross.add_theme_color_override("font_color", Color(1, 0.86, 0.7, 0.8))
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(cross)
	_build_settings(layer)

func _build_build_menu() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 15
	add_child(layer)
	build_overlay = ColorRect.new()
	build_overlay.color = Color(0.015, 0.035, 0.055, 0.78)
	build_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	build_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	build_overlay.visible = false
	layer.add_child(build_overlay)
	build_panel = PanelContainer.new()
	build_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	build_panel.offset_left = -270
	build_panel.offset_top = -235
	build_panel.offset_right = 270
	build_panel.offset_bottom = 235
	build_panel.add_theme_stylebox_override("panel", _menu_style(Color(0.045, 0.075, 0.105, 0.99), Color(0.25, 0.74, 0.82)))
	build_overlay.add_child(build_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 11)
	build_panel.add_child(column)
	var overline := Label.new()
	overline.text = "MARS INDUSTRIES  /  CONSTRUCTION"
	overline.add_theme_color_override("font_color", Color(0.39, 0.78, 0.83))
	column.add_child(overline)
	var heading := Label.new()
	heading.text = "Build menu"
	heading.add_theme_font_size_override("font_size", 30)
	heading.add_theme_color_override("font_color", Color(1.0, 0.89, 0.75))
	column.add_child(heading)
	var desc := Label.new()
	desc.text = "Choose a building, then click the ground to place it."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(desc)
	belt_stats_label = Label.new()
	belt_stats_label.text = "Conveyor speed: %.2f m/s  |  Auto-connect at snapped ends" % _current_belt_speed()
	belt_stats_label.add_theme_color_override("font_color", Color(0.58, 0.78, 0.80))
	column.add_child(belt_stats_label)
	_add_menu_button(column, "Dust extractor  |  150 cr", func(): _select_building("Staubfoerderer"), true)
	_add_menu_button(column, "Dust press  |  250 cr", func(): _select_building("Staubpresse"), false)
	_add_menu_button(column, "Upgrade station  |  500 cr", func(): _select_building("UpgradeStation"), false)
	_add_menu_button(column, "Conveyor  |  10 cr", func(): _select_building("Foerderband"), false)
	_add_menu_button(column, "Close  |  B / ESC", _close_build_menu, false)

func _build_building_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 40
	add_child(layer)
	building_overlay = ColorRect.new()
	building_overlay.color = Color(0.015, 0.035, 0.055, 0.80)
	building_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	building_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	building_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	building_overlay.visible = false
	layer.add_child(building_overlay)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.offset_left = -260
	panel.offset_top = -175
	panel.offset_right = 260
	panel.offset_bottom = 175
	panel.add_theme_stylebox_override("panel", _menu_style(Color(0.045, 0.075, 0.105, 0.99), Color(0.25, 0.74, 0.82)))
	building_overlay.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	panel.add_child(column)
	var overline := Label.new()
	overline.text = "MARS INDUSTRIES  /  BUILDING STATUS"
	overline.add_theme_color_override("font_color", Color(0.39, 0.78, 0.83))
	column.add_child(overline)
	var heading := Label.new()
	heading.text = "Building"
	heading.add_theme_font_size_override("font_size", 28)
	heading.add_theme_color_override("font_color", Color(1.0, 0.89, 0.75))
	column.add_child(heading)
	building_info = Label.new()
	building_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	building_info.custom_minimum_size = Vector2(440, 100)
	column.add_child(building_info)
	upgrade_machine_button = Button.new()
	upgrade_machine_button.custom_minimum_size = Vector2(0, 44)
	upgrade_machine_button.pressed.connect(_upgrade_machine_efficiency)
	upgrade_machine_button.visible = false
	column.add_child(upgrade_machine_button)
	upgrade_belt_button = Button.new()
	upgrade_belt_button.custom_minimum_size = Vector2(0, 44)
	upgrade_belt_button.pressed.connect(_upgrade_conveyor_speed)
	upgrade_belt_button.visible = false
	column.add_child(upgrade_belt_button)
	dismantle_button = Button.new()
	dismantle_button.custom_minimum_size = Vector2(0, 44)
	dismantle_button.pressed.connect(_dismantle_focused_building)
	column.add_child(dismantle_button)
	_add_menu_button(column, "Close  |  E / ESC", _close_building_ui, true)

func interact_with_aim(camera: Camera3D) -> void:
	var origin := camera.global_position
	var ray := PhysicsRayQueryParameters3D.create(origin, origin - camera.global_transform.basis.z * 5.0)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.has("collider"):
		return
	var target = hit["collider"]
	if target is Node and target.is_in_group("buildable"):
		_open_building_ui(target)
	elif target is Node and target.is_in_group("sell_stations"):
		_open_building_ui(target)
	elif target is Node3D and target.name.begins_with("OreRock"):
		mine_rock(target)

func dismantle_with_aim(camera: Camera3D) -> void:
	if get_tree().paused:
		return
	var origin := camera.global_position
	var ray := PhysicsRayQueryParameters3D.create(origin, origin - camera.global_transform.basis.z * 5.0)
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.has("collider"):
		var target = hit["collider"]
		if target is Node3D and target.is_in_group("buildable"):
			_dismantle_building(target)

func _dismantle_focused_building() -> void:
	if is_instance_valid(focused_building):
		_dismantle_building(focused_building)

func _dismantle_building(building: Node3D) -> void:
	if not is_instance_valid(building):
		return
	var kind := str(building.get_meta("building_kind", building.name))
	var refund := 5 if kind == "Foerderband" else (75 if kind == "Staubfoerderer" else (125 if kind == "Staubpresse" else 250))
	var building_id := building.get_instance_id()
	if kind == "Foerderband":
		for index in range(conveyor_items.size() - 1, -1, -1):
			if conveyor_items[index].get("belt") == building:
				_remove_conveyor_item(index)
	extractor_timers.erase(building_id)
	if focused_building == building:
		_close_building_ui()
	building.queue_free()
	money += refund
	_update_economy_ui()
	_update_status("Dismantled %s. Refund: %d cr." % [kind, refund])

func _open_building_ui(building: Node3D) -> void:
	focused_building = building
	var kind := str(building.get_meta("building_kind", building.name))
	var throughput := 0
	var now := Time.get_ticks_msec() / 1000.0
	for event in flow_events:
		if int(event["building"]) == building.get_instance_id() and now - float(event["time"]) <= 60.0:
			throughput += 1
	var info := ""
	if kind == "Staubfoerderer":
		var connected := _find_belt_at_entry(_extractor_outlet(building)) != null
		info = "Status: %s\nOutput: %d items/min (last 60 seconds)\nOutput belt: %s" % ["Running" if connected else "Waiting for conveyor", throughput, "Connected" if connected else "Not connected"]
	elif kind == "Staubpresse":
		var connected := false
		for belt in get_tree().get_nodes_in_group("conveyor_segments"):
			if _belt_exit(belt).distance_to(_press_intake(building)) < 2.6:
				connected = true
				break
		info = "Status: %s\nInput: %d items/min (last 60 seconds)\nBelt speed: %.2f m/s\nPressed dust: %d" % ["Processing" if connected else "Waiting for conveyor", throughput, _current_belt_speed(), compacted_dust]
	elif kind == "Foerderband":
		var connected_forward := _find_belt_at_entry(_belt_exit(building), building) != null
		var connected_from := _find_belt_exiting_at(_belt_entry(building), building) != null
		info = "Belt speed: %.2f m/s\nFlow: 2.4 m per segment\nConnected from previous belt: %s\nConnected to next belt: %s" % [_current_belt_speed(), "Yes" if connected_from else "No", "Yes" if connected_forward else "No"]
	elif kind == "Spaceport":
		info = "Cargo dock: connect a conveyor to the marked intake on the front (+Z).\nDust: %d cr each\nCompacted dust: %d cr each\nService fee: 10%%\nNet payout: dust %d cr  |  compacted dust %d cr\nItems are sold automatically when they reach the dock." % [DUST_SELL_PRICE, COMPACTED_DUST_SELL_PRICE, DUST_SELL_PRICE - int(round(DUST_SELL_PRICE * SPACEPORT_FEE_RATE)), COMPACTED_DUST_SELL_PRICE - int(round(COMPACTED_DUST_SELL_PRICE * SPACEPORT_FEE_RATE))]
	else:
		info = "Upgrade station\nMachine efficiency: level %d (%.1f items per dust)\nConveyor speed: %.2f m/s\nUpgrades affect all placed machines and belts." % [machine_upgrade_level, 1.0 + 0.5 * float(machine_upgrade_level), _current_belt_speed()]
	building_info.text = info
	var can_dismantle := kind != "Spaceport"
	if can_dismantle:
		building_info.text += "\nPress X to dismantle for a partial refund."
	dismantle_button.visible = can_dismantle
	var is_upgrade_station := kind == "UpgradeStation"
	upgrade_machine_button.visible = is_upgrade_station and machine_upgrade_level < 3
	upgrade_belt_button.visible = is_upgrade_station and belt_upgrade_level < 3
	if upgrade_machine_button.visible:
		upgrade_machine_button.text = "Machine efficiency +50%%  |  %d cr" % (250 * (machine_upgrade_level + 1))
	if upgrade_belt_button.visible:
		upgrade_belt_button.text = "Conveyor speed +35%%  |  %d cr" % (250 * (belt_upgrade_level + 1))
	if can_dismantle:
		dismantle_button.text = "Dismantle  |  X  |  Refund %d cr" % (5 if kind == "Foerderband" else (75 if kind == "Staubfoerderer" else (125 if kind == "Staubpresse" else 250)))
	building_overlay.visible = true
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _close_building_ui() -> void:
	building_overlay.visible = false
	focused_building = null
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _upgrade_machine_efficiency() -> void:
	var cost := 250 * (machine_upgrade_level + 1)
	if money < cost or machine_upgrade_level >= 3:
		_update_status("Not enough credits or maximum upgrade reached.")
		return
	money -= cost
	machine_upgrade_level += 1
	_update_economy_ui()
	_open_building_ui(focused_building)

func _upgrade_conveyor_speed() -> void:
	var cost := 250 * (belt_upgrade_level + 1)
	if money < cost or belt_upgrade_level >= 3:
		_update_status("Not enough credits or maximum upgrade reached.")
		return
	money -= cost
	belt_upgrade_level += 1
	_update_economy_ui()
	_open_building_ui(focused_building)

func _select_building(kind: String) -> void:
	selected_building = kind
	conveyor_start_set = false
	conveyor_branch_source = null
	preview_branch_source = null
	build_overlay.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_create_build_preview()
	if hud_status:
		if kind == "Foerderband":
			hud_status.text = "Conveyor selected - click a start point, drag aim, click again to finish."
		else:
			hud_status.text = "%s selected - click ground to place." % kind

func _close_build_menu() -> void:
	build_overlay.visible = false
	selected_building = ""
	conveyor_start_set = false
	conveyor_branch_source = null
	preview_branch_source = null
	_clear_build_preview()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func toggle_build_menu() -> void:
	if get_tree().paused or pause_overlay.visible:
		return
	build_overlay.visible = not build_overlay.visible
	selected_building = ""
	conveyor_start_set = false
	_clear_build_preview()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if build_overlay.visible else Input.MOUSE_MODE_CAPTURED
	if build_overlay.visible:
		build_panel.get_child(0).get_child(3).grab_focus()

func _create_build_preview() -> void:
	_clear_build_preview()
	build_preview = MeshInstance3D.new()
	if selected_building == "Foerderband":
		var belt_mesh := BoxMesh.new()
		belt_mesh.size = Vector3(1.0, 0.16, 2.4)
		build_preview.mesh = belt_mesh
		for x in [-0.48, 0.48]:
			var rail := MeshInstance3D.new()
			var rail_mesh := BoxMesh.new()
			rail_mesh.size = Vector3(0.08, 0.26, 2.4)
			rail.mesh = rail_mesh
			rail.position = Vector3(x, 0.10, 0)
			build_preview.add_child(rail)
	else:
		_build_machine_model(build_preview, selected_building)
	add_child(build_preview)
	_set_preview_tint(build_preview, Color(0.25, 1.0, 0.48, 0.42))
	build_preview.visible = false

func _set_preview_tint(node: Node, tint: Color) -> void:
	if node is MeshInstance3D:
		var ghost := StandardMaterial3D.new()
		ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		ghost.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ghost.albedo_color = tint
		node.material_override = ghost
	for child in node.get_children():
		_set_preview_tint(child, tint)

func copy_building_from_aim(camera: Camera3D) -> void:
	var origin := camera.global_position
	var direction := -camera.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 24.0)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.has("collider"):
		_update_status("Aim at a placed building to copy it.")
		return
	var target = hit["collider"]
	if target is Node and target.is_in_group("buildable"):
		var kind := str(target.get_meta("building_kind", ""))
		if kind != "":
			_select_building(kind)
			if hud_status:
				hud_status.text = "Copied %s - preview follows your aim." % kind
			return
	_update_status("Aim at a placed building to copy it.")

func _clear_build_preview() -> void:
	if is_instance_valid(build_preview):
		build_preview.queue_free()
	build_preview = null
	preview_valid = false

func _update_build_preview() -> void:
	if selected_building == "" or not is_instance_valid(build_preview):
		return
	var player = players.get(multiplayer.get_unique_id())
	if player == null or player.camera == null:
		build_preview.visible = false
		return
	var origin: Vector3 = player.camera.global_position
	var end: Vector3 = origin + -player.camera.global_transform.basis.z * 18.0
	var ray := PhysicsRayQueryParameters3D.create(origin, end)
	ray.exclude = [player]
	var hit := get_world_3d().direct_space_state.intersect_ray(ray)
	if not hit.has("position"):
		build_preview.visible = false
		preview_valid = false
		return
	var target: Vector3 = hit["position"]
	var check_size: Vector3
	var check_position: Vector3
	var cost := 150 if selected_building == "Staubfoerderer" else (250 if selected_building == "Staubpresse" else (500 if selected_building == "UpgradeStation" else 10))
	if selected_building == "Foerderband":
		if conveyor_start_set:
			preview_endpoint = _branch_endpoint(target) if is_instance_valid(conveyor_branch_source) else _snap_conveyor_point(target, false)
			var delta := preview_endpoint - conveyor_start
			delta.y = 0.0
			var length := delta.length()
			if length < 0.1:
				build_preview.visible = false
				preview_valid = false
				return
			preview_yaw = atan2(-delta.x, -delta.z)
			preview_position = conveyor_start + delta * 0.5
			preview_position.y = 0.15
			var visual_length := maxf(length, 2.4)
			build_preview.position = preview_position
			build_preview.rotation = Vector3(0, preview_yaw, 0)
			build_preview.scale = Vector3(1, 1, visual_length / 2.4)
			check_size = Vector3(0.82, 0.14, maxf(length - 0.25, 0.2))
			check_position = preview_position + Vector3(0, 0.12, 0)
			cost = ceili(length / 2.4) * 10
		else:
			var branch_attachment := _find_branch_attachment(target)
			if not branch_attachment.is_empty():
				preview_branch_source = branch_attachment["belt"]
				preview_endpoint = branch_attachment["anchor"]
			else:
				preview_branch_source = null
				preview_endpoint = _snap_conveyor_point(target, true)
			preview_position = Vector3(preview_endpoint.x, 0.15, preview_endpoint.z)
			if is_instance_valid(preview_branch_source):
				var source_direction := (preview_branch_source.get_meta("direction") as Vector3).normalized()
				var side := source_direction.rotated(Vector3.UP, PI * 0.5)
				var player_forward := -player.camera.global_transform.basis.z
				var branch_direction := side if player_forward.dot(side) >= player_forward.dot(-side) else -side
				preview_yaw = atan2(-branch_direction.x, -branch_direction.z)
			else:
				preview_yaw = player.rotation.y
			build_preview.position = preview_position
			build_preview.rotation = Vector3(0, preview_yaw, 0)
			build_preview.scale = Vector3(1, 1, 1)
			check_size = Vector3(0.82, 0.14, 2.2)
			check_position = preview_position + Vector3(0, 0.12, 0)
	else:
		preview_position = Vector3(round(target.x / 2.0) * 2.0, 1.0, round(target.z / 2.0) * 2.0)
		preview_yaw = 0.0
		build_preview.position = preview_position
		build_preview.rotation = Vector3.ZERO
		build_preview.scale = Vector3.ONE
		check_size = Vector3(1.8, 1.8, 1.8)
		check_position = preview_position
	var shape := BoxShape3D.new()
	shape.size = check_size
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(Vector3.UP, preview_yaw), check_position)
	query.exclude = [player.get_rid()]
	query.collide_with_areas = false
	var overlaps := get_world_3d().direct_space_state.intersect_shape(query, 12)
	var blocked := false
	if selected_building == "Foerderband":
		for overlap in overlaps:
			if not _is_allowed_conveyor_overlap(overlap.get("collider"), conveyor_start if conveyor_start_set else preview_endpoint, preview_endpoint):
				blocked = true
				break
	else:
		blocked = not overlaps.is_empty()
	preview_valid = not blocked and money >= cost
	_set_preview_tint(build_preview, Color(0.25, 1.0, 0.48, 0.42) if preview_valid else Color(1.0, 0.22, 0.18, 0.48))
	build_preview.visible = true
func _update_economy_ui() -> void:
	if is_instance_valid(balance_label):
		balance_label.text = "Kontostand: %d cr" % money
	if is_instance_valid(production_label):
		production_label.text = "Staub: %d · gepresst: %d" % [dust, compacted_dust]

	if is_instance_valid(belt_stats_label):
		belt_stats_label.text = "Conveyor speed: %.2f m/s  |  Auto-connect at snapped ends" % _current_belt_speed()

func _current_belt_speed() -> float:
	return 1.6 * pow(1.35, belt_upgrade_level)
func _build_settings(layer: CanvasLayer) -> void:
	settings_panel = PanelContainer.new()
	settings_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	settings_panel.offset_left = -230
	settings_panel.offset_top = -210
	settings_panel.offset_right = 230
	settings_panel.offset_bottom = 210
	settings_panel.visible = false
	settings_panel.process_mode = Node.PROCESS_MODE_ALWAYS
	settings_panel.add_theme_stylebox_override("panel", _menu_style(Color(0.055, 0.085, 0.12, 0.98), Color(0.24, 0.72, 0.82)))
	layer.add_child(settings_panel)
	var column := VBoxContainer.new()
	settings_panel.add_child(column)
	var heading := Label.new()
	heading.text = "EINSTELLUNGEN · TASTEN"
	column.add_child(heading)
	for action in ["move_forward", "move_back", "move_left", "move_right", "jump"]:
		var button := Button.new()
		button.text = "%s: %s (ändern)" % [action, key_labels[action]]
		button.pressed.connect(func(): remap_action = action; button.text = "Taste für %s drücken …" % action)
		column.add_child(button)
	var save_button := Button.new()
	save_button.text = "Spiel speichern"
	save_button.pressed.connect(save_game)
	column.add_child(save_button)
	var load_button := Button.new()
	load_button.text = "Spiel laden"
	load_button.pressed.connect(load_game)
	column.add_child(load_button)
	var close_button := Button.new()
	close_button.text = "Schließen"
	close_button.pressed.connect(_toggle_settings)
	column.add_child(close_button)

func _menu_style(fill: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 20
	style.content_margin_bottom = 20
	return style

func _build_pause_menu() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 20
	add_child(layer)
	pause_overlay = ColorRect.new()
	pause_overlay.color = Color(0.015, 0.035, 0.055, 0.78)
	pause_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pause_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	pause_overlay.visible = false
	pause_overlay.process_mode = Node.PROCESS_MODE_ALWAYS
	layer.add_child(pause_overlay)
	pause_panel = PanelContainer.new()
	pause_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	pause_panel.offset_left = -250
	pause_panel.offset_top = -235
	pause_panel.offset_right = 250
	pause_panel.offset_bottom = 235
	pause_panel.add_theme_stylebox_override("panel", _menu_style(Color(0.045, 0.075, 0.105, 0.99), Color(0.91, 0.43, 0.22)))
	pause_overlay.add_child(pause_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	pause_panel.add_child(column)
	var eyebrow := Label.new()
	eyebrow.text = "MARS OUTPOST  /  SECTOR 01"
	eyebrow.add_theme_color_override("font_color", Color(0.39, 0.78, 0.83))
	eyebrow.add_theme_font_size_override("font_size", 14)
	column.add_child(eyebrow)
	var heading := Label.new()
	heading.text = "PAUSE"
	heading.add_theme_color_override("font_color", Color(1.0, 0.89, 0.75))
	heading.add_theme_font_size_override("font_size", 34)
	column.add_child(heading)
	var divider := HSeparator.new()
	column.add_child(divider)
	_add_menu_button(column, "Weiter zum Aussenposten", _resume_game, true)
	_add_menu_button(column, "Einstellungen & Steuerung", _open_settings, false)
	_add_menu_button(column, "Multiplayer", _open_network_menu, false)
	_add_menu_button(column, "Spiel speichern", save_game, false)
	_add_menu_button(column, "Spiel laden", load_game, false)
	var footer := Label.new()
	footer.text = "ESC  ·  Menue schliessen"
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_theme_color_override("font_color", Color(0.55, 0.64, 0.69))
	column.add_child(footer)

func _add_menu_button(parent: VBoxContainer, caption: String, action: Callable, primary: bool) -> void:
	var button := Button.new()
	button.text = caption
	button.custom_minimum_size = Vector2(0, 48)
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", 17)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.09, 0.43, 0.50) if primary else Color(0.10, 0.15, 0.19)
	normal.border_color = Color(0.20, 0.74, 0.81) if primary else Color(0.22, 0.31, 0.36)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(8)
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.13, 0.56, 0.63) if primary else Color(0.16, 0.25, 0.30)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	button.pressed.connect(action)
	parent.add_child(button)

func toggle_pause_menu() -> void:
	if building_overlay.visible:
		_close_building_ui()
		return
	build_overlay.visible = false
	network_overlay.visible = false
	selected_building = ""
	_clear_build_preview()
	if settings_panel.visible:
		settings_panel.visible = false
		pause_overlay.visible = true
		return
	var opening := not pause_overlay.visible
	pause_overlay.visible = opening
	get_tree().paused = opening
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if opening else Input.MOUSE_MODE_CAPTURED
	if opening:
		pause_panel.get_child(0).get_child(3).grab_focus()

func _resume_game() -> void:
	pause_overlay.visible = false
	network_overlay.visible = false
	build_overlay.visible = false
	settings_panel.visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _open_settings() -> void:
	pause_overlay.visible = false
	settings_panel.visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _toggle_settings() -> void:
	if settings_panel.visible:
		settings_panel.visible = false
		pause_overlay.visible = true
	else:
		_open_settings()

func _unhandled_input(event: InputEvent) -> void:
	if remap_action != "" and event is InputEventKey and event.pressed:
		InputMap.action_erase_events(remap_action)
		var key_event := InputEventKey.new()
		key_event.physical_keycode = event.physical_keycode
		InputMap.action_add_event(remap_action, key_event)
		key_labels[remap_action] = OS.get_keycode_string(event.keycode)
		var config := ConfigFile.new()
		config.load("user://settings.cfg")
		config.set_value("controls", remap_action, event.physical_keycode)
		config.save("user://settings.cfg")
		remap_action = ""
		return
	if selected_building != "" and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if preview_valid:
			if selected_building == "Foerderband":
				if not conveyor_start_set:
					conveyor_start = preview_endpoint
					conveyor_start_set = true
					conveyor_branch_source = preview_branch_source if is_instance_valid(preview_branch_source) else null
					conveyor_branch_anchor = preview_endpoint
					if hud_status:
						hud_status.text = "Straight start set - branch will meet the belt at 90 degrees." if is_instance_valid(conveyor_branch_source) else "Conveyor start set - aim elsewhere and click to finish."
					return
				var direction := preview_endpoint - conveyor_start
				direction.y = 0.0
				var distance := direction.length()
				var segment_count := maxi(1, ceili(distance / 2.4))
				var segment_length := distance / float(segment_count)
				var belt_yaw := atan2(-direction.x, -direction.z)
				var splitter: Node3D = null
				if is_instance_valid(conveyor_branch_source):
					var branch_direction := direction.normalized()
					splitter = _split_belt_for_branch(conveyor_branch_source, conveyor_branch_anchor, branch_direction)
					if splitter == null:
						_update_status("Could not split this belt at the selected point.")
						return
				var branch_belt: Node3D = null
				for index in range(segment_count):
					var segment_pos := conveyor_start + direction * ((float(index) + 0.5) / float(segment_count))
					var placed_belt := add_conveyor(segment_pos, belt_yaw, segment_length)
					if index == 0:
						branch_belt = placed_belt
				if splitter != null and is_instance_valid(branch_belt):
					var output_belts: Array = splitter.get_meta("output_belts", [])
					output_belts.append(branch_belt)
					splitter.set_meta("output_belts", output_belts)
				conveyor_start_set = false
				conveyor_branch_source = null
			else:
				place_building(selected_building, preview_position)
			if hud_status:
				hud_status.text = "Placed %s." % selected_building
			selected_building = ""
			_clear_build_preview()
		else:
			_update_status("Invalid placement: surface is blocked or balance is too low.")

func save_game() -> void:
	var data := {"money": money, "dust": dust, "compacted_dust": compacted_dust, "machine_upgrade_level": machine_upgrade_level, "belt_upgrade_level": belt_upgrade_level, "buildings": []}
	for group_name in ["dust_extractors", "dust_presses", "upgrade_stations"]:
		for building in get_tree().get_nodes_in_group(group_name):
			data["buildings"].append({"type": building.name, "position": [building.position.x, building.position.y, building.position.z]})
	var file := FileAccess.open("user://savegame.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	_update_status("Spiel gespeichert.")

func load_game() -> void:
	if not FileAccess.file_exists("user://savegame.json"):
		_update_status("Kein Spielstand gefunden.")
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("user://savegame.json"))
	if typeof(parsed) != TYPE_DICTIONARY:
		_update_status("Spielstand ist beschädigt.")
		return
	for group_name in ["dust_extractors", "dust_presses", "upgrade_stations"]:
		for building in get_tree().get_nodes_in_group(group_name):
			building.queue_free()
	money = int(parsed.get("money", 1000))
	dust = int(parsed.get("dust", 0))
	compacted_dust = int(parsed.get("compacted_dust", 0))
	machine_upgrade_level = int(parsed.get("machine_upgrade_level", 0))
	belt_upgrade_level = int(parsed.get("belt_upgrade_level", 0))
	restoring_save = true
	for saved in parsed.get("buildings", []):
		place_building(str(saved["type"]), Vector3(saved["position"][0], 0, saved["position"][2]))
	restoring_save = false
	_update_economy_ui()
	_update_status("Spielstand geladen.")


