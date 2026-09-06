## `U` autoload — Unity engine shims that do not depend on the world (math, transforms,
## components, physics queries, audio, animation, particles, materials, UI, strings, time).
##
## Coordinate conventions: Unity is left-handed with +Z forward; Godot is right-handed with
## -Z forward. `coord_mode` selects how `transform.forward`, `Vector3.forward`, Euler angles
## and LookRotation are interpreted. UNITY keeps all numbers identical to the source (use it
## when your scene was imported preserving Unity axes); GODOT maps forward to -Z.
extends Node

enum CoordMode { UNITY, GODOT }
var coord_mode: CoordMode = CoordMode.UNITY

var _noise: FastNoiseLite = null
var _debug_lines: Array = []
var _line_data: Dictionary = {}     # node id → Dictionary for LineRenderer emulation
var _anim_params: Dictionary = {}   # node id → Dictionary of animator parameters
var _ps_modules: Dictionary = {}    # node id → Dictionary of particle module adapters
var _tags: Dictionary = {}          # node id → tag
var _layers: Dictionary = {}        # node id → Unity layer number
var _layer_names: Dictionary = {"Default": 0, "TransparentFX": 1, "Ignore Raycast": 2, "Water": 4, "UI": 5, "Player": 9, "PlayerLocal": 10, "Environment": 11, "UiMenu": 12, "Pickup": 13, "PickupNoEnvironment": 14, "StereoLeft": 15, "StereoRight": 16, "Walkthrough": 17, "MirrorReflection": 18, "reserved2": 19, "reserved3": 20, "reserved4": 21}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------

func unsupported(what: String):
	push_warning("udon2godot: unsupported API used: " + what)
	return null

func throw(msg: String) -> void:
	push_error("Udon exception: " + msg)
	assert(false, msg)

# ---------------------------------------------------------------------------
# UdonBehaviour API entry points.
# Converted scripts call these instead of the base-class methods: a call from guest code into a
# base-class GDScript method re-enters the sandbox, and the sandbox allows only a few nested
# VM entries per script. Host-side helpers keep the nesting flat.
# ---------------------------------------------------------------------------

func send_custom_event(b, event_name: String) -> void:
	if b == null or not is_instance_valid(b):
		return
	if b.has_method(event_name):
		b.call(event_name)
	elif b.has_method("SendCustomEvent"):
		b.SendCustomEvent(event_name)
	else:
		push_warning("SendCustomEvent: %s has no event '%s'" % [b.name, event_name])

func send_custom_event_delayed_seconds(b, event_name: String, delay: float, timing: int) -> void:
	if b != null and is_instance_valid(b) and b.has_method("SendCustomEventDelayedSeconds"):
		b.SendCustomEventDelayedSeconds(event_name, delay, timing)

func send_custom_event_delayed_frames(b, event_name: String, frames: int, timing: int) -> void:
	if b != null and is_instance_valid(b) and b.has_method("SendCustomEventDelayedFrames"):
		b.SendCustomEventDelayedFrames(event_name, frames, timing)

func send_custom_network_event(b, target: int, event_name: String, args: Array) -> void:
	if b != null and is_instance_valid(b):
		Udon.send_network_event(b, target, event_name, args)

func request_serialization(b) -> void:
	if b != null and is_instance_valid(b) and b.has_method("RequestSerialization"):
		b.RequestSerialization()

# ---------------------------------------------------------------------------
# Time
# ---------------------------------------------------------------------------

func delta_time() -> float:
	return Udon._physics_delta if Udon._in_physics else Udon._delta

func unscaled_delta_time() -> float:
	var ts: float = Engine.time_scale
	return delta_time() / ts if ts > 0.0 else delta_time()

func fixed_delta_time() -> float:
	return 1.0 / float(Engine.physics_ticks_per_second)

func time() -> float:
	return Udon._time

func fixed_time() -> float:
	return Udon._fixed_time

func realtime() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0

# ---------------------------------------------------------------------------
# Math
# ---------------------------------------------------------------------------

func sign(x: float) -> float:
	return 1.0 if x >= 0.0 else -1.0

func round_even(x: float) -> float:
	var r: float = roundf(x)
	if absf(x - floorf(x) - 0.5) < 1e-9:
		var f: float = floorf(x)
		return f if fmod(f, 2.0) == 0.0 else f + 1.0
	return r

func trunc(x: float) -> float:
	return float(int(x))

func f2i(x: float) -> int:
	if is_nan(x):
		return -2147483648
	if x >= 2147483647.0:
		return 2147483647
	if x <= -2147483648.0:
		return -2147483648
	return int(x)

func wrap_i32(v: int) -> int:
	v = v & 0xFFFFFFFF
	return v - 0x100000000 if v >= 0x80000000 else v

func wrap_i16(v: int) -> int:
	v = v & 0xFFFF
	return v - 0x10000 if v >= 0x8000 else v

func wrap_i8(v: int) -> int:
	v = v & 0xFF
	return v - 0x100 if v >= 0x80 else v

func compare(a, b) -> int:
	if a < b:
		return -1
	if a > b:
		return 1
	return 0

func inverse_lerp(a: float, b: float, v: float) -> float:
	if a == b:
		return 0.0
	return clampf((v - a) / (b - a), 0.0, 1.0)

func lerp_angle_deg(a: float, b: float, t: float) -> float:
	return a + delta_angle(a, b) * t

func delta_angle(a: float, b: float) -> float:
	var d: float = fposmod(b - a, 360.0)
	if d > 180.0:
		d -= 360.0
	return d

func move_towards_angle(cur: float, target: float, max_delta: float) -> float:
	var d: float = delta_angle(cur, target)
	if -max_delta < d and d < max_delta:
		return target
	return move_toward(cur, cur + d, max_delta)

