extends CharacterBody3D

const SPEED := 6.0
const JUMP_VELOCITY := 4.8
const MOUSE_SENSITIVITY := 0.0022
const SEND_INTERVAL := 0.05
var camera: Camera3D
var pitch := 0.0
var send_timer := 0.0
var remote_target_position := Vector3.ZERO
var remote_target_rotation := Vector3.ZERO
var is_local_player := false
var belt_mode := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	is_local_player = is_multiplayer_authority()
	var capsule := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.38
	shape.height = 1.8
	capsule.shape = shape
	add_child(capsule)
	if is_local_player:
		camera = Camera3D.new()
		camera.position.y = 0.62
		camera.current = true
		add_child(camera)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		var body_mesh := MeshInstance3D.new()
		var mesh := CapsuleMesh.new()
		mesh.radius = 0.38
		mesh.height = 1.8
		body_mesh.mesh = mesh
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(0.15, 0.65, 0.78)
		body_mesh.material_override = material
		body_mesh.position.y = 0.9
		add_child(body_mesh)
		remote_target_position = global_position
		remote_target_rotation = rotation

func _unhandled_input(event: InputEvent) -> void:
	if not is_local_player:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
		pitch = clampf(pitch - event.relative.y * MOUSE_SENSITIVITY, deg_to_rad(-82), deg_to_rad(82))
		camera.rotation.x = pitch
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		get_parent().toggle_pause_menu()
		get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if belt_mode:
			_place_belt()
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_E:
			_mine_target()

func _raycast_target() -> Dictionary:
	var origin := camera.global_position
	var end := origin + -camera.global_transform.basis.z * 5.0
	var query := PhysicsRayQueryParameters3D.create(origin, end)
	query.exclude = [self]
	return get_world_3d().direct_space_state.intersect_ray(query)

func _mine_target() -> void:
	var hit := _raycast_target()
	if hit.has("collider"):
		var collider = hit["collider"]
		if collider is Node3D and collider.name.begins_with("OreRock"):
			get_parent().mine_rock(collider)

func _place_belt() -> void:
	var hit := _raycast_target()
	if hit.has("position"):
		get_parent().add_conveyor(hit["position"], rotation.y)

func _physics_process(delta: float) -> void:
	if get_tree().paused:
		return
	if not is_local_player:
		global_position = global_position.lerp(remote_target_position, min(delta * 12.0, 1.0))
		rotation.y = lerp_angle(rotation.y, remote_target_rotation.y, min(delta * 12.0, 1.0))
		return
	if not is_on_floor():
		velocity += get_gravity() * delta
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED * 5 * delta)
		velocity.z = move_toward(velocity.z, 0, SPEED * 5 * delta)
	move_and_slide()
	send_timer += delta
	if send_timer >= SEND_INTERVAL and multiplayer.has_multiplayer_peer():
		send_timer = 0.0
		_sync_transform.rpc(global_position, rotation)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _sync_transform(new_position: Vector3, new_rotation: Vector3) -> void:
	if multiplayer.get_remote_sender_id() != get_multiplayer_authority():
		return
	remote_target_position = new_position
	remote_target_rotation = new_rotation
