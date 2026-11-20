extends Node3D

const PLAYER_SCRIPT = preload("res://player.gd")
const PORT := 24560
const MAX_PLAYERS := 8
var players: Dictionary = {}
var status_label: Label
var money := 1000
var dust := 0
var compacted_dust := 0
var selected_building := ""
var machine_timer := 0.0
var balance_label: Label
var production_label: Label
var settings_panel: PanelContainer
var pause_overlay: ColorRect
var pause_panel: PanelContainer
var build_overlay: ColorRect
var build_panel: PanelContainer
var network_overlay: ColorRect
var hud_status: Label
var remap_action := ""
var restoring_save := false
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
	_update_economy_ui()

func _process(delta: float) -> void:
	if get_tree().paused:
		return
	machine_timer += delta
	if machine_timer >= 1.0:
		machine_timer -= 1.0
		var extractors := get_tree().get_nodes_in_group("dust_extractors")
		dust += extractors.size()
		var presses := get_tree().get_nodes_in_group("dust_presses")
		for _press in presses:
			if dust >= 2:
				dust -= 2
				compacted_dust += 1
		_update_economy_ui()

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

	# A simple starter outpost visible ahead.
	_add_box(Vector3(0, 1.5, -16), Vector3(7, 3, 5), Color(0.55, 0.58, 0.60))
	_add_box(Vector3(-4.5, 1.0, -16), Vector3(2, 2, 2), Color(0.37, 0.52, 0.58))
	_add_box(Vector3(4.5, 1.0, -16), Vector3(2, 2, 2), Color(0.37, 0.52, 0.58))
	_add_box(Vector3(0, 3.3, -16), Vector3(3.2, 0.4, 2.5), Color(0.18, 0.48, 0.65))

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

func add_conveyor(pos: Vector3, yaw: float) -> void:
	if money < 10:
		_update_status("Nicht genug Geld fuer ein Foerderband (10 cr).")
		return
	money -= 10
	var belt := Node3D.new()
	belt.name = "ConveyorSegment"
	belt.position = Vector3(round(pos.x), 0.15, round(pos.z))
	belt.rotation.y = yaw
	var base := MeshInstance3D.new()
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(1.0, 0.16, 2.4)
	base.mesh = base_mesh
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color(0.17, 0.23, 0.27)
	steel.metallic = 0.72
	base.material_override = steel
	belt.add_child(base)
	for z in [-0.8, 0.0, 0.8]:
		var roller := MeshInstance3D.new()
		var roller_mesh := CylinderMesh.new()
		roller_mesh.top_radius = 0.09
		roller_mesh.bottom_radius = 0.09
		roller_mesh.height = 1.05
		roller.mesh = roller_mesh
		roller.rotation.z = deg_to_rad(90)
		roller.position = Vector3(0, 0.12, z)
		roller.material_override = steel
		belt.add_child(roller)
	add_child(belt)
	_update_economy_ui()

func place_building(kind: String, pos: Vector3) -> void:
	var cost := 150 if kind == "Staubförderer" else 250
	if not restoring_save and money < cost:
		_update_status("Nicht genug Geld für %s. Benötigt: %d cr." % [kind, cost])
		return
	if not restoring_save:
		money -= cost
	var body := StaticBody3D.new()
	body.name = kind
	body.position = Vector3(round(pos.x / 2.0) * 2.0, 1.0, round(pos.z / 2.0) * 2.0)
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(2.0, 2.0, 2.0)
	mesh_instance.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.82, 0.43, 0.18) if kind == "Staubförderer" else Color(0.45, 0.58, 0.64)
	material.metallic = 0.35
	mesh_instance.material_override = material
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = mesh.size
	collision.shape = box
	body.add_child(collision)
	if kind == "Staubförderer":
		body.add_to_group("dust_extractors")
	else:
		body.add_to_group("dust_presses")
	add_child(body)
	selected_building = ""
	_update_economy_ui()

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
	hint.text = "WASD move  |  E mine  |  B build menu  |  ESC pause"
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
	_add_menu_button(column, "Dust extractor  |  150 cr", func(): _select_building("Staubfoerderer"), true)
	_add_menu_button(column, "Dust press  |  250 cr", func(): _select_building("Staubpresse"), false)
	_add_menu_button(column, "Conveyor  |  10 cr", func(): _select_building("Foerderband"), false)
	_add_menu_button(column, "Close  |  B / ESC", _close_build_menu, false)

func _select_building(kind: String) -> void:
	selected_building = kind
	build_overlay.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if hud_status:
		hud_status.text = "%s selected - click ground to place." % kind

func _close_build_menu() -> void:
	build_overlay.visible = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func toggle_build_menu() -> void:
	if get_tree().paused or pause_overlay.visible:
		return
	build_overlay.visible = not build_overlay.visible
	selected_building = ""
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if build_overlay.visible else Input.MOUSE_MODE_CAPTURED
	if build_overlay.visible:
		build_panel.get_child(0).get_child(3).grab_focus()
func _update_economy_ui() -> void:
	if is_instance_valid(balance_label):
		balance_label.text = "Kontostand: %d cr" % money
	if is_instance_valid(production_label):
		production_label.text = "Staub: %d · gepresst: %d" % [dust, compacted_dust]

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
	build_overlay.visible = false
	network_overlay.visible = false
	selected_building = ""
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
		var player = players.get(multiplayer.get_unique_id())
		if player and player.camera:
			var origin: Vector3 = player.camera.global_position
			var end: Vector3 = origin + -player.camera.global_transform.basis.z * 12.0
			var query := PhysicsRayQueryParameters3D.create(origin, end)
			query.exclude = [player]
			var hit := get_world_3d().direct_space_state.intersect_ray(query)
			if hit.has("position"):
				if selected_building == "Foerderband":
					add_conveyor(hit["position"], player.rotation.y)
					selected_building = ""
				else:
					place_building(selected_building, hit["position"])

func save_game() -> void:
	var data := {"money": money, "dust": dust, "compacted_dust": compacted_dust, "buildings": []}
	for group_name in ["dust_extractors", "dust_presses"]:
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
	for group_name in ["dust_extractors", "dust_presses"]:
		for building in get_tree().get_nodes_in_group(group_name):
			building.queue_free()
	money = int(parsed.get("money", 1000))
	dust = int(parsed.get("dust", 0))
	compacted_dust = int(parsed.get("compacted_dust", 0))
	restoring_save = true
	for saved in parsed.get("buildings", []):
		place_building(str(saved["type"]), Vector3(saved["position"][0], 0, saved["position"][2]))
	restoring_save = false
	_update_economy_ui()
	_update_status("Spielstand geladen.")