func smooth_step(from: float, to: float, t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	t = -2.0 * t * t * t + 3.0 * t * t
	return to * t + from * (1.0 - t)

## Unity's Mathf.SmoothDamp. Returns [value, velocity].
func smooth_damp(current: float, target: float, vel: float, smooth_time: float, max_speed: float, dt: float) -> Array:
	smooth_time = maxf(0.0001, smooth_time)
	var omega: float = 2.0 / smooth_time
	var x: float = omega * dt
	var exp_: float = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	var change: float = current - target
	var original_to: float = target
	var max_change: float = max_speed * smooth_time
	change = clampf(change, -max_change, max_change)
	target = current - change
	var temp: float = (vel + omega * change) * dt
	vel = (vel - omega * temp) * exp_
	var output: float = target + (change + temp) * exp_
	if (original_to - current > 0.0) == (output > original_to):
		output = original_to
		vel = (output - original_to) / dt
	return [output, vel]

func smooth_damp_angle(current: float, target: float, vel: float, smooth_time: float, max_speed: float, dt: float) -> Array:
	target = current + delta_angle(current, target)
	return smooth_damp(current, target, vel, smooth_time, max_speed, dt)

func vec3_smooth_damp(current: Vector3, target: Vector3, vel: Vector3, smooth_time: float, max_speed: float, dt: float) -> Array:
	var x: Array = smooth_damp(current.x, target.x, vel.x, smooth_time, max_speed, dt)
	var y: Array = smooth_damp(current.y, target.y, vel.y, smooth_time, max_speed, dt)
	var z: Array = smooth_damp(current.z, target.z, vel.z, smooth_time, max_speed, dt)
	return [Vector3(x[0], y[0], z[0]), Vector3(x[1], y[1], z[1])]

func vec2_smooth_damp(current: Vector2, target: Vector2, vel: Vector2, smooth_time: float, max_speed: float, dt: float) -> Array:
	var x: Array = smooth_damp(current.x, target.x, vel.x, smooth_time, max_speed, dt)
	var y: Array = smooth_damp(current.y, target.y, vel.y, smooth_time, max_speed, dt)
	return [Vector2(x[0], y[0]), Vector2(x[1], y[1])]

func perlin_noise(x: float, y: float) -> float:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_PERLIN
		_noise.frequency = 1.0
	return (_noise.get_noise_2d(x, y) + 1.0) * 0.5

func closest_po2(v: int) -> int:
	var up: int = nearest_po2(v)
	var down: int = up >> 1
	return up if (up - v) <= (v - down) else down

func gamma(value: float, abs_max: float, g: float) -> float:
	var neg: bool = value < 0.0
	var a: float = absf(value)
	if a > abs_max:
		return -a if neg else a
	var r: float = pow(a / abs_max, g) * abs_max
	return -r if neg else r

func min_all(arr: Array):
	var m = arr[0]
	for v in arr:
		if v < m:
			m = v
	return m

func max_all(arr: Array):
	var m = arr[0]
	for v in arr:
		if v > m:
			m = v
	return m

func new_random(seed_: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	if seed_ >= 0:
		r.seed = seed_
	else:
		r.randomize()
	return r

func inside_unit_sphere() -> Vector3:
	while true:
		var v := Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		if v.length_squared() <= 1.0:
			return v
	return Vector3.ZERO

func on_unit_sphere() -> Vector3:
	var v := inside_unit_sphere()
	return v.normalized() if v.length_squared() > 0.0 else Vector3.UP

func inside_unit_circle() -> Vector2:
	while true:
		var v := Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		if v.length_squared() <= 1.0:
			return v
	return Vector2.ZERO

func random_rotation() -> Quaternion:
	return Quaternion(on_unit_sphere(), randf_range(0.0, TAU)).normalized()

# ---------------------------------------------------------------------------
# Vectors, quaternions, coordinate conventions
# ---------------------------------------------------------------------------

func forward_sign() -> float:
	return 1.0 if coord_mode == CoordMode.UNITY else -1.0

func vec_forward() -> Vector3:
	return Vector3(0.0, 0.0, forward_sign())

func vec_back() -> Vector3:
	return Vector3(0.0, 0.0, -forward_sign())

func forward(n: Node3D) -> Vector3:
	# Godot cameras and lights look down -Z whatever the coordinate mode; Unity's do so along +Z.
	if n is Camera3D or n is Light3D:
		return -n.global_transform.basis.z.normalized()
	return n.global_transform.basis.z.normalized() * forward_sign()

func right(n: Node3D) -> Vector3:
	return n.global_transform.basis.x.normalized()

func up(n: Node3D) -> Vector3:
	return n.global_transform.basis.y.normalized()

func get_global_rotation(n: Node3D) -> Quaternion:
	return n.global_transform.basis.get_rotation_quaternion()

func set_global_rotation(n: Node3D, q: Quaternion) -> void:
	var s: Vector3 = n.global_transform.basis.get_scale()
	var t: Transform3D = n.global_transform
	t.basis = Basis(q.normalized()).scaled(s)
	n.global_transform = t

func set_right(n: Node3D, r: Vector3) -> void:
	set_global_rotation(n, from_to_rotation(right(n), r) * get_global_rotation(n))

func set_up(n: Node3D, u_: Vector3) -> void:
	set_global_rotation(n, from_to_rotation(up(n), u_) * get_global_rotation(n))

## Unity Quaternion.Euler (degrees, applied Z then X then Y).
func euler(x: float, y: float, z: float) -> Quaternion:
	var qx := Quaternion(Vector3.RIGHT, deg_to_rad(x))
	var qy := Quaternion(Vector3.UP, deg_to_rad(y))
	var qz := Quaternion(Vector3(0.0, 0.0, 1.0), deg_to_rad(z))
	if coord_mode == CoordMode.UNITY:
		return (qy * qx * qz).normalized()
	# Mirrored handedness: rotations about X and Y flip sign.
	qx = Quaternion(Vector3.RIGHT, -deg_to_rad(x))
	qy = Quaternion(Vector3.UP, -deg_to_rad(y))
	return (qy * qx * qz).normalized()

func euler_v(v: Vector3) -> Quaternion:
	return euler(v.x, v.y, v.z)

## Inverse of `euler`: Unity-style Euler angles in degrees (Y-X-Z order, 0..360).
func quat_to_euler(q: Quaternion) -> Vector3:
	var e: Vector3 = Basis(q.normalized()).get_euler(EULER_ORDER_YXZ)
	var deg := Vector3(rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z))
	if coord_mode == CoordMode.GODOT:
		deg.x = -deg.x
		deg.y = -deg.y
	return Vector3(fposmod(deg.x, 360.0), fposmod(deg.y, 360.0), fposmod(deg.z, 360.0))

func angle_axis(angle_deg: float, axis: Vector3) -> Quaternion:
	if axis.length_squared() < 1e-12:
		return Quaternion()
	var a: float = deg_to_rad(angle_deg)
	if coord_mode == CoordMode.GODOT:
		a = -a
	return Quaternion(axis.normalized(), a)

func quat_axis(q: Quaternion) -> Vector3:
	var a: Vector3 = q.get_axis()
	return a if a.length_squared() > 0.0 else Vector3.RIGHT

## Unity Quaternion.LookRotation: rotation whose forward points along `fwd`.
func look_rotation(fwd: Vector3, up_: Vector3) -> Quaternion:
	if fwd.length_squared() < 1e-12:
		return Quaternion()
	var f: Vector3 = fwd.normalized()
	if up_.length_squared() < 1e-12 or absf(f.dot(up_.normalized())) > 0.9999:
		up_ = Vector3.UP if absf(f.dot(Vector3.UP)) < 0.9999 else Vector3(0.0, 0.0, 1.0)
	var z: Vector3 = f * forward_sign()
	var x: Vector3 = up_.cross(z).normalized()
	var y: Vector3 = z.cross(x)
	return Basis(x, y, z).get_rotation_quaternion()

func from_to_rotation(a: Vector3, b: Vector3) -> Quaternion:
	if a.length_squared() < 1e-12 or b.length_squared() < 1e-12:
		return Quaternion()
	var an: Vector3 = a.normalized()
	var bn: Vector3 = b.normalized()
	var d: float = an.dot(bn)
	if d > 0.999999:
		return Quaternion()
	if d < -0.999999:
		var axis: Vector3 = Vector3.RIGHT.cross(an)
		if axis.length_squared() < 1e-6:
			axis = Vector3.UP.cross(an)
		return Quaternion(axis.normalized(), PI)
	var c: Vector3 = an.cross(bn)
	var q := Quaternion(c.x, c.y, c.z, 1.0 + d)
	return q.normalized()

func quat_lerp(a: Quaternion, b: Quaternion, t: float) -> Quaternion:
	if a.dot(b) < 0.0:
		b = -b
	return Quaternion(lerpf(a.x, b.x, t), lerpf(a.y, b.y, t), lerpf(a.z, b.z, t), lerpf(a.w, b.w, t)).normalized()

func quat_rotate_towards(a: Quaternion, b: Quaternion, max_deg: float) -> Quaternion:
	var ang: float = rad_to_deg(a.angle_to(b))
	if ang <= 0.0001:
		return b
	return a.slerp(b, minf(1.0, max_deg / ang))

func vec3_slerp(a: Vector3, b: Vector3, t: float) -> Vector3:
	if a.length_squared() < 1e-12 or b.length_squared() < 1e-12:
		return a.lerp(b, t)
	return a.slerp(b, t)

func vec3_rotate_towards(cur: Vector3, target: Vector3, max_rad: float, max_mag: float) -> Vector3:
	var ang: float = cur.angle_to(target)
	var mag: float = move_toward(cur.length(), target.length(), max_mag)
	if ang <= 1e-6 or cur.length_squared() < 1e-12:
		return target.normalized() * mag if target.length_squared() > 0.0 else cur
	var axis: Vector3 = cur.cross(target)
	if axis.length_squared() < 1e-12:
		axis = Vector3.UP if absf(cur.normalized().dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var r: Vector3 = cur.rotated(axis.normalized(), minf(ang, max_rad))
	return r.normalized() * mag

func project_on_plane(v: Vector3, normal: Vector3) -> Vector3:
	var n2: float = normal.length_squared()
	if n2 < 1e-12:
		return v
	return v - normal * (v.dot(normal) / n2)

func reflect(v: Vector3, normal: Vector3) -> Vector3:
	return v - 2.0 * v.dot(normal) * normal

func ortho_normalize(a: Vector3, b: Vector3) -> Array:
	var an: Vector3 = a.normalized()
	var bn: Vector3 = (b - an * b.dot(an)).normalized()
	return [an, bn]

func matrix_column(t: Transform3D, i: int) -> Vector4:
	match i:
		0:
			return Vector4(t.basis.x.x, t.basis.x.y, t.basis.x.z, 0.0)
		1:
			return Vector4(t.basis.y.x, t.basis.y.y, t.basis.y.z, 0.0)
		2:
			return Vector4(t.basis.z.x, t.basis.z.y, t.basis.z.z, 0.0)
		_:
			return Vector4(t.origin.x, t.origin.y, t.origin.z, 1.0)

func matrix_row(t: Transform3D, i: int) -> Vector4:
	return Vector4(t.basis.x[i], t.basis.y[i], t.basis.z[i], t.origin[i])

func aabb_closest_point(b: AABB, p: Vector3) -> Vector3:
	return Vector3(clampf(p.x, b.position.x, b.end.x), clampf(p.y, b.position.y, b.end.y), clampf(p.z, b.position.z, b.end.z))

# ---------------------------------------------------------------------------
# Transform
# ---------------------------------------------------------------------------

func transform_direction(n: Node3D, v: Vector3) -> Vector3:
	return n.global_transform.basis.orthonormalized() * v

func inverse_transform_direction(n: Node3D, v: Vector3) -> Vector3:
	return n.global_transform.basis.orthonormalized().inverse() * v

func look_at(n: Node3D, target: Vector3, up_: Vector3) -> void:
	var d: Vector3 = target - n.global_position
	if d.length_squared() < 1e-12:
		return
	set_global_rotation(n, look_rotation(d, up_))

## space: 0 = Self (Unity default), 1 = World
func rotate_euler(n: Node3D, euler_deg: Vector3, space: int) -> void:
	var q: Quaternion = euler_v(euler_deg)
	if space == 0:
		n.quaternion = (n.quaternion * q).normalized()
	else:
		set_global_rotation(n, (q * get_global_rotation(n)).normalized())

func rotate_axis(n: Node3D, axis: Vector3, angle_deg: float, space: int) -> void:
	var q: Quaternion = angle_axis(angle_deg, axis)
	if space == 0:
		n.quaternion = (n.quaternion * q).normalized()
	else:
		set_global_rotation(n, (q * get_global_rotation(n)).normalized())

func rotate_around(n: Node3D, point: Vector3, axis: Vector3, angle_deg: float) -> void:
	var q: Quaternion = angle_axis(angle_deg, axis)
	var dir: Vector3 = n.global_position - point
	n.global_position = point + q * dir
	set_global_rotation(n, (q * get_global_rotation(n)).normalized())

func translate(n: Node3D, v: Vector3, space: int) -> void:
	if space == 0:
		n.global_position += transform_direction(n, v)
	else:
		n.global_position += v

func translate_relative(n: Node3D, v: Vector3, relative_to: Node3D) -> void:
	if relative_to == null:
		n.global_position += v
	else:
		n.global_position += transform_direction(relative_to, v)

func set_position_and_rotation(n: Node3D, p: Vector3, q: Quaternion) -> void:
	n.global_position = p
	set_global_rotation(n, q)

func set_local_position_and_rotation(n: Node3D, p: Vector3, q: Quaternion) -> void:
	n.position = p
	n.quaternion = q

func set_parent(n: Node, parent: Node, world_stays: bool) -> void:
	if n == null:
		return
	if parent == null:
		parent = n.get_tree().current_scene if n.is_inside_tree() else null
	if n.get_parent() == parent:
		return
	if n.is_inside_tree() and parent != null:
		n.reparent(parent, world_stays)
	elif parent != null:
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		parent.add_child(n)

func root_of(n: Node) -> Node:
	var cur: Node = n
	while cur.get_parent() != null and cur.get_parent() != cur.get_tree().root:
		cur = cur.get_parent()
	return cur

func is_child_of(n: Node, parent: Node) -> bool:
	return parent != null and (parent == n or parent.is_ancestor_of(n))

func detach_children(n: Node) -> void:
	for c in n.get_children():
		c.reparent(n.get_parent(), true)

func set_sibling_index(n: Node, i: int) -> void:
	var p: Node = n.get_parent()
	if p != null:
		p.move_child(n, i if i >= 0 else p.get_child_count() - 1)

# ---------------------------------------------------------------------------
# GameObject / components
# ---------------------------------------------------------------------------

func set_active(n: Node, active: bool) -> void:
	if n == null:
		return
	var was: bool = is_active(n)
	if n is CanvasItem or n is Node3D:
		n.visible = active
	n.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
	if n is CollisionObject3D:
		n.set_deferred("disable_mode", CollisionObject3D.DISABLE_MODE_REMOVE)
	if was != active:
		var ev: String = "OnEnable" if active else "OnDisable"
		if n.has_method(ev) and n.get("enabled") != false:
			n.call(ev)

func is_active(n: Node) -> bool:
	if n == null:
		return false
	return n.process_mode != Node.PROCESS_MODE_DISABLED

func is_active_in_hierarchy(n: Node) -> bool:
	if n == null:
		return false
	return n.can_process() and is_active(n)

func get_enabled(n: Node) -> bool:
	if n == null:
		return false
	var e = n.get("enabled")
	if e != null:
		return e
	if n is CanvasItem or n is Node3D:
		return n.visible
	return true

func set_enabled(n: Node, v: bool) -> void:
	if n == null:
		return
	if n.get("enabled") != null:
		n.set("enabled", v)
	elif n is CanvasItem or n is Node3D:
		n.visible = v

func new_game_object(name_: String) -> Node3D:
	var n := Node3D.new()
	n.name = name_
	var scene: Node = get_tree().current_scene
	if scene != null:
		scene.add_child(n)
	return n

func get_tag(n: Node) -> String:
	if n == null:
		return "Untagged"
	var t = _tags.get(n.get_instance_id())
	if t != null:
		return t
	for g in n.get_groups():
		if String(g).begins_with("tag:"):
			return String(g).substr(4)
	return "Untagged"

func set_tag(n: Node, tag: String) -> void:
	if n != null:
		_tags[n.get_instance_id()] = tag

func compare_tag(n: Node, tag: String) -> bool:
	return get_tag(n) == tag

func get_layer(n: Node) -> int:
	if n == null:
		return 0
	var l = _layers.get(n.get_instance_id())
	if l != null:
		return l
	if n is CollisionObject3D:
		var mask: int = n.collision_layer
		for i in range(32):
			if mask & (1 << i):
				return i
	return 0

func set_layer(n: Node, layer: int) -> void:
	if n == null:
		return
	_layers[n.get_instance_id()] = layer
	if n is CollisionObject3D:
		n.collision_layer = 1 << layer
	if n is VisualInstance3D:
		n.layers = 1 << (layer % 20)

func layer_mask(names: Array) -> int:
	var m: int = 0
	for nm in names:
		var l: int = name_to_layer(nm)
		if l >= 0:
			m |= 1 << l
	return m

func name_to_layer(name_: String) -> int:
	return _layer_names.get(name_, -1)

func layer_to_name(layer: int) -> String:
	for k in _layer_names.keys():
		if _layer_names[k] == layer:
			return k
	return ""

## Does `n` match a runtime type name (Godot class or UdonSharp class name)?
## Unity component types that have no single Godot class: name → Godot classes ("@udon" = any
## converted behaviour).
const _TYPE_ALIASES: Dictionary = {
	"Component": ["Node"], "Behaviour": ["Node"], "MonoBehaviour": ["@udon"],
	"Collider": ["CollisionObject3D", "CollisionShape3D"],
	"BoxCollider": ["CollisionObject3D", "CollisionShape3D"], "SphereCollider": ["CollisionObject3D", "CollisionShape3D"],
	"CapsuleCollider": ["CollisionObject3D", "CollisionShape3D"], "MeshCollider": ["CollisionObject3D", "CollisionShape3D"],
	"Animator": ["AnimationPlayer", "AnimationTree"],
	"LineRenderer": ["MeshInstance3D"], "TrailRenderer": ["MeshInstance3D", "GPUParticles3D"],
	"TextMeshPro": ["Label3D"], "EventSystem": ["Node"],
}

## VRC components are provider adapters: a node "has" one when the world registered it
## (`Udon.pickup(node)` etc.), put it in the `udon_<kind>` group, or implements the surface itself.
const _VRC_COMPONENTS: Dictionary = {
	"VRC_Pickup": "pickup", "VRCPickup": "pickup", "VRCStation": "station", "VRC_Station": "station",
	"VRCObjectSync": "object_sync", "VRC_ObjectSync": "object_sync", "VRCObjectPool": "object_pool",
	"VRCAvatarPedestal": "avatar_pedestal", "VRC_AvatarPedestal": "avatar_pedestal", "VRCPortalMarker": "portal",
	"VRC_PortalMarker": "portal", "VRCMirrorReflection": "mirror", "VRC_MirrorReflection": "mirror",
	"BaseVRCVideoPlayer": "video", "VRCUnityVideoPlayer": "video", "VRCAVProVideoPlayer": "video",
}

func node_is_type(n, type_name: String) -> bool:
	if n == null or not is_instance_valid(n):
		return false
	if type_name == "" or type_name == "Node" or type_name == "Object":
		return true
	if n is Object and n.is_class(type_name):
		return true
	if _VRC_COMPONENTS.has(type_name):
		return n is Node and Udon.has_component(n, _VRC_COMPONENTS[type_name])
	if _TYPE_ALIASES.has(type_name):
		for a in _TYPE_ALIASES[type_name]:
			if a == "@udon":
				if n is Node and n.has_method("udon_class"):
					return true
			elif n.is_class(a):
				return true
	if n is Node and n.has_method("udon_is") and n.udon_is(type_name):
		return true
	var s = n.get_script() if n is Object else null
	while s != null:
		if s.get_global_name() == type_name:
			return true
		s = s.get_base_script()
	return false

## Unity GetComponent: the node itself, then direct children that are "component-like".
func get_component(n: Node, type_name: String):
	if n == null or not is_instance_valid(n):
		return null
	if node_is_type(n, type_name):
		return n
	for c in n.get_children():
		if _is_component_child(c) and node_is_type(c, type_name):
			return c
	return null

## A child that stands for a separate GameObject (physics body/area, plain spatial, scripted
## behaviour) is not a component of its parent; helper nodes (shapes, meshes, audio, lights...) are.
func _is_component_child(c: Node) -> bool:
	if c is CollisionObject3D or c is CollisionObject2D:
		return false
	var cls: String = c.get_class()
	if cls == "Node3D" or cls == "Node2D" or cls == "Node":
		return false
	if c.has_method("udon_class"):
		return false
	return true

func get_components(n: Node, type_name: String) -> Array:
	var out: Array = []
	if n == null:
		return out
	if node_is_type(n, type_name):
		out.append(n)
	for c in n.get_children():
		if _is_component_child(c) and node_is_type(c, type_name):
			out.append(c)
	return out

func get_component_in_children(n: Node, type_name: String, include_inactive: bool):
	if n == null:
		return null
	if node_is_type(n, type_name) and (include_inactive or is_active(n)):
		return n
	for c in n.get_children():
		var r = get_component_in_children(c, type_name, include_inactive)
		if r != null:
			return r
	return null

func get_components_in_children(n: Node, type_name: String, include_inactive: bool) -> Array:
	var out: Array = []
	_collect_children(n, type_name, include_inactive, out)
	return out

func _collect_children(n: Node, type_name: String, include_inactive: bool, out: Array) -> void:
	if n == null:
		return
	if not include_inactive and not is_active(n):
		return
	if node_is_type(n, type_name):
		out.append(n)
	for c in n.get_children():
		_collect_children(c, type_name, include_inactive, out)

func get_component_in_parent(n: Node, type_name: String, _include_inactive: bool):
	var cur: Node = n
	while cur != null:
		if node_is_type(cur, type_name):
			return cur
		cur = cur.get_parent()
	return null

func get_components_in_parent(n: Node, type_name: String, _include_inactive: bool) -> Array:
	var out: Array = []
	var cur: Node = n
	while cur != null:
		if node_is_type(cur, type_name):
			out.append(cur)
		cur = cur.get_parent()
	return out

func add_component(n: Node, type_name: String):
	if ClassDB.class_exists(type_name):
		var c = ClassDB.instantiate(type_name)
		if c is Node:
			n.add_child(c)
			return c
	push_warning("AddComponent: cannot create " + type_name)
	return null

func find_object(name_: String) -> Node:
	var scene: Node = get_tree().current_scene
	if scene == null:
		scene = get_tree().root
	if name_.begins_with("/"):
		return scene.get_node_or_null(name_.substr(1))
	return scene.find_child(name_, true, false)

func find_with_tag(tag: String) -> Node:
	var all: Array = find_all_with_tag(tag)
	return all[0] if not all.is_empty() else null

func find_all_with_tag(tag: String) -> Array:
	var out: Array = get_tree().get_nodes_in_group("tag:" + tag)
	for id in _tags.keys():
		if _tags[id] == tag:
			var o = instance_from_id(id)
			if o != null and not out.has(o):
				out.append(o)
	return out

func find_object_of_type(type_name: String):
	var all: Array = get_components_in_children(get_tree().current_scene, type_name, true)
	return all[0] if not all.is_empty() else null

func find_objects_of_type(type_name: String) -> Array:
	return get_components_in_children(get_tree().current_scene, type_name, true)

func send_message(n: Node, method: String, arg) -> void:
	if n != null and n.has_method(method):
		if arg == null:
			n.call(method)
		else:
			n.call(method, arg)

func broadcast_message(n: Node, method: String, arg) -> void:
	send_message(n, method, arg)
	for c in n.get_children():
		broadcast_message(c, method, arg)

func obj_eq(a, b) -> bool:
	var av: bool = a != null and is_instance_valid(a)
	var bv: bool = b != null and is_instance_valid(b)
	if not av and not bv:
		return true
	return a == b

func is_type(v, type_name: String) -> bool:
	if v == null:
		return false
	if v is Object:
		return node_is_type(v, type_name)
	return type_name == builtin_type_name(v)

func as_type(v, type_name: String):
	return v if is_type(v, type_name) else null

func type_of(v) -> String:
	if v == null:
		return "null"
	if v is Object:
		if v.has_method("udon_class"):
			return v.udon_class()
		var s = v.get_script()
		if s != null and s.get_global_name() != "":
			return s.get_global_name()
		return v.get_class()
	return builtin_type_name(v)

func builtin_type_name(v) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "bool"
		TYPE_INT:
			return "int"
		TYPE_FLOAT:
			return "float"
		TYPE_STRING, TYPE_STRING_NAME:
			return "string"
		TYPE_VECTOR3:
			return "Vector3"
		TYPE_VECTOR2:
			return "Vector2"
		TYPE_QUATERNION:
			return "Quaternion"
		TYPE_COLOR:
			return "Color"
		TYPE_ARRAY:
			return "Array"
		TYPE_DICTIONARY:
			return "Dictionary"
		_:
			return type_string(typeof(v))

func type_is_subclass(a: String, b: String) -> bool:
	return ClassDB.is_parent_class(a, b)

func string_to_hash(s: String) -> int:
	return s.hash()

func set_global_shader_param(id, value) -> void:
	RenderingServer.global_shader_parameter_set(str(id), value)

func find_shader(_name: String) -> Shader:
	return null

# ---------------------------------------------------------------------------
# Rigidbody
# ---------------------------------------------------------------------------

func rb_set_kinematic(rb: RigidBody3D, kinematic: bool) -> void:
	rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	rb.freeze = kinematic

func rb_get_freeze_rotation(rb: RigidBody3D) -> bool:
	return rb.axis_lock_angular_x and rb.axis_lock_angular_y and rb.axis_lock_angular_z

func rb_set_freeze_rotation(rb: RigidBody3D, v: bool) -> void:
	rb.axis_lock_angular_x = v
	rb.axis_lock_angular_y = v
	rb.axis_lock_angular_z = v

func rb_get_constraints(rb: RigidBody3D) -> int:
	var c: int = 0
	if rb.axis_lock_linear_x:
		c |= 2
	if rb.axis_lock_linear_y:
		c |= 4
	if rb.axis_lock_linear_z:
		c |= 8
	if rb.axis_lock_angular_x:
		c |= 16
	if rb.axis_lock_angular_y:
		c |= 32
	if rb.axis_lock_angular_z:
		c |= 64
	return c

func rb_set_constraints(rb: RigidBody3D, c: int) -> void:
	rb.axis_lock_linear_x = (c & 2) != 0
	rb.axis_lock_linear_y = (c & 4) != 0
	rb.axis_lock_linear_z = (c & 8) != 0
	rb.axis_lock_angular_x = (c & 16) != 0
	rb.axis_lock_angular_y = (c & 32) != 0
	rb.axis_lock_angular_z = (c & 64) != 0

func rb_set_center_of_mass(rb: RigidBody3D, v: Vector3) -> void:
	rb.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	rb.center_of_mass = v

func rb_get_max_angular_velocity(_rb: RigidBody3D) -> float:
	return 7.0

func rb_set_max_angular_velocity(_rb: RigidBody3D, _v: float) -> void:
	pass

func rb_set_detect_collisions(rb: RigidBody3D, v: bool) -> void:
	for c in rb.get_children():
		if c is CollisionShape3D:
			c.disabled = not v

## ForceMode: Force=0 Impulse=1 VelocityChange=2 Acceleration=5
func rb_add_force(rb: RigidBody3D, f: Vector3, mode: int) -> void:
	match mode:
		1:
			rb.apply_central_impulse(f)
		2:
			rb.apply_central_impulse(f * rb.mass)
		5:
			rb.apply_central_force(f * rb.mass)
		_:
			rb.apply_central_force(f)

func rb_add_torque(rb: RigidBody3D, t: Vector3, mode: int) -> void:
	match mode:
		1:
			rb.apply_torque_impulse(t)
		2:
			rb.apply_torque_impulse(t * rb.mass)
		5:
			rb.apply_torque(t * rb.mass)
		_:
			rb.apply_torque(t)

func rb_add_force_at_position(rb: RigidBody3D, f: Vector3, pos: Vector3, mode: int) -> void:
	var offset: Vector3 = pos - rb.global_position
	match mode:
		1:
			rb.apply_impulse(f, offset)
		2:
			rb.apply_impulse(f * rb.mass, offset)
		5:
			rb.apply_force(f * rb.mass, offset)
		_:
			rb.apply_force(f, offset)

func rb_add_explosion_force(rb: RigidBody3D, force: float, origin: Vector3, radius: float, upwards: float, mode: int) -> void:
	var p: Vector3 = rb.global_position
	var d: Vector3 = p - origin
	var dist: float = d.length()
	if radius > 0.0 and dist > radius:
		return
	var falloff: float = 1.0 - (dist / radius if radius > 0.0 else 0.0)
	var dir: Vector3 = (d + Vector3(0.0, upwards, 0.0)).normalized() if dist > 1e-6 else Vector3.UP
	rb_add_force(rb, dir * force * falloff, mode)

func rb_move_position(rb: RigidBody3D, p: Vector3) -> void:
	if rb.freeze:
		rb.global_position = p
	else:
		var dt: float = fixed_delta_time()
		rb.linear_velocity = (p - rb.global_position) / dt

func rb_move_rotation(rb: RigidBody3D, q: Quaternion) -> void:
	if rb.freeze:
		set_global_rotation(rb, q)
	else:
		var dt: float = fixed_delta_time()
		var delta: Quaternion = (q * get_global_rotation(rb).inverse()).normalized()
		var axis: Vector3 = delta.get_axis()
		var ang: float = delta.get_angle()
		if ang > PI:
			ang -= TAU
		rb.angular_velocity = axis * ang / dt if axis.length_squared() > 0.0 else Vector3.ZERO

func rb_point_velocity(rb: RigidBody3D, p: Vector3) -> Vector3:
	return rb.linear_velocity + rb.angular_velocity.cross(p - rb.to_global(rb.center_of_mass))

func rb_sweep_test(rb: RigidBody3D, dir: Vector3, dist: float) -> Dictionary:
	var space := rb.get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	for c in rb.get_children():
		if c is CollisionShape3D and c.shape != null:
			params.shape = c.shape
			params.transform = c.global_transform
			break
	if params.shape == null:
		return {}
	params.motion = dir.normalized() * (dist if is_finite(dist) else 1000.0)
	params.exclude = [rb.get_rid()]
	var m: PackedFloat32Array = space.cast_motion(params)
	if m.size() < 2 or m[0] >= 1.0:
		return {}
	var frac: float = m[0]
	return {"position": rb.global_position + params.motion * frac, "normal": -dir.normalized(), "distance": params.motion.length() * frac, "collider": null}

# ---------------------------------------------------------------------------
# Colliders / physics queries
# ---------------------------------------------------------------------------

func _collision_object(n: Node) -> CollisionObject3D:
	if n is CollisionObject3D:
		return n
	if n is CollisionShape3D and n.get_parent() is CollisionObject3D:
		return n.get_parent()
	if n != null:
		for c in n.get_children():
			if c is CollisionObject3D:
				return c
	return null

func collider_get_enabled(n: Node) -> bool:
	if n is CollisionShape3D:
		return not n.disabled
	var co := _collision_object(n)
	if co == null:
		return false
	var shapes: int = 0
	for c in co.get_children():
		if c is CollisionShape3D:
			shapes += 1
			if not c.disabled:
				return true
	return shapes == 0 and co.collision_layer != 0

func collider_set_enabled(n: Node, v: bool) -> void:
	if n is CollisionShape3D:
		n.disabled = not v
		return
	var co := _collision_object(n)
	if co != null:
		for c in co.get_children():
			if c is CollisionShape3D:
				c.disabled = not v

func collider_is_trigger(n: Node) -> bool:
	return _collision_object(n) is Area3D

func collider_set_trigger(_n: Node, _v: bool) -> void:
	push_warning("Collider.isTrigger cannot be changed at run time in Godot (use an Area3D)")

func collider_bounds(n: Node) -> AABB:
	var co := _collision_object(n)
	var aabb := AABB()
	var first: bool = true
	if co != null:
		for c in co.get_children():
			if c is CollisionShape3D and c.shape != null:
				var local: AABB = c.shape.get_debug_mesh().get_aabb() if c.shape.get_debug_mesh() != null else AABB(Vector3.ZERO, Vector3.ONE)
				var world: AABB = c.global_transform * local
				aabb = world if first else aabb.merge(world)
				first = false
	if first and n is VisualInstance3D:
		return n.global_transform * n.get_aabb()
	if first and n is Node3D:
		return AABB(n.global_position, Vector3.ZERO)
	return aabb

func collider_attached_rigidbody(n: Node) -> RigidBody3D:
	var cur: Node = n
	while cur != null:
		if cur is RigidBody3D:
			return cur
		cur = cur.get_parent()
	return null

func collider_material(_n: Node) -> PhysicsMaterial:
	var co := _collision_object(_n)
	if co is PhysicsBody3D:
		return co.physics_material_override
	return null

func collider_set_material(n: Node, m: PhysicsMaterial) -> void:
	var co := _collision_object(n)
	if co is PhysicsBody3D:
		co.physics_material_override = m

func collider_closest_point(n: Node, p: Vector3) -> Vector3:
	return aabb_closest_point(collider_bounds(n), p)

func collider_raycast(n: Node, ray: Dictionary, dist: float) -> Dictionary:
	var hit: Dictionary = raycast(ray.origin, ray.direction, dist, -1, 2)
	if hit.is_empty():
		return {}
	var co := _collision_object(n)
	if co != null and hit.get("collider") != co:
		return {}
	return hit

func shape_of(n: Node) -> CollisionShape3D:
	if n is CollisionShape3D:
		return n
	var co := _collision_object(n)
	if co != null:
		for c in co.get_children():
			if c is CollisionShape3D:
				return c
	return null

func shape_get_center(n: Node) -> Vector3:
	var s := shape_of(n)
	return s.position if s != null else Vector3.ZERO

func shape_set_center(n: Node, v: Vector3) -> void:
	var s := shape_of(n)
	if s != null:
		s.position = v

func shape_get_size(n: Node) -> Vector3:
	var s := shape_of(n)
	if s != null and s.shape is BoxShape3D:
		return s.shape.size
	return Vector3.ONE

func shape_set_size(n: Node, v: Vector3) -> void:
	var s := shape_of(n)
	if s != null and s.shape is BoxShape3D:
		s.shape.size = v

func shape_get_radius(n: Node) -> float:
	var s := shape_of(n)
	if s != null and (s.shape is SphereShape3D or s.shape is CapsuleShape3D or s.shape is CylinderShape3D):
		return s.shape.radius
	return 0.5

func shape_set_radius(n: Node, v: float) -> void:
	var s := shape_of(n)
	if s != null and (s.shape is SphereShape3D or s.shape is CapsuleShape3D or s.shape is CylinderShape3D):
		s.shape.radius = v

func shape_get_height(n: Node) -> float:
	var s := shape_of(n)
	if s != null and (s.shape is CapsuleShape3D or s.shape is CylinderShape3D):
		return s.shape.height
	return 2.0

func shape_set_height(n: Node, v: float) -> void:
	var s := shape_of(n)
	if s != null and (s.shape is CapsuleShape3D or s.shape is CylinderShape3D):
		s.shape.height = v

func mesh_of(n: Node) -> Mesh:
	if n is MeshInstance3D:
		return n.mesh
	if n != null:
		for c in n.get_children():
			if c is MeshInstance3D:
				return c.mesh
	return null

func gravity() -> Vector3:
	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
	var v: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
	return v * g

func set_gravity(g: Vector3) -> void:
	PhysicsServer3D.area_set_param(get_viewport().world_3d.space, PhysicsServer3D.AREA_PARAM_GRAVITY, g.length())
	PhysicsServer3D.area_set_param(get_viewport().world_3d.space, PhysicsServer3D.AREA_PARAM_GRAVITY_VECTOR, g.normalized())

func _space() -> PhysicsDirectSpaceState3D:
	var w := get_viewport().world_3d if get_viewport() != null else null
	return w.direct_space_state if w != null else null

## Unity layer mask (bit per layer) → Godot collision mask. -1 = everything.
func _godot_mask(unity_mask: int) -> int:
	if unity_mask == -1 or unity_mask == -5:
		return 0xFFFFFFFF
	return unity_mask & 0xFFFFFFFF

## trigger: QueryTriggerInteraction (0 global, 1 ignore, 2 collide)
func raycast(origin: Vector3, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Dictionary:
	var space := _space()
	if space == null or dir.length_squared() < 1e-12:
		return {}
	var d: float = max_dist if is_finite(max_dist) else 100000.0
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir.normalized() * d, _godot_mask(mask))
	q.collide_with_areas = trigger != 1
	q.collide_with_bodies = true
	var r: Dictionary = space.intersect_ray(q)
	if r.is_empty():
		return {}
	r["distance"] = origin.distance_to(r["position"])
	r["origin"] = origin
	return r

func raycast_all(origin: Vector3, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Array:
	var out: Array = []
	var exclude: Array = []
	var space := _space()
	if space == null:
		return out
	var d: float = max_dist if is_finite(max_dist) else 100000.0
	for _i in range(32):
		var q := PhysicsRayQueryParameters3D.create(origin, origin + dir.normalized() * d, _godot_mask(mask))
		q.collide_with_areas = trigger != 1
		q.exclude = exclude
		var r: Dictionary = space.intersect_ray(q)
		if r.is_empty():
			break
		r["distance"] = origin.distance_to(r["position"])
		out.append(r)
		exclude.append(r["rid"])
	return out

func raycast_non_alloc(origin: Vector3, dir: Vector3, results: Array, max_dist: float, mask: int, trigger: int) -> int:
	var hits: Array = raycast_all(origin, dir, max_dist, mask, trigger)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func sphere_cast(origin: Vector3, radius: float, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Dictionary:
	var space := _space()
	if space == null:
		return {}
	var shape := SphereShape3D.new()
	shape.radius = radius
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis(), origin)
	var d: float = max_dist if is_finite(max_dist) else 100000.0
	params.motion = dir.normalized() * d
	params.collision_mask = _godot_mask(mask)
	params.collide_with_areas = trigger != 1
	var m: PackedFloat32Array = space.cast_motion(params)
	if m.size() < 2 or m[0] >= 1.0:
		return {}
	var frac: float = m[0]
	params.transform = Transform3D(Basis(), origin + params.motion * frac)
	var rest: Dictionary = space.get_rest_info(params)
	var hit: Dictionary = {"position": rest.get("point", origin + params.motion * frac), "normal": rest.get("normal", -dir.normalized()), "distance": d * frac, "collider": rest.get("collider_id", 0)}
	if rest.has("collider_id"):
		hit["collider"] = instance_from_id(rest["collider_id"])
	return hit

func sphere_cast_all(origin: Vector3, radius: float, dir: Vector3, max_dist: float, mask: int, trigger: int) -> Array:
	var h: Dictionary = sphere_cast(origin, radius, dir, max_dist, mask, trigger)
	return [h] if not h.is_empty() else []

func sphere_cast_non_alloc(origin: Vector3, radius: float, dir: Vector3, results: Array, max_dist: float, mask: int, trigger: int) -> int:
	var hits: Array = sphere_cast_all(origin, radius, dir, max_dist, mask, trigger)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func capsule_cast(p1: Vector3, p2: Vector3, radius: float, dir: Vector3, max_dist: float, mask: int) -> Dictionary:
	return sphere_cast((p1 + p2) * 0.5, radius, dir, max_dist, mask, 0)

func box_cast(center: Vector3, half: Vector3, dir: Vector3, _rot: Quaternion, max_dist: float, mask: int) -> Dictionary:
	return sphere_cast(center, maxf(half.x, maxf(half.y, half.z)), dir, max_dist, mask, 0)

func _overlap(shape: Shape3D, xform: Transform3D, mask: int, trigger: int) -> Array:
	var space := _space()
	if space == null:
		return []
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = xform
	params.collision_mask = _godot_mask(mask)
	params.collide_with_areas = trigger != 1
	var out: Array = []
	for r in space.intersect_shape(params, 64):
		out.append(r["collider"])
	return out

func overlap_sphere(pos: Vector3, radius: float, mask: int, trigger: int) -> Array:
	var s := SphereShape3D.new()
	s.radius = radius
	return _overlap(s, Transform3D(Basis(), pos), mask, trigger)

func overlap_sphere_non_alloc(pos: Vector3, radius: float, results: Array, mask: int, trigger: int) -> int:
	var hits: Array = overlap_sphere(pos, radius, mask, trigger)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func overlap_box(center: Vector3, half: Vector3, rot: Quaternion, mask: int, trigger: int) -> Array:
	var s := BoxShape3D.new()
	s.size = half * 2.0
	return _overlap(s, Transform3D(Basis(rot), center), mask, trigger)

func overlap_box_non_alloc(center: Vector3, half: Vector3, results: Array, rot: Quaternion, mask: int, trigger: int) -> int:
	var hits: Array = overlap_box(center, half, rot, mask, trigger)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func overlap_capsule(p1: Vector3, p2: Vector3, radius: float, mask: int, trigger: int) -> Array:
	var s := CapsuleShape3D.new()
	s.radius = radius
	s.height = p1.distance_to(p2) + radius * 2.0
	var center: Vector3 = (p1 + p2) * 0.5
	var b := Basis()
	if p1.distance_squared_to(p2) > 1e-9:
		b = Basis(from_to_rotation(Vector3.UP, (p2 - p1).normalized()))
	return _overlap(s, Transform3D(b, center), mask, trigger)

func ignore_collision(a: Node, b: Node, ignore: bool) -> void:
	var ca := _collision_object(a)
	var cb := _collision_object(b)
	if ca == null or cb == null:
		return
	if ignore:
		ca.add_collision_exception_with(cb)
	else:
		ca.remove_collision_exception_with(cb)

func joint_get_connected_body(j: Joint3D) -> Node:
	return j.get_node_or_null(j.node_b)

func joint_set_connected_body(j: Joint3D, body: Node) -> void:
	j.node_b = j.get_path_to(body) if body != null else NodePath()

func hinge_motor(j: HingeJoint3D) -> Dictionary:
	return {"targetVelocity": rad_to_deg(j.get_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY)), "force": j.get_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE)}

func hinge_set_motor(j: HingeJoint3D, m: Dictionary) -> void:
	j.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, deg_to_rad(float(m.get("targetVelocity", 0.0))))
	j.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, float(m.get("force", 0.0)))

