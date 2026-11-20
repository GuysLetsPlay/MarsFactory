extends Node3D

const PLAYER_SCRIPT = preload("res://player.gd")
const PORT := 24560
const MAX_PLAYERS := 8
var players: Dictionary = {}
var status_label: Label

func _ready() -> void:
	_build_world()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_spawn_player(multiplayer.get_unique_id())
	_build_hud()
	_build_network_menu()

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

func _build_network_menu() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(24, 100)
	panel.custom_minimum_size = Vector2(300, 190)
	layer.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)
	var heading := Label.new()
	heading.text = "MULTIPLAYER · bis zu 8 Spieler"
	column.add_child(heading)
	var host_button := Button.new()
	host_button.text = "Sitzung hosten"
	host_button.pressed.connect(_host_game)
	column.add_child(host_button)
	var address := LineEdit.new()
	address.placeholder_text = "Host-IP, z. B. 192.168.1.20"
	address.text = "127.0.0.1"
	column.add_child(address)
	var join_button := Button.new()
	join_button.text = "Beitreten"
	join_button.pressed.connect(func(): _join_game(address.text))
	column.add_child(join_button)
	status_label = Label.new()
	status_label.text = "Lokal solo. Host starten oder IP eingeben."
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(status_label)

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var title := Label.new()
	title.text = "MARS OUTPOST  /  SECTOR 01"
	title.position = Vector2(24, 20)
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1.0, 0.78, 0.59))
	layer.add_child(title)
	var hint := Label.new()
	hint.text = "WASD bewegen   •   Maus umsehen   •   Leertaste springen   •   ESC Maus freigeben"
	hint.position = Vector2(24, 58)
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.88))
	layer.add_child(hint)
	var cross := Label.new()
	cross.text = "+"
	cross.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	cross.position = Vector2(-7, -15)
	cross.add_theme_font_size_override("font_size", 26)
	cross.add_theme_color_override("font_color", Color(1, 0.86, 0.7, 0.8))
	layer.add_child(cross)