func wheel_ground_hit(w: VehicleWheel3D) -> Dictionary:
	return {"point": w.get_contact_point(), "normal": w.get_contact_normal(), "collider": w.get_contact_body(), "force": 0.0, "forwardSlip": 0.0, "sidewaysSlip": w.get_skidinfo()}

# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------

func _vol_prop(a: Node) -> String:
	return "volume_db" if (a is AudioStreamPlayer3D or a is AudioStreamPlayer or a is AudioStreamPlayer2D) else ""

func audio_get_volume(a: Node) -> float:
	var p := _vol_prop(a)
	return db_to_linear(a.get(p)) if p != "" else 1.0

func audio_set_volume(a: Node, v: float) -> void:
	var p := _vol_prop(a)
	if p != "":
		a.set(p, linear_to_db(maxf(v, 0.0001)))

func audio_get_loop(a: Node) -> bool:
	var s = a.get("stream")
	if s is AudioStreamWAV:
		return s.loop_mode != AudioStreamWAV.LOOP_DISABLED
	if s != null and s.get("loop") != null:
		return s.loop
	return false

func audio_set_loop(a: Node, v: bool) -> void:
	var s = a.get("stream")
	if s == null:
		return
	if s is AudioStreamWAV:
		s.loop_mode = AudioStreamWAV.LOOP_FORWARD if v else AudioStreamWAV.LOOP_DISABLED
	elif s.get("loop") != null:
		s.loop = v

func audio_get_mute(a: Node) -> bool:
	return a.get_meta("udon_muted", false)

func audio_set_mute(a: Node, v: bool) -> void:
	if v and not audio_get_mute(a):
		a.set_meta("udon_prev_volume", a.get(_vol_prop(a)))
		a.set(_vol_prop(a), -80.0)
	elif not v and audio_get_mute(a):
		a.set(_vol_prop(a), a.get_meta("udon_prev_volume", 0.0))
	a.set_meta("udon_muted", v)

func audio_get_enabled(a: Node) -> bool:
	return a.process_mode != Node.PROCESS_MODE_DISABLED

func audio_set_enabled(a: Node, v: bool) -> void:
	a.process_mode = Node.PROCESS_MODE_INHERIT if v else Node.PROCESS_MODE_DISABLED
	if not v and a.has_method("stop"):
		a.stop()

func audio_set_bus(a: Node, bus) -> void:
	if bus != null:
		a.set("bus", str(bus))

func audio_play_delayed(a: Node, delay: float) -> void:
	if delay <= 0.0:
		a.play()
		return
	var t := get_tree().create_timer(delay)
	var w: WeakRef = weakref(a)
	t.timeout.connect(func():
		var o = w.get_ref()
		if o != null:
			o.play())

func audio_play_one_shot(a: Node, clip: AudioStream, volume: float) -> void:
	if clip == null:
		return
	var p: Node
	if a is AudioStreamPlayer3D:
		p = AudioStreamPlayer3D.new()
		p.max_distance = a.max_distance
		p.unit_size = a.unit_size
		p.attenuation_model = a.attenuation_model
	elif a is AudioStreamPlayer2D:
		p = AudioStreamPlayer2D.new()
	else:
		p = AudioStreamPlayer.new()
	p.stream = clip
	p.set("bus", a.get("bus"))
	p.set("pitch_scale", a.get("pitch_scale"))
	p.set("volume_db", a.get(_vol_prop(a)) + linear_to_db(maxf(volume, 0.0001)))
	a.add_child(p)
	p.finished.connect(p.queue_free)
	p.play()

func audio_play_at_point(clip: AudioStream, pos: Vector3, volume: float) -> void:
	var p := AudioStreamPlayer3D.new()
	p.stream = clip
	p.volume_db = linear_to_db(maxf(volume, 0.0001))
	get_tree().current_scene.add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()

# ---------------------------------------------------------------------------
# Animator (parameters stored per node; forwarded to an AnimationTree if present)
# ---------------------------------------------------------------------------

func _anim_tree(n: Node) -> AnimationTree:
	if n is AnimationTree:
		return n
	if n != null:
		for c in n.get_children():
			if c is AnimationTree:
				return c
	return null

func _anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	if n != null:
		for c in n.get_children():
			if c is AnimationPlayer:
				return c
	return null

func _params(n: Node) -> Dictionary:
	var id: int = n.get_instance_id()
	if not _anim_params.has(id):
		_anim_params[id] = {}
	return _anim_params[id]

func anim_set(n: Node, key, value) -> void:
	if n == null:
		return
	var k: String = str(key)
	_params(n)[k] = value
	var t := _anim_tree(n)
	if t != null:
		var path: String = "parameters/" + k
		if t.get(path) != null:
			t.set(path, value)
		elif t.get(path + "/blend_amount") != null:
			t.set(path + "/blend_amount", value)
		elif t.get(path + "/blend_position") != null:
			t.set(path + "/blend_position", value)
	if n.has_method("udon_anim_set"):
		n.udon_anim_set(k, value)

func anim_set_damped(n: Node, key, value: float, damp_time: float, dt: float) -> void:
	var cur: float = float(anim_get(n, key, 0.0))
	var r: Array = smooth_damp(cur, value, 0.0, damp_time, INF, dt) if damp_time > 0.0 else [value, 0.0]
	anim_set(n, key, r[0])

func anim_get(n: Node, key, default):
	if n == null:
		return default
	return _params(n).get(str(key), default)

func anim_trigger(n: Node, key) -> void:
	var k: String = str(key)
	var t := _anim_tree(n)
	if t != null:
		var path: String = "parameters/" + k + "/request"
		if t.get(path) != null:
			t.set(path, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			return
	anim_set(n, k, true)
	var p := _anim_player(n)
	if p != null and p.has_animation(k):
		p.play(k)

func anim_reset_trigger(n: Node, key) -> void:
	anim_set(n, str(key), false)

func anim_play(n: Node, state, _layer: int, normalized_time: float) -> void:
	var p := _anim_player(n)
	var s: String = str(state)
	if p != null and p.has_animation(s):
		p.play(s)
		if normalized_time > -INF:
			p.seek(normalized_time * p.get_animation(s).length, true)
		return
	var t := _anim_tree(n)
	if t != null:
		var sm = t.get("parameters/playback")
		if sm is AnimationNodeStateMachinePlayback:
			sm.travel(s)

func anim_cross_fade(n: Node, state, duration: float, _layer: int) -> void:
	var p := _anim_player(n)
	var s: String = str(state)
	if p != null and p.has_animation(s):
		p.play(s, duration)
		return
	anim_play(n, s, _layer, -INF)

func anim_get_speed(n: Node) -> float:
	var p := _anim_player(n)
	return p.speed_scale if p != null else 1.0

func anim_set_speed(n: Node, v: float) -> void:
	var p := _anim_player(n)
	if p != null:
		p.speed_scale = v

func anim_get_enabled(n: Node) -> bool:
	var t := _anim_tree(n)
	if t != null:
		return t.active
	return n.process_mode != Node.PROCESS_MODE_DISABLED

func anim_set_enabled(n: Node, v: bool) -> void:
	var t := _anim_tree(n)
	if t != null:
		t.active = v
	else:
		n.process_mode = Node.PROCESS_MODE_INHERIT if v else Node.PROCESS_MODE_DISABLED

func anim_controller(n: Node):
	var t := _anim_tree(n)
	return t.tree_root if t != null else null

func anim_set_controller(n: Node, c) -> void:
	var t := _anim_tree(n)
	if t != null and c is AnimationRootNode:
		t.tree_root = c

func anim_layer_count(_n: Node) -> int:
	return 1

func anim_parameter_count(n: Node) -> int:
	return _params(n).size()

func anim_layer_name(_n: Node, _i: int) -> String:
	return "Base Layer"

func anim_layer_index(_n: Node, name_: String) -> int:
	return 0 if name_ == "Base Layer" else -1

func anim_set_layer_weight(n: Node, _i: int, w: float) -> void:
	anim_set(n, "__layer_weight", w)

func anim_get_layer_weight(n: Node, _i: int) -> float:
	return float(anim_get(n, "__layer_weight", 1.0))

func anim_state_info(n: Node, _layer: int, next: bool) -> Dictionary:
	var p := _anim_player(n)
	if p != null and p.current_animation != "":
		var a := p.get_animation(p.current_animation)
		var len_: float = a.length if a != null else 0.0
		var t: float = p.current_animation_position
		return {"name": p.current_animation if not next else "", "normalizedTime": (t / len_) if len_ > 0.0 else 0.0, "length": len_, "speed": p.speed_scale, "loop": a != null and a.loop_mode != Animation.LOOP_NONE}
	var tree := _anim_tree(n)
	if tree != null:
		var sm = tree.get("parameters/playback")
		if sm is AnimationNodeStateMachinePlayback:
			return {"name": String(sm.get_current_node()), "normalizedTime": (sm.get_current_play_position() / sm.get_current_length()) if sm.get_current_length() > 0.0 else 0.0, "length": sm.get_current_length(), "speed": 1.0, "loop": false}
	return {"name": "", "normalizedTime": 0.0, "length": 0.0, "speed": 1.0, "loop": false}

func anim_in_transition(n: Node, _layer: int) -> bool:
	var tree := _anim_tree(n)
	if tree != null:
		var sm = tree.get("parameters/playback")
		if sm is AnimationNodeStateMachinePlayback:
			return sm.get_fading_from_node() != &""
	return false

func anim_bone_transform(n: Node, _bone: int) -> Node3D:
	return n if n is Node3D else null

func animation_current_clip(p: AnimationPlayer) -> Animation:
	return p.get_animation(p.current_animation) if p.current_animation != "" else null

func animation_play(p: AnimationPlayer, name_: String) -> bool:
	if name_ == "":
		if p.current_animation == "" and p.get_animation_list().size() > 0:
			p.play(p.get_animation_list()[0])
		else:
			p.play()
		return true
	if p.has_animation(name_):
		p.play(name_)
		return true
	return false

func blend_shape_get(m: MeshInstance3D, i: int) -> float:
	return m.get_blend_shape_value(i) * 100.0

func blend_shape_set(m: MeshInstance3D, i: int, v: float) -> void:
	m.set_blend_shape_value(i, v / 100.0)

# ---------------------------------------------------------------------------
# Particles
# ---------------------------------------------------------------------------

func _gpu(n: Node) -> GPUParticles3D:
	if n is GPUParticles3D:
		return n
	if n != null:
		for c in n.get_children():
			if c is GPUParticles3D:
				return c
	return null

func ps_play(n: Node, with_children: bool) -> void:
	var p := _gpu(n)
	if p != null:
		p.emitting = true
	if with_children:
		for c in n.get_children():
			if c is GPUParticles3D and c != p:
				c.emitting = true

func ps_stop(n: Node, with_children: bool, behavior: int) -> void:
	var p := _gpu(n)
	if p != null:
		p.emitting = false
		if behavior == 0:
			p.restart()
			p.emitting = false
	if with_children:
		for c in n.get_children():
			if c is GPUParticles3D and c != p:
				c.emitting = false

func ps_pause(n: Node, _with_children: bool) -> void:
	var p := _gpu(n)
	if p != null:
		p.speed_scale = 0.0

func ps_clear(n: Node, _with_children: bool) -> void:
	var p := _gpu(n)
	if p != null:
		var was: bool = p.emitting
		p.restart()
		p.emitting = was

func ps_emit(n: Node, count: int) -> void:
	var p := _gpu(n)
	if p == null:
		return
	for _i in range(count):
		p.emit_particle(p.global_transform, Vector3.ZERO, Color.WHITE, Color.WHITE, GPUParticles3D.EMIT_FLAG_POSITION)

func ps_emit_params(n: Node, params: Dictionary, count: int) -> void:
	var p := _gpu(n)
	if p == null:
		return
	var xf := Transform3D(Basis(), params.get("position", p.global_position))
	var flags: int = GPUParticles3D.EMIT_FLAG_POSITION
	if params.has("velocity"):
		flags |= GPUParticles3D.EMIT_FLAG_VELOCITY
	if params.has("startColor"):
		flags |= GPUParticles3D.EMIT_FLAG_COLOR
	for _i in range(count):
		p.emit_particle(xf, params.get("velocity", Vector3.ZERO), params.get("startColor", Color.WHITE), Color.WHITE, flags)

class PsModule:
	var node: Node
	var kind: String
	var enabled: bool = true
	var data: Dictionary = {}
	func _init(n: Node, k: String) -> void:
		node = n
		kind = k
	func _get(prop: StringName):
		if data.has(prop):
			return data[prop]
		return null
	func _set(prop: StringName, value) -> bool:
		data[prop] = value
		U._ps_apply(node, kind, String(prop), value)
		return true

func ps_module(n: Node, kind: String):
	if n == null:
		return null
	var id: int = n.get_instance_id()
	if not _ps_modules.has(id):
		_ps_modules[id] = {}
	if not _ps_modules[id].has(kind):
		_ps_modules[id][kind] = PsModule.new(n, kind)
	return _ps_modules[id][kind]

func ps_main(n: Node):
	var m = ps_module(n, "main")
	var p := _gpu(n)
	if p != null and m.data.is_empty():
		m.data = {"duration": p.lifetime, "loop": not p.one_shot, "startLifetime": p.lifetime, "startSpeed": 1.0, "startSize": 1.0, "startColor": Color.WHITE, "startRotation": 0.0, "gravityModifier": 1.0, "simulationSpace": 1 if not p.local_coords else 0, "simulationSpeed": p.speed_scale, "maxParticles": p.amount, "playOnAwake": p.emitting}
	return m

func ps_emission(n: Node):
	var m = ps_module(n, "emission")
	var p := _gpu(n)
	if p != null and m.data.is_empty():
		m.data = {"enabled": p.emitting, "rateOverTime": float(p.amount) / maxf(p.lifetime, 0.001), "rateOverDistance": 0.0}
	return m

func _ps_apply(n: Node, kind: String, prop: String, value) -> void:
	var p := _gpu(n)
	if p == null:
		return
	match [kind, prop]:
		["main", "duration"], ["main", "startLifetime"]:
			p.lifetime = maxf(float(value), 0.01)
		["main", "loop"]:
			p.one_shot = not bool(value)
		["main", "simulationSpeed"]:
			p.speed_scale = float(value)
		["main", "maxParticles"]:
			p.amount = maxi(int(value), 1)
		["main", "simulationSpace"]:
			p.local_coords = int(value) == 0
		["main", "startColor"]:
			if p.process_material is ParticleProcessMaterial:
				p.process_material.color = value
		["main", "startSpeed"]:
			if p.process_material is ParticleProcessMaterial:
				p.process_material.initial_velocity_min = float(value)
				p.process_material.initial_velocity_max = float(value)
		["main", "startSize"]:
			if p.process_material is ParticleProcessMaterial:
				p.process_material.scale_min = float(value)
				p.process_material.scale_max = float(value)
		["main", "gravityModifier"]:
			if p.process_material is ParticleProcessMaterial:
				p.process_material.gravity = gravity() * float(value)
		["emission", "enabled"]:
			p.emitting = bool(value)
		["emission", "rateOverTime"]:
			p.amount = maxi(int(float(value) * p.lifetime), 1)
		["shape", "radius"]:
			if p.process_material is ParticleProcessMaterial:
				p.process_material.emission_sphere_radius = float(value)
		_:
			pass

func ps_material(n: Node) -> Material:
	var p := _gpu(n)
	return p.material_override if p != null else null

func ps_set_material(n: Node, m: Material) -> void:
	var p := _gpu(n)
	if p != null:
		p.material_override = m

# ---------------------------------------------------------------------------
# Renderer / Material
# ---------------------------------------------------------------------------

func _geom(n: Node) -> GeometryInstance3D:
	if n is GeometryInstance3D:
		return n
	if n != null:
		for c in n.get_children():
			if c is GeometryInstance3D:
				return c
	return null

func renderer_shared_material(n: Node) -> Material:
	var g := _geom(n)
	if g == null:
		return null
	if g.material_override != null:
		return g.material_override
	if g is MeshInstance3D:
		var m: Material = g.get_surface_override_material(0)
		if m == null and g.mesh != null and g.mesh.get_surface_count() > 0:
			m = g.mesh.surface_get_material(0)
		return m
	return null

## Unity `renderer.material` returns a per-instance copy; emulate by duplicating once.
func renderer_material(n: Node) -> Material:
	var g := _geom(n)
	if g == null:
		return null
	if g.has_meta("udon_instanced_material"):
		return g.get_meta("udon_instanced_material")
	var m := renderer_shared_material(n)
	if m == null:
		m = StandardMaterial3D.new()
	else:
		m = m.duplicate()
	g.material_override = m
	g.set_meta("udon_instanced_material", m)
	return m

func renderer_set_material(n: Node, m: Material) -> void:
	var g := _geom(n)
	if g != null:
		g.material_override = m
		g.set_meta("udon_instanced_material", m)

func renderer_materials(n: Node) -> Array:
	var g := _geom(n)
	var out: Array = []
	if g is MeshInstance3D and g.mesh != null:
		for i in range(g.mesh.get_surface_count()):
			var m: Material = g.get_surface_override_material(i)
			out.append(m if m != null else g.mesh.surface_get_material(i))
	elif g != null:
		out.append(renderer_shared_material(n))
	return out

func renderer_set_materials(n: Node, mats: Array) -> void:
	var g := _geom(n)
	if g is MeshInstance3D:
		for i in range(mini(mats.size(), g.get_surface_override_material_count())):
			g.set_surface_override_material(i, mats[i])

func renderer_bounds(n: Node) -> AABB:
	var g := _geom(n)
	return g.global_transform * g.get_aabb() if g != null else AABB()

func renderer_set_property_block(n: Node, block: Dictionary) -> void:
	var g := _geom(n)
	if g == null:
		return
	for k in block.keys():
		g.set_instance_shader_parameter(_shader_param_name(k), block[k])
	var m := renderer_material(n)
	for k in block.keys():
		mat_set(m, k, block[k])

func renderer_get_property_block(n: Node, block: Dictionary) -> void:
	var g := _geom(n)
	if g == null:
		return
	for k in block.keys():
		var v = g.get_instance_shader_parameter(_shader_param_name(k))
		if v != null:
			block[k] = v

func _shader_param_name(k) -> String:
	var s: String = str(k)
	return s.trim_prefix("_")

func new_material(_shader) -> Material:
	if _shader is Shader:
		var sm := ShaderMaterial.new()
		sm.shader = _shader
		return sm
	return StandardMaterial3D.new()

## Map common Unity material properties onto StandardMaterial3D / ShaderMaterial.
func mat_set(m: Material, key, value) -> void:
	if m == null:
		return
	var k: String = str(key)
	if m is ShaderMaterial:
		m.set_shader_parameter(_shader_param_name(k), value)
		return
	if m is BaseMaterial3D:
		match k:
			"_Color", "_BaseColor", "color":
				m.albedo_color = value
			"_MainTex", "_BaseMap":
				m.albedo_texture = value
			"_EmissionColor":
				m.emission_enabled = true
				m.emission = value
			"_Metallic":
				m.metallic = float(value)
			"_Glossiness", "_Smoothness":
				m.roughness = 1.0 - float(value)
			"_BumpMap", "_NormalMap":
				m.normal_enabled = value != null
				m.normal_texture = value
			"_MainTex_Offset":
				m.uv1_offset = Vector3(value.x, value.y, 0.0)
			"_MainTex_Scale":
				m.uv1_scale = Vector3(value.x, value.y, 1.0)
			_:
				m.set_meta("udon_" + _shader_param_name(k), value)

func mat_get(m: Material, key, default):
	if m == null:
		return default
	var k: String = str(key)
	if m is ShaderMaterial:
		var v = m.get_shader_parameter(_shader_param_name(k))
		return v if v != null else default
	if m is BaseMaterial3D:
		match k:
			"_Color", "_BaseColor", "color":
				return m.albedo_color
			"_MainTex", "_BaseMap":
				return m.albedo_texture
			"_EmissionColor":
				return m.emission
			"_Metallic":
				return m.metallic
			"_Glossiness", "_Smoothness":
				return 1.0 - m.roughness
			"_MainTex_Offset":
				return Vector2(m.uv1_offset.x, m.uv1_offset.y)
			"_MainTex_Scale":
				return Vector2(m.uv1_scale.x, m.uv1_scale.y)
			_:
				return m.get_meta("udon_" + _shader_param_name(k), default)
	return default

func mat_has(m: Material, key) -> bool:
	var k: String = str(key)
	if m is ShaderMaterial:
		return m.get_shader_parameter(_shader_param_name(k)) != null
	return k in ["_Color", "_BaseColor", "_MainTex", "_EmissionColor", "_Metallic", "_Glossiness", "_Smoothness"] or m.has_meta("udon_" + _shader_param_name(k))

func mat_copy(dst: Material, src: Material) -> void:
	if dst is BaseMaterial3D and src is BaseMaterial3D:
		dst.albedo_color = src.albedo_color
		dst.albedo_texture = src.albedo_texture
		dst.emission = src.emission
		dst.emission_enabled = src.emission_enabled

func new_texture(w: int, h: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	return ImageTexture.create_from_image(img)

func texture_get_pixel(t: Texture2D, x: int, y: int) -> Color:
	var img := t.get_image()
	if img == null:
		return Color.BLACK
	return img.get_pixel(clampi(x, 0, img.get_width() - 1), clampi(img.get_height() - 1 - y, 0, img.get_height() - 1))

func texture_set_pixel(t: Texture2D, x: int, y: int, c: Color) -> void:
	var img := t.get_image()
	if img != null:
		img.set_pixel(x, img.get_height() - 1 - y, c)
		t.set_meta("udon_img", img)

func texture_set_pixels(t: Texture2D, colors: Array) -> void:
	var img := t.get_image()
	if img == null:
		return
	var w: int = img.get_width()
	for i in range(mini(colors.size(), w * img.get_height())):
		img.set_pixel(i % w, img.get_height() - 1 - (i / w), colors[i])
	t.set_meta("udon_img", img)

func texture_get_pixels(t: Texture2D) -> Array:
	var out: Array = []
	var img := t.get_image()
	if img == null:
		return out
	for y in range(img.get_height() - 1, -1, -1):
		for x in range(img.get_width()):
			out.append(img.get_pixel(x, y))
	return out

func texture_apply(t: Texture2D) -> void:
	if t is ImageTexture and t.has_meta("udon_img"):
		t.update(t.get_meta("udon_img"))

func white_texture() -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)

func black_texture() -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	return ImageTexture.create_from_image(img)

func new_render_texture(_w: int, _h: int):
	return null

func mesh_vertex_count(m: Mesh) -> int:
	return mesh_vertices(m).size()

func mesh_vertices(m: Mesh) -> Array:
	if m == null or m.get_surface_count() == 0:
		return []
	return Array(m.surface_get_arrays(0)[Mesh.ARRAY_VERTEX])

func mesh_normals(m: Mesh) -> Array:
	if m == null or m.get_surface_count() == 0:
		return []
	var n = m.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
	return Array(n) if n != null else []

func mesh_triangles(m: Mesh) -> Array:
	if m == null or m.get_surface_count() == 0:
		return []
	var idx = m.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	return Array(idx) if idx != null else []

# ---------------------------------------------------------------------------
# Light / camera
# ---------------------------------------------------------------------------

func light_get_range(l: Light3D) -> float:
	if l is OmniLight3D:
		return l.omni_range
	if l is SpotLight3D:
		return l.spot_range
	return INF

func light_set_range(l: Light3D, r: float) -> void:
	if l is OmniLight3D:
		l.omni_range = r
	elif l is SpotLight3D:
		l.spot_range = r

func light_get_spot_angle(l: Light3D) -> float:
	return l.spot_angle * 2.0 if l is SpotLight3D else 30.0

func light_set_spot_angle(l: Light3D, a: float) -> void:
	if l is SpotLight3D:
		l.spot_angle = a / 2.0

func light_type(l: Light3D) -> int:
	if l is SpotLight3D:
		return 0
	if l is DirectionalLight3D:
		return 1
	return 2

func main_camera() -> Camera3D:
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null

func camera_aspect(c: Camera3D) -> float:
	var s: Vector2 = c.get_viewport().get_visible_rect().size
	return s.x / maxf(s.y, 1.0)

func camera_set_enabled(c: Camera3D, v: bool) -> void:
	if v:
		c.make_current()
	elif c.current:
		c.clear_current()

func camera_get_bg(c: Camera3D) -> Color:
	if c.environment != null:
		return c.environment.background_color
	return Color.BLACK

func camera_set_bg(c: Camera3D, col: Color) -> void:
	if c.environment == null:
		c.environment = Environment.new()
		c.environment.background_mode = Environment.BG_COLOR
	c.environment.background_color = col

func camera_set_target_texture(_c: Camera3D, _t) -> void:
	pass

func camera_pixel_size(c: Camera3D) -> Vector2i:
	return Vector2i(c.get_viewport().get_visible_rect().size)

func screen_size() -> Vector2i:
	var vp := get_viewport()
	return Vector2i(vp.get_visible_rect().size) if vp != null else Vector2i(1920, 1080)

func world_to_screen(c: Camera3D, p: Vector3) -> Vector3:
	var s: Vector2 = c.unproject_position(p)
	var h: float = c.get_viewport().get_visible_rect().size.y
	var depth: float = (c.global_transform.affine_inverse() * p).z * -1.0
	return Vector3(s.x, h - s.y, depth)

func world_to_viewport(c: Camera3D, p: Vector3) -> Vector3:
	var s: Vector3 = world_to_screen(c, p)
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return Vector3(s.x / size.x, s.y / size.y, s.z)

func screen_to_world(c: Camera3D, p: Vector3) -> Vector3:
	var h: float = c.get_viewport().get_visible_rect().size.y
	return c.project_position(Vector2(p.x, h - p.y), p.z)

func viewport_to_world(c: Camera3D, p: Vector3) -> Vector3:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return screen_to_world(c, Vector3(p.x * size.x, p.y * size.y, p.z))

func screen_point_to_ray(c: Camera3D, p: Vector3) -> Dictionary:
	var h: float = c.get_viewport().get_visible_rect().size.y
	var sp := Vector2(p.x, h - p.y)
	return {"origin": c.project_ray_origin(sp), "direction": c.project_ray_normal(sp)}

func viewport_point_to_ray(c: Camera3D, p: Vector3) -> Dictionary:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return screen_point_to_ray(c, Vector3(p.x * size.x, p.y * size.y, 0.0))

func debug_draw_line(_a: Vector3, _b: Vector3, _c: Color, _dur: float) -> void:
	pass

# ---------------------------------------------------------------------------
# LineRenderer / TrailRenderer emulation (positions stored; drawn with an ImmediateMesh)
# ---------------------------------------------------------------------------

func _line(n: Node) -> Dictionary:
	var id: int = n.get_instance_id()
	if not _line_data.has(id):
		_line_data[id] = {"positions": [], "props": {}}
	return _line_data[id]

func line_get_count(n: Node) -> int:
	return _line(n)["positions"].size()

func line_set_count(n: Node, c: int) -> void:
	_line(n)["positions"].resize(maxi(c, 0))
	_line_redraw(n)

func line_set_position(n: Node, i: int, p: Vector3) -> void:
	var d := _line(n)
	if i >= d["positions"].size():
		d["positions"].resize(i + 1)
	d["positions"][i] = p
	_line_redraw(n)

func line_get_position(n: Node, i: int) -> Vector3:
	var d := _line(n)
	return d["positions"][i] if i < d["positions"].size() and d["positions"][i] != null else Vector3.ZERO

func line_set_positions(n: Node, arr: Array) -> void:
	_line(n)["positions"] = arr.duplicate()
	_line_redraw(n)

func line_get_positions(n: Node, into: Array) -> int:
	var d := _line(n)
	var c: int = mini(into.size(), d["positions"].size())
	for i in range(c):
		into[i] = d["positions"][i]
	return c

func line_get_prop(n: Node, key: String, default):
	return _line(n)["props"].get(key, default)

func line_set_prop(n: Node, key: String, value) -> void:
	_line(n)["props"][key] = value
	_line_redraw(n)

func line_clear(n: Node) -> void:
	_line(n)["positions"].clear()
	_line_redraw(n)

func _line_redraw(n: Node) -> void:
	if not (n is Node3D):
		return
	var d := _line(n)
	var mi: MeshInstance3D = n.get_node_or_null("_udon_line")
	if mi == null:
		mi = MeshInstance3D.new()
		mi.name = "_udon_line"
		mi.mesh = ImmediateMesh.new()
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mi.material_override = mat
		n.add_child(mi)
		mi.top_level = true
		mi.global_transform = Transform3D()
	var im: ImmediateMesh = mi.mesh
	im.clear_surfaces()
	var pts: Array = d["positions"]
	var set_pts: int = 0
	for p0 in pts:
		if p0 != null:
			set_pts += 1
	if set_pts < 2:
		return
	var world: bool = d["props"].get("useWorldSpace", true)
	var c0: Color = d["props"].get("startColor", Color.WHITE)
	var c1: Color = d["props"].get("endColor", c0)
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for i in range(pts.size()):
		var p = pts[i]
		if p == null:
			continue
		if not world:
			p = n.global_transform * p
		im.surface_set_color(c0.lerp(c1, float(i) / maxf(pts.size() - 1, 1.0)))
		im.surface_add_vertex(p)
	im.surface_end()

# ---------------------------------------------------------------------------
# UI helpers (Control-based)
# ---------------------------------------------------------------------------

func ui_get_text(n: Node) -> String:
	if n == null:
		return ""
	var t = n.get("text")
	return str(t) if t != null else ""

func ui_set_text(n: Node, s: String) -> void:
	if n != null and n.get("text") != null:
		n.set("text", s)

func ui_get_color(n: Node) -> Color:
	if n is Label3D:
		return n.modulate
	if n is Control:
		var c = n.get_theme_color("font_color") if n.has_theme_color("font_color") else null
		return c if c != null else n.modulate
	return Color.WHITE

func ui_set_color(n: Node, c: Color) -> void:
	if n is Label or n is RichTextLabel:
		n.add_theme_color_override("font_color", c)
	elif n is Label3D or n is CanvasItem:
		n.modulate = c

func ui_get_font_size(n: Node) -> int:
	if n is Label3D:
		return n.font_size
	if n is Control and n.has_theme_font_size("font_size"):
		return n.get_theme_font_size("font_size")
	return 16

func ui_set_font_size(n: Node, s: int) -> void:
	if n is Label3D:
		n.font_size = s
	elif n is Control:
		n.add_theme_font_size_override("font_size", s)

func ui_set_visible_characters(n: Node, c: int) -> void:
	if n.get("visible_characters") != null:
		n.set("visible_characters", c)

func ui_text_info(n: Node) -> Dictionary:
	var t: String = ui_get_text(n)
	return {"characterCount": t.length(), "lineCount": t.split("\n").size()}

func ui_fade_alpha(n: CanvasItem, alpha: float, duration: float) -> void:
	var tw := n.create_tween()
	tw.tween_property(n, "modulate:a", alpha, duration)

func ui_get_texture(n: Node):
	return n.get("texture")

func ui_set_texture(n: Node, t) -> void:
	if n.get("texture") != null or n is TextureRect:
		n.set("texture", t)

func ui_get_fill(n: Node) -> float:
	if n is TextureProgressBar:
		return n.ratio
	if n is Range:
		return n.ratio
	return n.get_meta("udon_fill", 1.0)

func ui_set_fill(n: Node, v: float) -> void:
	if n is TextureProgressBar or n is Range:
		n.ratio = v
	else:
		n.set_meta("udon_fill", v)
		if n is Control:
			n.scale.x = v

func ui_get_interactable(n: Node) -> bool:
	if n.get("disabled") != null:
		return not n.disabled
	if n.get("editable") != null:
		return n.editable
	return true

func ui_set_interactable(n: Node, v: bool) -> void:
	if n.get("disabled") != null:
		n.disabled = not v
	elif n.get("editable") != null:
		n.editable = v

func scroll_get_v(s: ScrollContainer) -> float:
	var bar := s.get_v_scroll_bar()
	var range_: float = bar.max_value - bar.page
	return 1.0 - (bar.value / range_ if range_ > 0.0 else 0.0)

func scroll_set_v(s: ScrollContainer, v: float) -> void:
	var bar := s.get_v_scroll_bar()
	bar.value = (1.0 - v) * (bar.max_value - bar.page)

func scroll_get_h(s: ScrollContainer) -> float:
	var bar := s.get_h_scroll_bar()
	var range_: float = bar.max_value - bar.page
	return bar.value / range_ if range_ > 0.0 else 0.0

func scroll_set_h(s: ScrollContainer, v: float) -> void:
	var bar := s.get_h_scroll_bar()
	bar.value = v * (bar.max_value - bar.page)

func scroll_content(s: ScrollContainer) -> Control:
	return s.get_child(0) if s.get_child_count() > 0 else null

func rect_get_pivot(c: Control) -> Vector2:
	return c.pivot_offset / c.size if c.size.x > 0.0 and c.size.y > 0.0 else Vector2(0.5, 0.5)

func rect_set_pivot(c: Control, p: Vector2) -> void:
	c.pivot_offset = p * c.size

func rect_set_anchor_min(c: Control, v: Vector2) -> void:
	c.anchor_left = v.x
	c.anchor_top = 1.0 - v.y

func rect_set_anchor_max(c: Control, v: Vector2) -> void:
	c.anchor_right = v.x
	c.anchor_bottom = 1.0 - v.y

func rect_set_offset_min(c: Control, v: Vector2) -> void:
	c.offset_left = v.x
	c.offset_bottom = -v.y

func rect_set_offset_max(c: Control, v: Vector2) -> void:
	c.offset_right = v.x
	c.offset_top = -v.y

func rect_set_size_axis(c: Control, axis: int, size: float) -> void:
	if axis == 0:
		c.size.x = size
	else:
		c.size.y = size

func rect_world_corners(c: Control, into: Array) -> void:
	var r: Rect2 = c.get_global_rect()
	var corners: Array = [Vector3(r.position.x, r.end.y, 0.0), Vector3(r.position.x, r.position.y, 0.0), Vector3(r.end.x, r.position.y, 0.0), Vector3(r.end.x, r.end.y, 0.0)]
	for i in range(mini(4, into.size())):
		into[i] = corners[i]

func app_is_focused() -> bool:
	return DisplayServer.window_is_focused()

func app_platform() -> int:
	match OS.get_name():
		"Windows":
			return 2
		"macOS":
			return 1
		"Linux":
			return 13
		"Android":
			return 11
		"iOS":
			return 8
		"Web":
			return 17
		_:
			return 2

func app_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "1.0"))

# ---------------------------------------------------------------------------
# Strings & formatting
# ---------------------------------------------------------------------------

func bool_str(b: bool) -> String:
	return "True" if b else "False"

## Color.h/s/v are computed properties the sandbox cannot read on a Color value; do it host-side.
func color_hsv(c: Color) -> Array:
	return [c.h, c.s, c.v]

## Unity sliders are continuous unless wholeNumbers is set; Godot's default step of 1 would snap.
func slider_set_value(s, v: float) -> void:
	if s is Range:
		if s is Slider and s.step == 1.0 and not s.rounded:
			s.step = 0.0
		s.value = v

## C# float.ToString(): shortest round-trip, no trailing ".0".
func float_str(f: float) -> String:
	if is_nan(f):
		return "NaN"
	if is_inf(f):
		return "∞" if f > 0.0 else "-∞"
	if f == floorf(f) and absf(f) < 1e15:
		return str(int(f))
	# shortest decimal that round-trips through float32 (Godot's "%g" is unsupported)
	var f32: float = _f32(f)
	var e: int = int(floor(log(absf(f)) / log(10.0)))
	for sig in range(1, 10):
		var s: String = String.num(f, maxi(0, sig - 1 - e))
		if _f32(float(s)) == f32:
			return _trim_float(s)
	return _trim_float(String.num(f, 9))

func _f32(f: float) -> float:
	var p: PackedFloat32Array = PackedFloat32Array([f])
	return p[0]

func _trim_float(s: String) -> String:
	if s.contains(".") and not s.contains("e"):
		s = s.rstrip("0").rstrip(".")
	if s == "" or s == "-":
		s = "0"
	return s

## Fixed-point with .NET rounding (half away from zero; printf rounds half to even).
func _fixed(f: float, d: int) -> String:
	var scale: float = pow(10.0, d)
	var r: float = floor(absf(f) * scale + 0.5) / scale
	return ("-" if f < 0.0 and r != 0.0 else "") + ("%.*f" % [d, r])

## .NET "E" format: d.dddE+xxx
func _sci(f: float, d: int, upper: bool) -> String:
	var ex: String = "E" if upper else "e"
	if f == 0.0:
		return ("0." + "0".repeat(d) if d > 0 else "0") + ex + "+000"
	var e: int = int(floor(log(absf(f)) / log(10.0)))
	var ms: String = _fixed(f / pow(10.0, e), d)
	if absf(float(ms)) >= 10.0:
		e += 1
		ms = _fixed(f / pow(10.0, e), d)
	return ms + ex + ("+" if e >= 0 else "-") + str(absi(e)).pad_zeros(3)

func vec3_str(v: Vector3, fmt: String = "F2") -> String:
	return "(%s, %s, %s)" % [format_num(v.x, fmt), format_num(v.y, fmt), format_num(v.z, fmt)]

func vec2_str(v: Vector2, fmt: String = "F2") -> String:
	return "(%s, %s)" % [format_num(v.x, fmt), format_num(v.y, fmt)]

## .NET numeric format strings: F0..F9, N0..N9, D2, X, X4, 0.00, 0.#, P0, E2, C
func format_num(v, fmt: String) -> String:
	if fmt == null or fmt == "":
		return float_str(v) if typeof(v) == TYPE_FLOAT else str(v)
	if typeof(v) == TYPE_BOOL:
		return bool_str(v)
	if typeof(v) != TYPE_INT and typeof(v) != TYPE_FLOAT:
		return str(v)
	var f: float = float(v)
	var spec: String = fmt.substr(0, 1).to_upper()
	var digits_s: String = fmt.substr(1)
	var digits: int = int(digits_s) if digits_s.is_valid_int() else -1
	match spec:
		"F":
			return _fixed(f, digits if digits >= 0 else 2)
		"N":
			var d: int = digits if digits >= 0 else 2
			var s: String = _fixed(absf(f), d)
			var parts: PackedStringArray = s.split(".")
			var ip: String = parts[0]
			var out: String = ""
			var cnt: int = 0
			for i in range(ip.length() - 1, -1, -1):
				out = ip[i] + out
				cnt += 1
				if cnt % 3 == 0 and i > 0:
					out = "," + out
			if parts.size() > 1:
				out += "." + parts[1]
			return ("-" if f < 0.0 else "") + out
		"D":
			var iv: int = int(v)
			var s2: String = str(absi(iv))
			if digits > 0:
				s2 = s2.pad_zeros(digits)
			return ("-" if iv < 0 else "") + s2
		"X":
			var hex: String = ("%x" % int(v)).to_upper() if fmt.substr(0, 1) == "X" else ("%x" % int(v))
			while hex.length() < digits:
				hex = "0" + hex
			return hex
		"P":
			return _fixed(f * 100.0, digits if digits >= 0 else 2) + " %"
		"E":
			return _sci(f, digits if digits >= 0 else 6, fmt.substr(0, 1) == "E")
		"C":
			return "$" + format_num(f, "N" + (str(digits) if digits >= 0 else "2"))
		"G", "R":
			return float_str(f)
		_:
			pass
	# custom patterns: 0.00, #.##, 0.#
	if fmt.contains("0") or fmt.contains("#"):
		var dot: int = fmt.find(".")
		var int_part: String = fmt if dot < 0 else fmt.substr(0, dot)
		var frac_part: String = "" if dot < 0 else fmt.substr(dot + 1)
		var min_frac: int = frac_part.count("0")
		var max_frac: int = frac_part.length()
		var s3: String = _fixed(f, max_frac)
		if max_frac > min_frac and s3.contains("."):
			s3 = s3.rstrip("0")
			if s3.ends_with("."):
				s3 = s3.substr(0, s3.length() - 1)
		var min_int: int = int_part.count("0")
		var parts2: PackedStringArray = s3.split(".")
		var neg: bool = parts2[0].begins_with("-")
		var ip2: String = parts2[0].trim_prefix("-")
		if ip2.length() < min_int:
			ip2 = ip2.pad_zeros(min_int)
		if int_part.contains(","):
			var out2: String = ""
			var cnt2: int = 0
			for i in range(ip2.length() - 1, -1, -1):
				out2 = ip2[i] + out2
				cnt2 += 1
				if cnt2 % 3 == 0 and i > 0:
					out2 = "," + out2
			ip2 = out2
		var res: String = ("-" if neg else "") + ip2
		if parts2.size() > 1 and parts2[1] != "":
			res += "." + parts2[1]
		return res
	return str(v)

## string.Format / interpolation holes: {0}, {1:F2}, {0,5}
func format(fmt: String, args: Array) -> String:
	var out: String = ""
	var i: int = 0
	while i < fmt.length():
		var c: String = fmt[i]
		if c == "{":
			if i + 1 < fmt.length() and fmt[i + 1] == "{":
				out += "{"
				i += 2
				continue
			var close: int = fmt.find("}", i)
			if close < 0:
				out += fmt.substr(i)
				break
			var spec: String = fmt.substr(i + 1, close - i - 1)
			var idx_s: String = spec
			var f: String = ""
			var align: int = 0
			var colon: int = spec.find(":")
			if colon >= 0:
				idx_s = spec.substr(0, colon)
				f = spec.substr(colon + 1)
			var comma: int = idx_s.find(",")
			if comma >= 0:
				align = int(idx_s.substr(comma + 1))
				idx_s = idx_s.substr(0, comma)
			var idx: int = int(idx_s)
			var val = args[idx] if idx < args.size() else ""
			var s: String = format_num(val, f) if f != "" else _to_str(val)
			if align > 0:
				s = s.lpad(align)
			elif align < 0:
				s = s.rpad(-align)
			out += s
			i = close + 1
		elif c == "}" and i + 1 < fmt.length() and fmt[i + 1] == "}":
			out += "}"
			i += 2
		else:
			out += c
			i += 1
	return out

func _to_str(v) -> String:
	match typeof(v):
		TYPE_FLOAT:
			return float_str(v)
		TYPE_BOOL:
			return bool_str(v)
		TYPE_VECTOR3:
			return vec3_str(v)
		TYPE_VECTOR2:
			return vec2_str(v)
		_:
			return str(v)

func concat(parts: Array) -> String:
	var out: String = ""
	for p in parts:
		out += _to_str(p)
	return out

func join(sep: String, parts: Array) -> String:
	var strs: PackedStringArray = []
	for p in parts:
		strs.append(_to_str(p))
	return sep.join(strs)

func is_null_or_empty(s) -> bool:
	return s == null or str(s) == ""

func is_null_or_whitespace(s) -> bool:
	return s == null or str(s).strip_edges() == ""

func str_compare(a: String, b: String, ignore_case: bool = false) -> int:
	if ignore_case:
		return a.nocasecmp_to(b)
	return a.casecmp_to(b)

func str_equals(a: String, b: String, comparison: int) -> bool:
	if comparison == 1 or comparison == 3 or comparison == 5:
		return a.nocasecmp_to(b) == 0
	return a == b

func str_split(s: String, sep: String, options: int) -> Array:
	var out: Array = Array(s.split(sep, options & 1 == 0))
	if options & 2:
		for i in range(out.size()):
			out[i] = out[i].strip_edges()
	return out

func str_split_any(s: String, seps: Array, options: int = 0) -> Array:
	var out: Array = []
	var cur: String = ""
	for ch in s:
		if seps.has(ch):
			out.append(cur)
			cur = ""
		else:
			cur += ch
	out.append(cur)
	if options & 1:
		out = out.filter(func(x): return x != "")
	return out

func str_trim_chars(s: String, chars: Array, start: bool = true, end: bool = true) -> String:
	var cs: String = "".join(chars)
	if start and end:
		return s.strip_edges() if cs == "" else s.lstrip(cs).rstrip(cs)
	if start:
		return s.lstrip(cs)
	return s.rstrip(cs)

func pad_left(s: String, width: int, pad: String) -> String:
	while s.length() < width:
		s = pad + s
	return s

func pad_right(s: String, width: int, pad: String) -> String:
	while s.length() < width:
		s = s + pad
	return s

func to_char_array(s: String) -> Array:
	var out: Array = []
	for ch in s:
		out.append(ch)
	return out

func char_is_digit(c: String) -> bool:
	return c.length() > 0 and c.unicode_at(0) >= 48 and c.unicode_at(0) <= 57

func char_is_letter(c: String) -> bool:
	if c.length() == 0:
		return false
	var u: int = c.unicode_at(0)
	return (u >= 65 and u <= 90) or (u >= 97 and u <= 122) or u > 127 and c.to_upper() != c.to_lower()

func char_is_letter_or_digit(c: String) -> bool:
	return char_is_digit(c) or char_is_letter(c)

func char_is_whitespace(c: String) -> bool:
	return c.length() > 0 and c.strip_edges() == ""

func char_is_punctuation(c: String) -> bool:
	return c.length() > 0 and "!\"#%&'()*,-./:;?@[\\]_{}".contains(c)

func parse_base(s: String, base: int) -> int:
	if base == 16:
		return s.hex_to_int()
	if base == 2:
		return s.bin_to_int()
	return s.to_int()

func to_base(v: int, base: int) -> String:
	match base:
		16:
			return "%x" % v
		2:
			var out: String = ""
			var n: int = v
			if n == 0:
				return "0"
			while n > 0:
				out = str(n & 1) + out
				n >>= 1
			return out
		8:
			return "%o" % v
		_:
			return str(v)

func new_guid() -> String:
	var b := PackedByteArray()
	for _i in range(16):
		b.append(randi() & 255)
	return b.hex_encode()

func bytes_to_int32(bytes: Array, offset: int) -> int:
	return PackedByteArray(bytes).decode_s32(offset)

func bytes_to_float(bytes: Array, offset: int) -> float:
	return PackedByteArray(bytes).decode_float(offset)

func int32_to_bytes(v: int) -> Array:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, v)
	return Array(b)

func float_to_bytes(v: float) -> Array:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return Array(b)

func float_to_bits(v: float) -> int:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_float(0, v)
	return b.decode_s32(0)

func bits_to_float(v: int) -> float:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_s32(0, v)
	return b.decode_float(0)

# ---------------------------------------------------------------------------
# Arrays
# ---------------------------------------------------------------------------

func new_array(n: int, default) -> Array:
	var a: Array = []
	a.resize(maxi(n, 0))
	if default != null:
		a.fill(default)
	return a

func new_array_nd(dims: Array, default) -> Array:
	if dims.is_empty():
		return []
	var n: int = int(dims[0])
	if dims.size() == 1:
		return new_array(n, default)
	var a: Array = []
	a.resize(maxi(n, 0))
	for i in range(a.size()):
		a[i] = new_array_nd(dims.slice(1), default)
	return a

func array_rank(a: Array) -> int:
	var r: int = 1
	var cur = a
	while cur is Array and cur.size() > 0 and cur[0] is Array:
		r += 1
		cur = cur[0]
	return r

func array_get_length(a: Array, dim: int) -> int:
	var cur = a
	for _i in range(dim):
		if cur is Array and cur.size() > 0:
			cur = cur[0]
		else:
			return 0
	return cur.size() if cur is Array else 0

func array_copy(src: Array, si: int, dst: Array, di: int, n: int) -> void:
	for i in range(n):
		if si + i < src.size() and di + i < dst.size():
			dst[di + i] = src[si + i]

func array_clear(a: Array, i: int, n: int) -> void:
	for k in range(i, mini(i + n, a.size())):
		a[k] = null if not (a[k] is int or a[k] is float or a[k] is bool) else (0 if a[k] is int else (0.0 if a[k] is float else false))

func array_resized(a, n: int) -> Array:
	var out: Array = a.duplicate() if a != null else []
	out.resize(n)
	return out

func array_reverse_range(a: Array, i: int, n: int) -> void:
	var s: Array = a.slice(i, i + n)
	s.reverse()
	for k in range(s.size()):
		a[i + k] = s[k]

func array_sort_range(a: Array, i: int, n: int) -> void:
	var s: Array = a.slice(i, i + n)
	s.sort()
	for k in range(s.size()):
		a[i + k] = s[k]

func array_remove(a: Array, v) -> bool:
	var i: int = a.find(v)
	if i < 0:
		return false
	a.remove_at(i)
	return true

func array_remove_all(a: Array, v) -> int:
	var c: int = 0
	while a.has(v):
		a.erase(v)
		c += 1
	return c

func array_remove_range(a: Array, i: int, n: int) -> void:
	for _k in range(n):
		if i < a.size():
			a.remove_at(i)

func array_insert_range(a: Array, i: int, items: Array) -> void:
	for k in range(items.size()):
		a.insert(i + k, items[k])

# ---------------------------------------------------------------------------
# Data containers (VRC DataToken)
# ---------------------------------------------------------------------------

func token_type(v) -> int:
	match typeof(v):
		TYPE_NIL:
			return 0
		TYPE_BOOL:
			return 1
		TYPE_INT:
			return 6
		TYPE_FLOAT:
			return 11
		TYPE_STRING, TYPE_STRING_NAME:
			return 12
		TYPE_ARRAY:
			return 13
		TYPE_DICTIONARY:
			return 16 if v.has("error") and v.size() == 1 else 14
		_:
			return 15

func token_error(v) -> int:
	if v is Dictionary and v.has("error"):
		return int(v["error"])
	return 0

func json_parse(s: String):
	var j := JSON.new()
	if j.parse(s) != OK:
		return null
	return j.data

# ---------------------------------------------------------------------------
# Date / time
# ---------------------------------------------------------------------------

func datetime_now(utc: bool) -> Dictionary:
	var d: Dictionary = Time.get_datetime_dict_from_system(utc)
	var unix: float = Time.get_unix_time_from_system()
	d["unix"] = unix
	d["millisecond"] = int(fmod(unix, 1.0) * 1000.0)
	d["ticks"] = int(unix * 10000000.0) + 621355968000000000
	d["dayofyear"] = 1
	return d

func datetime_today() -> Dictionary:
	var d := datetime_now(false)
	d["hour"] = 0
	d["minute"] = 0
	d["second"] = 0
	d["millisecond"] = 0
	return d

func datetime_from_unix(unix: float) -> Dictionary:
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(int(unix))
	d["unix"] = unix
	d["millisecond"] = int(fmod(unix, 1.0) * 1000.0)
	d["ticks"] = int(unix * 10000000.0) + 621355968000000000
	d["dayofyear"] = 1
	return d

func datetime_date(d: Dictionary) -> Dictionary:
	var out := d.duplicate()
	out["hour"] = 0
	out["minute"] = 0
	out["second"] = 0
	return out

func datetime_add_seconds(d: Dictionary, s: float) -> Dictionary:
	return datetime_from_unix(float(d.get("unix", 0.0)) + s)

func datetime_diff(a: Dictionary, b: Dictionary) -> Dictionary:
	return timespan_from_seconds(float(a.get("unix", 0.0)) - float(b.get("unix", 0.0)))

func datetime_format(d: Dictionary, fmt: String) -> String:
	if fmt == "":
		return "%04d-%02d-%02d %02d:%02d:%02d" % [d.get("year", 0), d.get("month", 0), d.get("day", 0), d.get("hour", 0), d.get("minute", 0), d.get("second", 0)]
	var out: String = fmt
	out = out.replace("yyyy", "%04d" % d.get("year", 0)).replace("MM", "%02d" % d.get("month", 0)).replace("dd", "%02d" % d.get("day", 0))
	out = out.replace("HH", "%02d" % d.get("hour", 0)).replace("mm", "%02d" % d.get("minute", 0)).replace("ss", "%02d" % d.get("second", 0))
	out = out.replace("fff", "%03d" % d.get("millisecond", 0))
	return out

func timespan_from_seconds(s: float) -> Dictionary:
	return {"total_seconds": s}

func timespan_format(t: Dictionary, _fmt: String) -> String:
	var s: float = float(t.get("total_seconds", 0.0))
	var neg: bool = s < 0.0
	s = absf(s)
	var h: int = int(s / 3600.0)
	var m: int = int(fmod(s, 3600.0) / 60.0)
	var sec: float = fmod(s, 60.0)
	return ("-" if neg else "") + "%02d:%02d:%02d" % [h, m, int(sec)]

# ---------------------------------------------------------------------------
# Input key mapping
# ---------------------------------------------------------------------------

func keycode_to_godot_key(keycode: int) -> Key:
	if keycode >= 97 and keycode <= 122:
		return (KEY_A + (keycode - 97)) as Key
	if keycode >= 48 and keycode <= 57:
		return (KEY_0 + (keycode - 48)) as Key
	if keycode >= 282 and keycode <= 296:
		return (KEY_F1 + (keycode - 282)) as Key
	if keycode >= 256 and keycode <= 265:
		return (KEY_KP_0 + (keycode - 256)) as Key
	match keycode:
		8: return KEY_BACKSPACE
		9: return KEY_TAB
		13: return KEY_ENTER
		19: return KEY_PAUSE
		27: return KEY_ESCAPE
		32: return KEY_SPACE
		39: return KEY_APOSTROPHE
		44: return KEY_COMMA
		45: return KEY_MINUS
		46: return KEY_PERIOD
		47: return KEY_SLASH
		59: return KEY_SEMICOLON
		61: return KEY_EQUAL
		91: return KEY_BRACKETLEFT
		92: return KEY_BACKSLASH
		93: return KEY_BRACKETRIGHT
		96: return KEY_QUOTELEFT
		127: return KEY_DELETE
		266: return KEY_KP_PERIOD
		267: return KEY_KP_DIVIDE
		268: return KEY_KP_MULTIPLY
		269: return KEY_KP_SUBTRACT
		270: return KEY_KP_ADD
		271: return KEY_KP_ENTER
		273: return KEY_UP
		274: return KEY_DOWN
		275: return KEY_RIGHT
		276: return KEY_LEFT
		277: return KEY_INSERT
		278: return KEY_HOME
		279: return KEY_END
		280: return KEY_PAGEUP
		281: return KEY_PAGEDOWN
		300: return KEY_NUMLOCK
		301: return KEY_CAPSLOCK
		302: return KEY_SCROLLLOCK
		303, 304: return KEY_SHIFT
		305, 306: return KEY_CTRL
		307, 308: return KEY_ALT
		309, 310: return KEY_META
		311, 312: return KEY_META
		319: return KEY_MENU
		_: return KEY_NONE

func keycode_from_name(name_: String) -> int:
	var n: String = name_.to_lower()
	if n.length() == 1:
		return n.unicode_at(0)
	match n:
		"space": return 32
		"escape": return 27
		"return", "enter": return 13
		"tab": return 9
		"backspace": return 8
		"up": return 273
		"down": return 274
		"left": return 276
		"right": return 275
		"left shift": return 304
		"right shift": return 303
		"left ctrl": return 306
		"right ctrl": return 305
		"left alt": return 308
		"right alt": return 307
		_: return 0

# ---------------------------------------------------------------------------
# AnimationCurve (Curve), constraints, wheels
# ---------------------------------------------------------------------------

func curve_from_keys(keys: Array) -> Curve:
	var c := Curve.new()
	for k in keys:
		curve_add_key(c, float(k.get("time", 0.0)), float(k.get("value", 0.0)), float(k.get("inTangent", 0.0)), float(k.get("outTangent", 0.0)))
	return c

## Godot curves clamp to their domain/value range (0..1 by default); grow both to fit the keys.
func curve_add_key(c: Curve, t: float, v: float, tin: float = 0.0, tout: float = 0.0) -> int:
	if c.point_count == 0:
		c.min_domain = t
		c.max_domain = t
		c.min_value = v
		c.max_value = v
	c.min_domain = minf(c.min_domain, t)
	c.max_domain = maxf(c.max_domain, t)
	c.min_value = minf(c.min_value, v)
	c.max_value = maxf(c.max_value, v)
	return c.add_point(Vector2(t, v), tin, tout)

func curve_keys(c: Curve) -> Array:
	var out: Array = []
	for i in range(c.point_count):
		var p: Vector2 = c.get_point_position(i)
		out.append({"time": p.x, "value": p.y, "inTangent": c.get_point_left_tangent(i), "outTangent": c.get_point_right_tangent(i)})
	return out

func curve_move_key(c: Curve, i: int, k: Dictionary) -> int:
	c.set_point_offset(i, float(k.get("time", 0.0)))
	c.set_point_value(i, float(k.get("value", 0.0)))
	return i

func curve_linear(t0: float, v0: float, t1: float, v1: float) -> Curve:
	return curve_from_keys([{"time": t0, "value": v0}, {"time": t1, "value": v1}])

func curve_ease_in_out(t0: float, v0: float, t1: float, v1: float) -> Curve:
	var c := curve_linear(t0, v0, t1, v1)
	c.set_point_right_tangent(0, 0.0)
	c.set_point_left_tangent(1, 0.0)
	return c

var _constraints: Dictionary = {}

func _constraint(n: Node) -> Dictionary:
	var id: int = n.get_instance_id()
	if not _constraints.has(id):
		_constraints[id] = {"active": false, "weight": 1.0, "locked": false, "sources": []}
	return _constraints[id]

func constraint_get(n: Node, key: String, default):
	if n == null:
		return default
	return _constraint(n).get(key, default)

func constraint_set(n: Node, key: String, value) -> void:
	if n == null:
		return
	_constraint(n)[key] = value
	if n.has_method("udon_constraint_set"):
		n.udon_constraint_set(key, value)

func constraint_sources(n: Node) -> Array:
	return _constraint(n)["sources"] if n != null else []

func constraint_set_source(n: Node, i: int, src: Dictionary) -> void:
	var s: Array = constraint_sources(n)
	if i >= 0 and i < s.size():
		s[i] = src

func constraint_add_source(n: Node, src: Dictionary) -> int:
	var s: Array = constraint_sources(n)
	s.append(src)
	return s.size() - 1

func constraint_remove_source(n: Node, i: int) -> void:
	var s: Array = constraint_sources(n)
	if i >= 0 and i < s.size():
		s.remove_at(i)

func wheel_set_spring(w: VehicleWheel3D, spring: Dictionary) -> void:
	w.suspension_stiffness = float(spring.get("spring", w.suspension_stiffness))
	w.damping_compression = float(spring.get("damper", w.damping_compression))
	w.damping_relaxation = float(spring.get("damper", w.damping_relaxation))

# ---------------------------------------------------------------------------
# .NET extras: StringBuilder, Regex, Encoding, DateTime parsing, Stopwatch, Type
# ---------------------------------------------------------------------------

const _UdonStringBuilder := preload("res://addons/udon_runtime/udon_string_builder.gd")
var _regex_cache: Dictionary = {}

func new_string_builder(initial: String):
	return _UdonStringBuilder.new(initial)

func new_regex(pattern: String, options: int) -> RegEx:
	var p: String = pattern
	if options & 1:
		p = "(?i)" + p
	if options & 2:
		p = "(?m)" + p
	if options & 16:
		p = "(?s)" + p
	if options & 32:
		p = "(?x)" + p
	var r := RegEx.new()
	if r.compile(p) != OK:
		push_error("Regex: invalid pattern " + pattern)
	r.set_meta("udon_options", options)
	return r

func regex_static(pattern: String, options: int) -> RegEx:
	var key := "%d:%s" % [options, pattern]
	if not _regex_cache.has(key):
		_regex_cache[key] = new_regex(pattern, options)
	return _regex_cache[key]

func _match_dict(r: RegEx, m: RegExMatch, subject: String) -> Dictionary:
	if m == null:
		return {"success": false, "value": "", "index": 0, "length": 0, "groups": [], "name": "0"}
	var groups: Array = []
	var by_num: Dictionary = {}
	for n in m.names.keys():
		by_num[m.names[n]] = n
	for i in range(m.get_group_count() + 1):
		var s: int = m.get_start(i)
		groups.append({"success": s >= 0, "value": m.get_string(i), "index": maxi(s, 0), "length": m.get_string(i).length(), "name": str(by_num.get(i, str(i))), "groups": []})
	return {"success": true, "value": m.get_string(), "index": m.get_start(), "length": m.get_string().length(), "groups": groups, "name": "0", "_regex": r, "_subject": subject, "_end": m.get_end()}

func regex_match(r: RegEx, subject: String, start: int = 0, end: int = -1) -> Dictionary:
	return _match_dict(r, r.search(subject, start, end), subject)

func regex_next_match(m: Dictionary) -> Dictionary:
	var r = m.get("_regex")
	if r == null or not m.get("success", false):
		return _match_dict(null, null, "")
	var subject: String = m.get("_subject", "")
	var next: int = int(m.get("_end", 0))
	if next == int(m.get("index", 0)):
		next += 1
	return _match_dict(r, r.search(subject, next), subject)

func regex_matches(r: RegEx, subject: String, start: int = 0) -> Array:
	var out: Array = []
	for m in r.search_all(subject, start):
		out.append(_match_dict(r, m, subject))
	return out

## .NET replacement syntax ($1, ${name}) → Godot ($1, ${name} works too)
func regex_replacement(rep: String) -> String:
	return rep.replace("$$", "\\$")

func regex_replace_n(r: RegEx, subject: String, rep: String, count: int, start: int = 0) -> String:
	var out: String = subject
	var n: int = 0
	var pos: int = start
	while n < count:
		var m := r.search(out, pos)
		if m == null:
			break
		var repl: String = regex_expand(_match_dict(r, m, out), rep)
		out = out.substr(0, m.get_start()) + repl + out.substr(m.get_end())
		pos = m.get_start() + repl.length()
		n += 1
	return out

func regex_expand(m: Dictionary, rep: String) -> String:
	var out: String = rep
	var groups: Array = m.get("groups", [])
	for i in range(groups.size() - 1, -1, -1):
		out = out.replace("$" + str(i), str(groups[i].get("value", "")))
		out = out.replace("${" + str(groups[i].get("name", "")) + "}", str(groups[i].get("value", "")))
	return out.replace("$&", str(m.get("value", "")))

func regex_split(r: RegEx, subject: String, count: int = 0) -> Array:
	var out: Array = []
	var last: int = 0
	for m in r.search_all(subject):
		if count > 0 and out.size() >= count - 1:
			break
		out.append(subject.substr(last, m.get_start() - last))
		last = m.get_end()
	out.append(subject.substr(last))
	return out

func regex_group_name(r: RegEx, i: int) -> String:
	# Named groups are numbered in order of appearance; approximate with the names list.
	var names: PackedStringArray = r.get_names()
	if i >= 1 and i <= names.size():
		return names[i - 1]
	return str(i)

func regex_group_number(r: RegEx, name_: String) -> int:
	var names: PackedStringArray = r.get_names()
	var i: int = names.find(name_)
	return i + 1 if i >= 0 else -1

func regex_group_by_name(groups: Array, name_: String) -> Dictionary:
	for g in groups:
		if str(g.get("name", "")) == name_:
			return g
	return {"success": false, "value": "", "index": 0, "length": 0, "name": ""}

func regex_group_names(groups: Array) -> Array:
	var out: Array = []
	for g in groups:
		out.append(str(g.get("name", "")))
	return out

func regex_escape(s: String) -> String:
	var out: String = ""
	for c in s:
		if "\\*+?|{}[]()^$.#".contains(c) or c == " ":
			out += "\\"
		out += c
	return out

func regex_unescape(s: String) -> String:
	return s.replace("\\\\", "\\").replace("\\.", ".").replace("\\*", "*").replace("\\+", "+").replace("\\?", "?").replace("\\(", "(").replace("\\)", ")").replace("\\[", "[").replace("\\]", "]").replace("\\{", "{").replace("\\}", "}").replace("\\^", "^").replace("\\$", "$").replace("\\|", "|").replace("\\#", "#").replace("\\ ", " ")

func encoding_get_bytes(enc: String, s: String) -> Array:
	match enc:
		"ascii", "latin1":
			return Array(s.to_ascii_buffer())
		"utf16":
			return Array(s.to_utf16_buffer())
		"utf32":
			return Array(s.to_utf32_buffer())
		_:
			return Array(s.to_utf8_buffer())

func encoding_get_string(enc: String, bytes: Array) -> String:
	var b := PackedByteArray(bytes)
	match enc:
		"ascii", "latin1":
			return b.get_string_from_ascii()
		"utf16":
			return b.get_string_from_utf16()
		"utf32":
			return b.get_string_from_utf32()
		_:
			return b.get_string_from_utf8()

func datetime_parse(s: String) -> Dictionary:
	var unix: float = float(Time.get_unix_time_from_datetime_string(s.strip_edges().replace(" ", "T")))
	if unix <= 0.0 and not s.begins_with("1970"):
		return {"unix": -1.0}
	return datetime_from_unix(unix)

func datetime_from_parts(y: int, mo: int, d: int, h: int, mi: int, s: int) -> Dictionary:
	return datetime_from_unix(float(Time.get_unix_time_from_datetime_dict({"year": y, "month": mo, "day": d, "hour": h, "minute": mi, "second": s})))

func days_in_month(y: int, m: int) -> int:
	var days: Array = [31, 29 if ((y % 4 == 0 and y % 100 != 0) or y % 400 == 0) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	return days[clampi(m - 1, 0, 11)]

func stopwatch_start(sw: Dictionary) -> void:
	if not sw.get("running", false):
		sw["start"] = Time.get_ticks_usec()
		sw["running"] = true

func stopwatch_stop(sw: Dictionary) -> void:
	if sw.get("running", false):
		sw["acc"] = int(sw.get("acc", 0)) + (Time.get_ticks_usec() - int(sw.get("start", 0)))
		sw["running"] = false

func stopwatch_usec(sw: Dictionary) -> int:
	var acc: int = int(sw.get("acc", 0))
	if sw.get("running", false):
		acc += Time.get_ticks_usec() - int(sw.get("start", 0))
	return acc

func type_is_value(t: String) -> bool:
	return t in ["bool", "int", "float", "double", "long", "short", "byte", "char", "Vector3", "Vector2", "Vector4", "Quaternion", "Color", "Color32", "Rect", "Bounds", "Plane", "Ray", "Matrix4x4"]

func type_base(t: String) -> String:
	if ClassDB.class_exists(t):
		return ClassDB.get_parent_class(t)
	return "Object"

func type_code(t: String) -> int:
	match t:
		"bool": return 3
		"char": return 4
		"sbyte": return 5
		"byte": return 6
		"short": return 7
		"ushort": return 8
		"int": return 9
		"uint": return 10
		"long": return 11
		"ulong": return 12
		"float": return 13
		"double": return 14
		"decimal": return 15
		"DateTime": return 16
		"string": return 18
		_: return 1

func change_type(v, t: String):
	match t:
		"int", "long", "short", "byte", "uint", "ulong", "ushort", "sbyte": return int(v)
		"float", "double", "decimal": return float(v)
		"string": return str(v)
		"bool": return bool(v)
		_: return v

func array_index_of_range(a: Array, v, start: int, count: int) -> int:
	var i: int = a.find(v, start)
	return i if i >= 0 and i < start + count else -1

func array_last_index_of(a: Array, v, start: int) -> int:
	var i: int = start
	while i >= 0:
		if i < a.size() and a[i] == v:
			return i
		i -= 1
	return -1

func array_sort_keys_items(keys: Array, items: Array) -> void:
	var idx: Array = range(keys.size())
	idx.sort_custom(func(x, y): return keys[x] < keys[y])
	var k2: Array = keys.duplicate()
	var i2: Array = items.duplicate()
	for n in range(idx.size()):
		keys[n] = k2[idx[n]]
		if n < items.size():
			items[n] = i2[idx[n]]

func scene_root() -> Node:
	return get_tree().current_scene if get_tree().current_scene != null else get_tree().root

# ---------------------------------------------------------------------------
# 2D physics (Unity Y-up ↔ Godot Y-down)
# ---------------------------------------------------------------------------

func v2_to_gd(v: Vector2) -> Vector2:
	return Vector2(v.x, -v.y)

func v2_from_gd(v: Vector2) -> Vector2:
	return Vector2(v.x, -v.y)

func gravity2d() -> Vector2:
	var g: float = ProjectSettings.get_setting("physics/2d/default_gravity", 980.0)
	var v: Vector2 = ProjectSettings.get_setting("physics/2d/default_gravity_vector", Vector2.DOWN)
	return v2_from_gd(v * g)

func set_gravity2d(g: Vector2) -> void:
	var space := get_viewport().world_2d.space
	PhysicsServer2D.area_set_param(space, PhysicsServer2D.AREA_PARAM_GRAVITY, g.length())
	PhysicsServer2D.area_set_param(space, PhysicsServer2D.AREA_PARAM_GRAVITY_VECTOR, v2_to_gd(g).normalized())

func rb2d_set_kinematic(rb: RigidBody2D, k: bool) -> void:
	rb.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
	rb.freeze = k

func rb2d_get_body_type(rb: RigidBody2D) -> int:
	if rb.freeze:
		return 2 if rb.freeze_mode == RigidBody2D.FREEZE_MODE_STATIC else 1
	return 0

func rb2d_set_body_type(rb: RigidBody2D, t: int) -> void:
	match t:
		1:
			rb.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
			rb.freeze = true
		2:
			rb.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
			rb.freeze = true
		_:
			rb.freeze = false

func rb2d_get_constraints(rb: RigidBody2D) -> int:
	return (4 if rb.lock_rotation else 0)

func rb2d_set_constraints(rb: RigidBody2D, c: int) -> void:
	rb.lock_rotation = (c & 4) != 0
	if c & 3 == 3:
		rb.freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
		rb.freeze = true

func rb2d_add_force(rb: RigidBody2D, f: Vector2, mode: int) -> void:
	if mode == 1:
		rb.apply_central_impulse(v2_to_gd(f))
	else:
		rb.apply_central_force(v2_to_gd(f))

func rb2d_add_force_at(rb: RigidBody2D, f: Vector2, pos: Vector2, mode: int) -> void:
	var off: Vector2 = v2_to_gd(pos) - rb.global_position
	if mode == 1:
		rb.apply_impulse(v2_to_gd(f), off)
	else:
		rb.apply_force(v2_to_gd(f), off)

func rb2d_add_torque(rb: RigidBody2D, t: float, mode: int) -> void:
	if mode == 1:
		rb.apply_torque_impulse(-t)
	else:
		rb.apply_torque(-t)

func rb2d_move_position(rb: RigidBody2D, p: Vector2) -> void:
	var target: Vector2 = v2_to_gd(p)
	if rb.freeze:
		rb.global_position = target
	else:
		rb.linear_velocity = (target - rb.global_position) / fixed_delta_time()

func rb2d_move_rotation(rb: RigidBody2D, deg: float) -> void:
	var target: float = -deg_to_rad(deg)
	if rb.freeze:
		rb.global_rotation = target
	else:
		rb.angular_velocity = angle_difference(rb.global_rotation, target) / fixed_delta_time()

func rb2d_point_velocity(rb: RigidBody2D, p: Vector2) -> Vector2:
	var r: Vector2 = v2_to_gd(p) - rb.to_global(rb.center_of_mass)
	return v2_from_gd(rb.linear_velocity + Vector2(-r.y, r.x) * rb.angular_velocity)

func _space2d() -> PhysicsDirectSpaceState2D:
	var w := get_viewport().world_2d if get_viewport() != null else null
	return w.direct_space_state if w != null else null

func _mask2d(m: int) -> int:
	return 0xFFFFFFFF if m < 0 else m

func raycast2d(origin: Vector2, dir: Vector2, dist: float, mask: int) -> Dictionary:
	var space := _space2d()
	if space == null or dir.length_squared() < 1e-12:
		return {}
	var d: float = dist if is_finite(dist) else 100000.0
	var o: Vector2 = v2_to_gd(origin)
	var q := PhysicsRayQueryParameters2D.create(o, o + v2_to_gd(dir).normalized() * d, _mask2d(mask))
	q.collide_with_areas = true
	var r: Dictionary = space.intersect_ray(q)
	if r.is_empty():
		return {}
	var p: Vector2 = r["position"]
	return {"point": v2_from_gd(p), "normal": v2_from_gd(r["normal"]), "distance": o.distance_to(p), "fraction": o.distance_to(p) / d, "collider": r["collider"], "centroid": v2_from_gd(p)}

func raycast2d_all(origin: Vector2, dir: Vector2, dist: float, mask: int) -> Array:
	var out: Array = []
	var exclude: Array = []
	var space := _space2d()
	if space == null:
		return out
	var d: float = dist if is_finite(dist) else 100000.0
	var o: Vector2 = v2_to_gd(origin)
	for _i in range(32):
		var q := PhysicsRayQueryParameters2D.create(o, o + v2_to_gd(dir).normalized() * d, _mask2d(mask))
		q.collide_with_areas = true
		q.exclude = exclude
		var r: Dictionary = space.intersect_ray(q)
		if r.is_empty():
			break
		var p: Vector2 = r["position"]
		out.append({"point": v2_from_gd(p), "normal": v2_from_gd(r["normal"]), "distance": o.distance_to(p), "fraction": o.distance_to(p) / d, "collider": r["collider"], "centroid": v2_from_gd(p)})
		exclude.append(r["rid"])
	return out

func raycast2d_all_into(origin: Vector2, dir: Vector2, dist: float, mask: int, results: Array) -> int:
	var hits: Array = raycast2d_all(origin, dir, dist, mask)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func _shape2d(kind: String, radius: float, size: Vector2) -> Shape2D:
	match kind:
		"circle":
			var c := CircleShape2D.new()
			c.radius = radius
			return c
		"box":
			var b := RectangleShape2D.new()
			b.size = size
			return b
		"capsule":
			var cp := CapsuleShape2D.new()
			cp.radius = size.x / 2.0
			cp.height = size.y
			return cp
		_:
			var pt := CircleShape2D.new()
			pt.radius = 0.01
			return pt

func shapecast2d(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, dir: Vector2, dist: float, mask: int) -> Dictionary:
	var space := _space2d()
	if space == null:
		return {}
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = _shape2d(kind, radius, size)
	params.transform = Transform2D(-deg_to_rad(angle), v2_to_gd(origin))
	var d: float = dist if is_finite(dist) else 100000.0
	params.motion = v2_to_gd(dir).normalized() * d
	params.collision_mask = _mask2d(mask)
	params.collide_with_areas = true
	var m: PackedFloat32Array = space.cast_motion(params)
	if m.size() < 2 or m[0] >= 1.0:
		return {}
	var frac: float = m[0]
	var centroid: Vector2 = v2_to_gd(origin) + params.motion * frac
	params.transform = Transform2D(-deg_to_rad(angle), centroid)
	var rest: Dictionary = space.get_rest_info(params)
	var col = instance_from_id(rest["collider_id"]) if rest.has("collider_id") else null
	return {"point": v2_from_gd(rest.get("point", centroid)), "normal": v2_from_gd(rest.get("normal", Vector2.UP)), "distance": d * frac, "fraction": frac, "collider": col, "centroid": v2_from_gd(centroid)}

func shapecast2d_all(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, dir: Vector2, dist: float, mask: int) -> Array:
	var h := shapecast2d(kind, origin, radius, size, angle, dir, dist, mask)
	return [h] if not h.is_empty() else []

func shapecast2d_into(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, dir: Vector2, dist: float, mask: int, results: Array) -> int:
	var hits: Array = shapecast2d_all(kind, origin, radius, size, angle, dir, dist, mask)
	var n: int = mini(hits.size(), results.size())
	for i in range(n):
		results[i] = hits[i]
	return n

func overlap2d(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, mask: int) -> Array:
	var space := _space2d()
	if space == null:
		return []
	var out: Array = []
	if kind == "point":
		var pq := PhysicsPointQueryParameters2D.new()
		pq.position = v2_to_gd(origin)
		pq.collision_mask = _mask2d(mask)
		pq.collide_with_areas = true
		for r in space.intersect_point(pq, 64):
			out.append(r["collider"])
		return out
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = _shape2d(kind, radius, size)
	params.transform = Transform2D(-deg_to_rad(angle), v2_to_gd(origin))
	params.collision_mask = _mask2d(mask)
	params.collide_with_areas = true
	for r in space.intersect_shape(params, 64):
		out.append(r["collider"])
	return out

func overlap2d_first(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, mask: int):
	var all: Array = overlap2d(kind, origin, radius, size, angle, mask)
	return all[0] if not all.is_empty() else null

func overlap2d_into(kind: String, origin: Vector2, radius: float, size: Vector2, angle: float, mask: int, results: Array) -> int:
	var all: Array = overlap2d(kind, origin, radius, size, angle, mask)
	var n: int = mini(all.size(), results.size())
	for i in range(n):
		results[i] = all[i]
	return n

func _co2d(n: Node) -> CollisionObject2D:
	if n is CollisionObject2D:
		return n
	if n is CollisionShape2D and n.get_parent() is CollisionObject2D:
		return n.get_parent()
	if n != null:
		for c in n.get_children():
			if c is CollisionObject2D:
				return c
	return null

func shape2d_of(n: Node) -> CollisionShape2D:
	if n is CollisionShape2D:
		return n
	var co := _co2d(n)
	if co != null:
		for c in co.get_children():
			if c is CollisionShape2D:
				return c
	return null

func collider2d_get_enabled(n: Node) -> bool:
	var s := shape2d_of(n)
	return s != null and not s.disabled

func collider2d_set_enabled(n: Node, v: bool) -> void:
	var s := shape2d_of(n)
	if s != null:
		s.disabled = not v

func collider2d_attached_rigidbody(n: Node) -> RigidBody2D:
	var cur: Node = n
	while cur != null:
		if cur is RigidBody2D:
			return cur
		cur = cur.get_parent()
	return null

func collider2d_bounds(n: Node) -> AABB:
	var s := shape2d_of(n)
	if s == null or s.shape == null:
		return AABB()
	var r: Rect2 = s.shape.get_rect()
	var gr: Rect2 = s.global_transform * r
	var pos: Vector2 = v2_from_gd(gr.end)
	return AABB(Vector3(gr.position.x, pos.y, 0.0), Vector3(gr.size.x, gr.size.y, 0.0))

func collider2d_material(n: Node) -> PhysicsMaterial:
	var co := _co2d(n)
	return co.physics_material_override if co is PhysicsBody2D else null

func collider2d_set_material(n: Node, m: PhysicsMaterial) -> void:
	var co := _co2d(n)
	if co is PhysicsBody2D:
		co.physics_material_override = m

func collider2d_material_prop(n: Node, prop: String, default: float) -> float:
	var m := collider2d_material(n)
	return m.get(prop) if m != null else default

func shape2d_set_offset(n: Node, v: Vector2) -> void:
	var s := shape2d_of(n)
	if s != null:
		s.position = v2_to_gd(v)

func shape2d_get_size(n: Node) -> Vector2:
	var s := shape2d_of(n)
	if s != null and s.shape is RectangleShape2D:
		return s.shape.size
	if s != null and s.shape is CapsuleShape2D:
		return Vector2(s.shape.radius * 2.0, s.shape.height)
	return Vector2.ONE

func shape2d_set_size(n: Node, v: Vector2) -> void:
	var s := shape2d_of(n)
	if s != null and s.shape is RectangleShape2D:
		s.shape.size = v
	elif s != null and s.shape is CapsuleShape2D:
		s.shape.radius = v.x / 2.0
		s.shape.height = v.y

func shape2d_get_radius(n: Node) -> float:
	var s := shape2d_of(n)
	if s != null and (s.shape is CircleShape2D or s.shape is CapsuleShape2D):
		return s.shape.radius
	return 0.5

func shape2d_set_radius(n: Node, v: float) -> void:
	var s := shape2d_of(n)
	if s != null and (s.shape is CircleShape2D or s.shape is CapsuleShape2D):
		s.shape.radius = v

func shape2d_get_points(n: Node) -> Array:
	var s := shape2d_of(n)
	var out: Array = []
	if s != null and s.shape is ConvexPolygonShape2D:
		for p in s.shape.points:
			out.append(v2_from_gd(p))
	elif s != null and s.shape is ConcavePolygonShape2D:
		for p in s.shape.segments:
			out.append(v2_from_gd(p))
	return out

func shape2d_get_points_into(n: Node, into: Array) -> int:
	var pts: Array = shape2d_get_points(n)
	into.assign(pts)
	return pts.size()

func shape2d_set_points(n: Node, pts: Array) -> void:
	var s := shape2d_of(n)
	if s == null:
		return
	var conv := PackedVector2Array()
	for p in pts:
		conv.append(v2_to_gd(p))
	if s.shape is ConvexPolygonShape2D or s.shape == null:
		var sh := ConvexPolygonShape2D.new()
		sh.points = conv
		s.shape = sh
	elif s.shape is ConcavePolygonShape2D:
		var seg := PackedVector2Array()
		for i in range(conv.size() - 1):
			seg.append(conv[i])
			seg.append(conv[i + 1])
		s.shape.segments = seg

func collider2d_touching(a: Node, b: Node) -> bool:
	var ca := _co2d(a)
	var cb := _co2d(b)
	if ca == null or cb == null:
		return false
	if ca is RigidBody2D:
		return ca.get_colliding_bodies().has(cb)
	if ca is Area2D:
		return ca.get_overlapping_bodies().has(cb) or ca.get_overlapping_areas().has(cb)
	return false

func collider2d_touching_any(a: Node) -> bool:
	var ca := _co2d(a)
	if ca is RigidBody2D:
		return not ca.get_colliding_bodies().is_empty()
	if ca is Area2D:
		return not ca.get_overlapping_bodies().is_empty()
	return false

func collider2d_overlap_point(n: Node, p: Vector2) -> bool:
	var co := _co2d(n)
	return co != null and overlap2d("point", p, 0.0, Vector2.ZERO, 0.0, -1).has(co)

func collider2d_closest_point(n: Node, p: Vector2) -> Vector2:
	var b := collider2d_bounds(n)
	var c := aabb_closest_point(b, Vector3(p.x, p.y, 0.0))
	return Vector2(c.x, c.y)

func collider2d_distance(a: Node, b: Node) -> Dictionary:
	var pa: Vector2 = collider2d_closest_point(a, collider2d_closest_point(b, Vector2.ZERO))
	var pb: Vector2 = collider2d_closest_point(b, pa)
	return {"pointA": pa, "pointB": pb, "normal": (pb - pa).normalized(), "distance": pa.distance_to(pb)}

func collider2d_raycast(n: Node, dir: Vector2, results: Array, dist: float) -> int:
	var co := _co2d(n)
	if not (co is Node2D):
		return 0
	var hit := raycast2d(v2_from_gd(co.global_position), dir, dist, -1)
	if hit.is_empty() or results.is_empty():
		return 0
	results[0] = hit
	return 1

func rb2d_cast(n: Node, dir: Vector2, results: Array, dist: float) -> int:
	var co := _co2d(n)
	var s := shape2d_of(n)
	if co == null or s == null or s.shape == null:
		return 0
	var space := _space2d()
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = s.shape
	params.transform = s.global_transform
	params.exclude = [co.get_rid()]
	var d: float = dist if is_finite(dist) else 100000.0
	params.motion = v2_to_gd(dir).normalized() * d
	var m: PackedFloat32Array = space.cast_motion(params)
	if m.size() < 2 or m[0] >= 1.0 or results.is_empty():
		return 0
	var centroid: Vector2 = s.global_position + params.motion * m[0]
	results[0] = {"point": v2_from_gd(centroid), "normal": -dir.normalized(), "distance": d * m[0], "fraction": m[0], "collider": null, "centroid": v2_from_gd(centroid)}
	return 1

func rb2d_attached_colliders(rb: RigidBody2D, into: Array) -> int:
	var n: int = 0
	for c in rb.get_children():
		if c is CollisionShape2D and n < into.size():
			into[n] = c
			n += 1
	return n

func rb2d_contacts(n: Node, into: Array) -> int:
	var co := _co2d(n)
	var bodies: Array = []
	if co is RigidBody2D:
		bodies = co.get_colliding_bodies()
	elif co is Area2D:
		bodies = co.get_overlapping_bodies()
	var k: int = mini(bodies.size(), into.size())
	for i in range(k):
		into[i] = bodies[i]
	return k

func rb2d_overlap_point(rb: RigidBody2D, p: Vector2) -> bool:
	return overlap2d("point", p, 0.0, Vector2.ZERO, 0.0, -1).has(rb)

func collider2d_contact_points(n: Node, into: Array) -> int:
	var co := _co2d(n)
	if not (co is RigidBody2D) or into.is_empty():
		return 0
	var bodies: Array = co.get_colliding_bodies()
	var k: int = mini(bodies.size(), into.size())
	for i in range(k):
		into[i] = {"point": v2_from_gd(bodies[i].global_position), "normal": Vector2.UP, "collider": bodies[i], "otherCollider": co}
	return k

func collider2d_overlap(n: Node, into: Array) -> int:
	return rb2d_contacts(n, into)

func ignore_collision2d(a: Node, b: Node, ignore: bool) -> void:
	var ca := _co2d(a)
	var cb := _co2d(b)
	if ca is PhysicsBody2D and cb is PhysicsBody2D:
		if ignore:
			ca.add_collision_exception_with(cb)
		else:
			ca.remove_collision_exception_with(cb)

var _effectors: Dictionary = {}

func effector_get(n: Node, key: String, default):
	return _effectors.get(n.get_instance_id(), {}).get(key, default) if n != null else default

func effector_set(n: Node, key: String, value) -> void:
	if n == null:
		return
	var id: int = n.get_instance_id()
	if not _effectors.has(id):
		_effectors[id] = {}
	_effectors[id][key] = value
	if n is Area2D and key in ["forceAngle", "forceMagnitude"]:
		var ang: float = float(_effectors[id].get("forceAngle", 0.0))
		var mag: float = float(_effectors[id].get("forceMagnitude", 0.0))
		n.gravity_direction = v2_to_gd(Vector2(cos(deg_to_rad(ang)), sin(deg_to_rad(ang))))
		n.gravity = mag
		n.gravity_space_override = Area2D.SPACE_OVERRIDE_COMBINE if mag != 0.0 else Area2D.SPACE_OVERRIDE_DISABLED

# ---------------------------------------------------------------------------
# Navigation & character controller
# ---------------------------------------------------------------------------

var _nav: Dictionary = {}

func nav_get(a: Node, key: String, default):
	return _nav.get(a.get_instance_id(), {}).get(key, default) if a != null else default

func nav_set(a: Node, key: String, value) -> void:
	if a == null:
		return
	var id: int = a.get_instance_id()
	if not _nav.has(id):
		_nav[id] = {}
	_nav[id][key] = value

func nav_origin(a: NavigationAgent3D) -> Vector3:
	var p := a.get_parent()
	return p.global_position if p is Node3D else Vector3.ZERO

func nav_set_stopped(a: NavigationAgent3D, stopped: bool) -> void:
	nav_set(a, "stopped", stopped)
	if stopped:
		a.velocity = Vector3.ZERO

func nav_warp(a: NavigationAgent3D, p: Vector3) -> bool:
	var body := a.get_parent()
	if body is Node3D:
		body.global_position = p
	return true

func nav_move(a: NavigationAgent3D, offset: Vector3) -> void:
	var body := a.get_parent()
	if body is Node3D:
		body.global_position += offset

func nav_sample(p: Vector3, max_dist: float) -> Dictionary:
	var map: RID = get_viewport().world_3d.navigation_map if get_viewport() != null else RID()
	if not map.is_valid():
		return {"position": p, "hit": false}
	var c: Vector3 = NavigationServer3D.map_get_closest_point(map, p)
	return {"position": c, "normal": Vector3.UP, "distance": p.distance_to(c), "hit": p.distance_to(c) <= max_dist, "mask": -1}

func nav_path(from: Vector3, to: Vector3) -> Array:
	var map: RID = get_viewport().world_3d.navigation_map if get_viewport() != null else RID()
	if not map.is_valid():
		return []
	return Array(NavigationServer3D.map_get_path(map, from, to, true))

func cc_collision_flags(cc: CharacterBody3D) -> int:
	var f: int = 0
	if cc.is_on_wall():
		f |= 1
	if cc.is_on_ceiling():
		f |= 2
	if cc.is_on_floor():
		f |= 4
	return f

## CharacterController.Move: displacement this frame (no gravity applied by Unity either).
func cc_move(cc: CharacterBody3D, motion: Vector3) -> int:
	var dt: float = maxf(delta_time(), 0.0001)
	cc.velocity = motion / dt
	cc.move_and_slide()
	return cc_collision_flags(cc)

## CharacterController.SimpleMove: velocity in m/s with gravity.
func cc_simple_move(cc: CharacterBody3D, speed: Vector3) -> bool:
	var v: Vector3 = speed
	v.y = cc.velocity.y + gravity().y * delta_time()
	if cc.is_on_floor() and v.y < 0.0:
		v.y = -0.1
	cc.velocity = v
	cc.move_and_slide()
	return cc.is_on_floor()

# ---------------------------------------------------------------------------
# RenderSettings (WorldEnvironment), camera, mesh, texture, matrix, joint, misc adapters
# ---------------------------------------------------------------------------

func _env() -> Environment:
	var we: WorldEnvironment = find_object_of_type("WorldEnvironment")
	if we != null:
		if we.environment == null:
			we.environment = Environment.new()
		return we.environment
	var cam := main_camera()
	if cam != null:
		if cam.environment == null:
			cam.environment = Environment.new()
		return cam.environment
	return null

func env_get(prop: String, default):
	var e := _env()
	if e == null:
		return default
	if prop == "sky":
		return e.sky
	var v = e.get(prop)
	return v if v != null else default

func env_set(prop: String, value) -> void:
	var e := _env()
	if e == null:
		return
	if prop == "fog_enabled":
		e.fog_enabled = bool(value)
	elif prop == "ambient_light_source":
		e.ambient_light_source = (Environment.AMBIENT_SOURCE_COLOR if int(value) != 0 else Environment.AMBIENT_SOURCE_BG)
	else:
		e.set(prop, value)

func env_set_skybox(mat) -> void:
	var e := _env()
	if e == null:
		return
	if mat is Sky:
		e.sky = mat
		e.background_mode = Environment.BG_SKY
	elif mat is Material:
		var sky := Sky.new()
		sky.sky_material = mat
		e.sky = sky
		e.background_mode = Environment.BG_SKY

func env_sun() -> DirectionalLight3D:
	return find_object_of_type("DirectionalLight3D")

func env_set_sun(_l) -> void:
	pass

func camera_projection(c: Camera3D) -> Transform3D:
	return c.global_transform.affine_inverse()

func camera_frustum_corners(c: Camera3D, z: float, into: Array) -> void:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	var corners: Array = [Vector2(0, size.y), Vector2(0, 0), Vector2(size.x, 0), Vector2(size.x, size.y)]
	for i in range(mini(4, into.size())):
		into[i] = c.to_local(c.project_position(corners[i], z))

func camera_copy_from(dst: Camera3D, src: Camera3D) -> void:
	dst.fov = src.fov
	dst.near = src.near
	dst.far = src.far
	dst.projection = src.projection
	dst.size = src.size
	dst.cull_mask = src.cull_mask
	dst.global_transform = src.global_transform

func screen_to_viewport(c: Camera3D, p: Vector3) -> Vector3:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return Vector3(p.x / size.x, p.y / size.y, p.z)

func viewport_to_screen(c: Camera3D, p: Vector3) -> Vector3:
	var size: Vector2 = c.get_viewport().get_visible_rect().size
	return Vector3(p.x * size.x, p.y * size.y, p.z)

func all_cameras() -> Array:
	return get_components_in_children(scene_root(), "Camera3D", true)

func mesh_array(m: Mesh, idx: int) -> Array:
	if m == null or m.get_surface_count() == 0:
		return []
	var a = m.surface_get_arrays(0)[idx]
	return Array(a) if a != null else []

func mesh_tangents(m: Mesh) -> Array:
	var raw: Array = mesh_array(m, Mesh.ARRAY_TANGENT)
	var out: Array = []
	for i in range(0, raw.size() - 3, 4):
		out.append(Vector4(raw[i], raw[i + 1], raw[i + 2], raw[i + 3]))
	return out

func mesh_set_arrays(m: Mesh, which: String, data: Array) -> void:
	if not (m is ArrayMesh):
		return
	var arrays: Array = m.surface_get_arrays(0) if m.get_surface_count() > 0 else []
	if arrays.is_empty():
		arrays.resize(Mesh.ARRAY_MAX)
	match which:
		"vertices":
			arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(data)
		"normals":
			arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(data)
		"triangles":
			arrays[Mesh.ARRAY_INDEX] = PackedInt32Array(data)
		"uv":
			arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(data)
		"uv2":
			arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array(data)
		"colors":
			arrays[Mesh.ARRAY_COLOR] = PackedColorArray(data)
		"tangents":
			var t := PackedFloat32Array()
			for v in data:
				t.append_array([v.x, v.y, v.z, v.w])
			arrays[Mesh.ARRAY_TANGENT] = t
	if arrays[Mesh.ARRAY_VERTEX] == null:
		return
	if m.get_surface_count() > 0:
		m.clear_surfaces()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

func mesh_clear(m: Mesh) -> void:
	if m is ArrayMesh:
		m.clear_surfaces()

func mesh_blend_shape_index(m: Mesh, name_: String) -> int:
	if m is ArrayMesh:
		for i in range(m.get_blend_shape_count()):
			if String(m.get_blend_shape_name(i)) == name_:
				return i
	return -1

func texture_get_pixels_rect(t: Texture2D, x: int, y: int, w: int, h: int) -> Array:
	var out: Array = []
	var img := t.get_image()
	if img == null:
		return out
	for yy in range(y + h - 1, y - 1, -1):
		for xx in range(x, x + w):
			out.append(img.get_pixel(clampi(xx, 0, img.get_width() - 1), clampi(img.get_height() - 1 - yy, 0, img.get_height() - 1)))
	return out

func texture_set_pixels_rect(t: Texture2D, x: int, y: int, w: int, h: int, colors: Array) -> void:
	var img := t.get_image()
	if img == null:
		return
	var i: int = 0
	for yy in range(y, y + h):
		for xx in range(x, x + w):
			if i < colors.size():
				img.set_pixel(clampi(xx, 0, img.get_width() - 1), clampi(img.get_height() - 1 - yy, 0, img.get_height() - 1), colors[i])
			i += 1
	t.set_meta("udon_img", img)

func texture_load_raw(t: Texture2D, bytes: Array) -> void:
	var img := t.get_image()
	if img == null:
		return
	var b := PackedByteArray(bytes)
	if b.size() == img.get_data().size():
		img.set_data(img.get_width(), img.get_height(), img.has_mipmaps(), img.get_format(), b)
		t.set_meta("udon_img", img)

func texture_resize(t: Texture2D, w: int, h: int) -> bool:
	var img := t.get_image()
	if img == null:
		return false
	img.resize(w, h)
	if t is ImageTexture:
		t.set_image(img)
	return true

var _rt: Dictionary = {}

func rt_get(t, key: String, default):
	if t == null:
		return default
	if key == "width" and t is Texture2D:
		return t.get_width()
	if key == "height" and t is Texture2D:
		return t.get_height()
	return _rt.get(t.get_instance_id(), {}).get(key, default) if t is Object else default

func rt_set(t, key: String, value) -> void:
	if not (t is Object):
		return
	var id: int = t.get_instance_id()
	if not _rt.has(id):
		_rt[id] = {}
	_rt[id][key] = value

func matrix_get(t: Transform3D, row: int, col: int) -> float:
	var c: Vector4 = matrix_column(t, col)
	return c[row]

func matrix_from_columns(c0: Vector4, c1: Vector4, c2: Vector4, c3: Vector4) -> Transform3D:
	return Transform3D(Vector3(c0.x, c0.y, c0.z), Vector3(c1.x, c1.y, c1.z), Vector3(c2.x, c2.y, c2.z), Vector3(c3.x, c3.y, c3.z))

func matrix_set_column(t: Transform3D, i: int, v: Vector4) -> Transform3D:
	var v3 := Vector3(v.x, v.y, v.z)
	match i:
		0: t.basis.x = v3
		1: t.basis.y = v3
		2: t.basis.z = v3
		_: t.origin = v3
	return t

func matrix_set_row(t: Transform3D, i: int, v: Vector4) -> Transform3D:
	if i < 3:
		t.basis.x[i] = v.x
		t.basis.y[i] = v.y
		t.basis.z[i] = v.z
		t.origin[i] = v.w
	return t

func matrix_mul_vec4(t: Transform3D, v: Vector4) -> Vector4:
	var p: Vector3 = t.basis * Vector3(v.x, v.y, v.z) + t.origin * v.w
	return Vector4(p.x, p.y, p.z, v.w)

var _joints: Dictionary = {}

func joint_get(j: Node, key: String, default):
	return _joints.get(j.get_instance_id(), {}).get(key, default) if j != null else default

func joint_set(j: Node, key: String, value) -> void:
	if j == null:
		return
	var id: int = j.get_instance_id()
	if not _joints.has(id):
		_joints[id] = {}
	_joints[id][key] = value

## ConfigurableJointMotion: Locked=0 Limited=1 Free=2 → Generic6DOFJoint3D linear limits
func joint6_motion(j: Node, axis: int, motion: int) -> void:
	if not (j is Generic6DOFJoint3D):
		return
	var flag := Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT
	j.set_flag_x(flag, motion != 2) if axis == 0 else (j.set_flag_y(flag, motion != 2) if axis == 1 else j.set_flag_z(flag, motion != 2))
	var lim: float = 0.0 if motion == 0 else float(joint_get(j, "linearLimit", 0.0))
	joint6_linear_limit_axis(j, axis, lim)

func joint6_angular(j: Node, axis: int, motion: int) -> void:
	if not (j is Generic6DOFJoint3D):
		return
	var flag := Generic6DOFJoint3D.FLAG_ENABLE_ANGULAR_LIMIT
	match axis:
		0: j.set_flag_x(flag, motion != 2)
		1: j.set_flag_y(flag, motion != 2)
		_: j.set_flag_z(flag, motion != 2)
	if motion == 0:
		var lo := Generic6DOFJoint3D.PARAM_ANGULAR_LOWER_LIMIT
		var hi := Generic6DOFJoint3D.PARAM_ANGULAR_UPPER_LIMIT
		match axis:
			0:
				j.set_param_x(lo, 0.0)
				j.set_param_x(hi, 0.0)
			1:
				j.set_param_y(lo, 0.0)
				j.set_param_y(hi, 0.0)
			_:
				j.set_param_z(lo, 0.0)
				j.set_param_z(hi, 0.0)

func joint6_linear_limit(j: Node, lim: float) -> void:
	for a in range(3):
		if int(joint_get(j, ["xMotion", "yMotion", "zMotion"][a], 2)) == 1:
			joint6_linear_limit_axis(j, a, lim)

func joint6_linear_limit_axis(j: Generic6DOFJoint3D, axis: int, lim: float) -> void:
	var lo := Generic6DOFJoint3D.PARAM_LINEAR_LOWER_LIMIT
	var hi := Generic6DOFJoint3D.PARAM_LINEAR_UPPER_LIMIT
	match axis:
		0:
			j.set_param_x(lo, -lim)
			j.set_param_x(hi, lim)
		1:
			j.set_param_y(lo, -lim)
			j.set_param_y(hi, lim)
		_:
			j.set_param_z(lo, -lim)
			j.set_param_z(hi, lim)

var _generic_props: Dictionary = {}

func _gp_get(n, key: String, default):
	if not (n is Object):
		return default
	return _generic_props.get(n.get_instance_id(), {}).get(key, default)

func _gp_set(n, key: String, value) -> void:
	if not (n is Object):
		return
	var id: int = n.get_instance_id()
	if not _generic_props.has(id):
		_generic_props[id] = {}
	_generic_props[id][key] = value

func reverb_get(n, key: String, default):
	return _gp_get(n, key, default)

func reverb_set(n, key: String, value) -> void:
	_gp_set(n, key, value)

func dolly_get(n, key: String, default):
	return _gp_get(n, key, default)

func dolly_set(n, key: String, value) -> void:
	_gp_set(n, key, value)
	if n is PathFollow3D and key == "time":
		n.progress = float(value)

func physbone_get(n, key: String, default):
	return _gp_get(n, key, default)

func physbone_set(n, key: String, value) -> void:
	_gp_set(n, key, value)

func cine_get(n, key: String, default):
	return _gp_get(n, key, default)

func cine_set(n, key: String, value) -> void:
	_gp_set(n, key, value)
	if n is Camera3D and key == "priority" and int(value) > 100:
		n.make_current()

func layout_get(n, key: String, default):
	return _gp_get(n, key, default)

func layout_set(n, key: String, value) -> void:
	_gp_set(n, key, value)

func video_get(n, key: String, default):
	return _gp_get(n, key, default)

func video_set_url(n, url: String) -> void:
	_gp_set(n, "url", url)
	if n is VideoStreamPlayer and url.begins_with("res://"):
		n.stream = load(url)

func path_position(p: Path3D, offset: float) -> Vector3:
	if p.curve == null:
		return p.global_position
	return p.to_global(p.curve.sample_baked(offset, true))

func path_tangent(p: Path3D, offset: float) -> Vector3:
	if p.curve == null:
		return forward(p)
	var a: Vector3 = p.curve.sample_baked(offset, true)
	var b: Vector3 = p.curve.sample_baked(offset + 0.01, true)
	return p.global_transform.basis * (b - a).normalized()

func path_orientation(p: Path3D, offset: float) -> Quaternion:
	return look_rotation(path_tangent(p, offset), Vector3.UP)

func dropdown_options(o: OptionButton) -> Array:
	var out: Array = []
	for i in range(o.item_count):
		out.append({"text": o.get_item_text(i), "image": o.get_item_icon(i)})
	return out

func dropdown_set_options(o: OptionButton, opts: Array) -> void:
	o.clear()
	dropdown_add_options(o, opts)

func dropdown_add_options(o: OptionButton, opts: Array) -> void:
	for it in opts:
		if it is Dictionary:
			o.add_item(str(it.get("text", "")))
		else:
			o.add_item(str(it))

func anim_parameters(n: Node) -> Array:
	var out: Array = []
	for k in _params(n).keys():
		var v = _params(n)[k]
		var t: int = 1 if typeof(v) == TYPE_FLOAT else (3 if typeof(v) == TYPE_INT else (4 if typeof(v) == TYPE_BOOL else 9))
		out.append({"name": k, "type": t, "value": v})
	return out

func animation_state(p: AnimationPlayer, name_: String) -> Dictionary:
	var a := p.get_animation(name_) if p.has_animation(name_) else null
	return {"name": name_, "enabled": p.current_animation == name_, "weight": 1.0, "time": p.current_animation_position if p.current_animation == name_ else 0.0, "normalizedTime": 0.0, "speed": p.speed_scale, "length": a.length if a != null else 0.0, "clip": a}

func animation_add_clip(p: AnimationPlayer, clip: Animation, name_: String) -> void:
	var lib: AnimationLibrary = p.get_animation_library("") if p.has_animation_library("") else null
	if lib == null:
		lib = AnimationLibrary.new()
		p.add_animation_library("", lib)
	lib.add_animation(name_, clip)

func animation_remove_clip(p: AnimationPlayer, name_: String) -> void:
	if p.has_animation_library("") and p.get_animation_library("").has_animation(name_):
		p.get_animation_library("").remove_animation(name_)

func terrain_sample_height(n: Node, p: Vector3) -> float:
	var hit := raycast(Vector3(p.x, 10000.0, p.z), Vector3.DOWN, 20000.0, -1, 1)
	return hit.get("position", Vector3.ZERO).y if not hit.is_empty() else 0.0

func line_add_position(n: Node, p: Vector3) -> void:
	_line(n)["positions"].append(p)
	_line_redraw(n)

func line_add_positions(n: Node, pts: Array) -> void:
	_line(n)["positions"].append_array(pts)
	_line_redraw(n)

func line_gradient(n: Node) -> Gradient:
	var g := Gradient.new()
	g.set_color(0, line_get_prop(n, "startColor", Color.WHITE))
	g.set_color(1, line_get_prop(n, "endColor", Color.WHITE))
	return g

func gpu_readback(tex, _mip: int, receiver) -> Dictionary:
	var img: Image = tex.get_image() if tex is Texture2D else null
	var d := {"done": true, "hasError": img == null, "width": img.get_width() if img != null else 0, "height": img.get_height() if img != null else 0, "data": img.get_data() if img != null else PackedByteArray(), "image": img}
	if receiver != null and receiver.has_method("OnAsyncGpuReadbackComplete"):
		receiver.call_deferred("OnAsyncGpuReadbackComplete", d)
	return d

func gpu_readback_copy(req: Dictionary, into: Array) -> bool:
	var data: PackedByteArray = req.get("data", PackedByteArray())
	var n: int = mini(data.size(), into.size())
	for i in range(n):
		into[i] = data[i]
	return not req.get("hasError", true)

func gpu_readback_copy_colors(req: Dictionary, into: Array) -> bool:
	var img: Image = req.get("image")
	if img == null:
		return false
	var i: int = 0
	for y in range(img.get_height() - 1, -1, -1):
		for x in range(img.get_width()):
			if i >= into.size():
				return true
			into[i] = img.get_pixel(x, y)
			i += 1
	return true

func gpu_readback_copy_floats(req: Dictionary, into: Array) -> bool:
	var img: Image = req.get("image")
	if img == null:
		return false
	var i: int = 0
	for y in range(img.get_height() - 1, -1, -1):
		for x in range(img.get_width()):
			if i >= into.size():
				return true
			into[i] = img.get_pixel(x, y).r
			i += 1
	return true
