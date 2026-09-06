## `Udon` autoload — the world provider.
##
## This is the abstraction surface between converted Udon scripts and a Godot game. Everything
## VRChat-specific (players, ownership, networking, pickups, stations, input) is a method here
## or on the adapter objects it returns. A game supplies its own implementation by assigning
## `Udon.provider` to a subclass of [UdonWorldProvider] (see `udon_world_provider.gd`); the
## default provider is a single-user local stand-in that makes converted scripts run offline.
extends Node

const NetworkEventTarget_Owner := 0
const NetworkEventTarget_All := 1
const NetworkEventTarget_Others := 2
const NetworkEventTarget_Self := 3

## The active world provider (see udon_world_provider.gd). Assign before scripts run.
var provider: UdonWorldProvider = null

var _behaviours: Array = []
var _calling_player = null
var _in_network_call: int = 0
var _static_registry: Dictionary = {}  # class name → script resource (for cross-class statics)

# --- frame timing shared with U ---
var _delta: float = 0.0
var _physics_delta: float = 1.0 / 60.0
var _in_physics: bool = false
var _time: float = 0.0
var _fixed_time: float = 0.0
var _last_process_frame: int = -1

func _ready() -> void:
	process_priority = -1000
	if provider == null:
		set_provider(UdonWorldProvider.new())

## Install a world provider (a UdonWorldProvider subclass). Replaces the default one.
func set_provider(p: UdonWorldProvider) -> void:
	if provider != null and provider != p:
		provider.queue_free()
	provider = p
	if p.get_parent() == null:
		p.name = "UdonProvider"
		add_child(p)
	p._world_ready(self)

func _process(delta: float) -> void:
	_in_physics = false
	_delta = delta
	_time += delta
	_last_process_frame = Engine.get_process_frames()

func _physics_process(delta: float) -> void:
	_physics_delta = delta
	_fixed_time += delta

func _note_process(_delta: float) -> void:
	_in_physics = false

func _note_physics(_delta: float) -> void:
	_in_physics = true

# ---------------------------------------------------------------------------
# Behaviour registry
# ---------------------------------------------------------------------------

func _register_behaviour(b: Node) -> void:
	if not _behaviours.has(b):
		_behaviours.append(b)
	provider._on_behaviour_registered(b)

func _unregister_behaviour(b: Node) -> void:
	_behaviours.erase(b)

## All live converted behaviours.
func behaviours() -> Array:
	var out: Array = []
	for b in _behaviours:
		if is_instance_valid(b):
			out.append(b)
	return out

## Raise a VRChat world event (OnPlayerJoined, OnPlayerLeft, OnPlayerRespawn, ...) on every behaviour.
func broadcast_event(event_name: String, args: Array = []) -> void:
	for b in behaviours():
		if b.has_method(event_name):
			b.callv(event_name, args)

# ---------------------------------------------------------------------------
# Players
# ---------------------------------------------------------------------------

func local_player():
	return provider.local_player()

func master():
	return provider.master()

func instance_owner():
	return provider.instance_owner()

func is_master() -> bool:
	var lp = local_player()
	return lp != null and lp.is_master

func is_instance_owner() -> bool:
	var lp = local_player()
	return lp != null and lp.is_instance_owner

func get_player_by_id(id: int):
	return provider.get_player_by_id(id)

func get_players(into: Array) -> Array:
	var players: Array = provider.get_players()
	if into == null:
		return players
	into.resize(maxi(into.size(), players.size()))
	for i in range(players.size()):
		into[i] = players[i]
	return into

func player_count() -> int:
	return provider.get_players().size()

func get_players_with_tag(tag_name: String, value: String) -> Array:
	var out: Array = []
	for p in provider.get_players():
		if p.get_player_tag(tag_name) == value:
			out.append(p.player_id)
	return out

## `Utilities.IsValid` / `player.IsValid()` — accepts players, nodes and nulls.
func is_valid(obj) -> bool:
	if obj == null:
		return false
	if obj is Object:
		if not is_instance_valid(obj):
			return false
		if obj.has_method("is_valid"):
			return obj.is_valid()
		return true
	return true

func player_eq(a, b) -> bool:
	if a == null or b == null:
		return a == b
	if not (is_instance_valid(a) and is_instance_valid(b)):
		return a == b
	if a.has_method("get_player_id") or "player_id" in a:
		return a.player_id == b.player_id
	return a == b

# ---------------------------------------------------------------------------
# Ownership & networking
# ---------------------------------------------------------------------------

func is_owner(node: Node) -> bool:
	return provider.is_owner(local_player(), node)

func is_owner_player(player, node: Node) -> bool:
	return provider.is_owner(player, node)

func owner_of(node: Node):
	return provider.owner_of(node)

func transfer_owner(player, node: Node) -> void:
	var prev = provider.owner_of(node)
	provider.set_owner_of(player, node)
	if prev != player:
		_ownership_transferred(node, player)

func _ownership_transferred(node: Node, player) -> void:
	# Every behaviour on the object hears OnOwnershipTransferred.
	for b in behaviours():
		if b == node or b.is_ancestor_of(node) and b.get_parent() == node.get_parent():
			if b.has_method("OnOwnershipTransferred"):
				b.call("OnOwnershipTransferred", player)
	if node.has_method("OnOwnershipTransferred") and not _behaviours.has(node):
		node.call("OnOwnershipTransferred", player)

func is_object_ready(node: Node) -> bool:
	return provider.is_object_ready(node)

func get_unique_name(node: Node) -> String:
	return String(node.get_path())

func server_time_ms() -> int:
	return provider.server_time_ms()

func server_time_s() -> float:
	return float(provider.server_time_ms()) / 1000.0

func server_delta_time(t1: float, t2: float) -> float:
	return t1 - t2

func network_date_time() -> Dictionary:
	return U.datetime_now(true)

func simulation_time(_node: Node) -> float:
	return float(provider.server_time_ms()) / 1000.0

func simulation_time_player(_player) -> float:
	return float(provider.server_time_ms()) / 1000.0

func is_clogged() -> bool:
	return provider.is_clogged()

func is_network_settled() -> bool:
	return provider.is_network_settled()

func calling_player():
	return _calling_player

func in_network_call() -> bool:
	return _in_network_call > 0

func _begin_network_call(sender) -> void:
	_calling_player = sender
	_in_network_call += 1

func _end_network_call() -> void:
	_in_network_call -= 1
	if _in_network_call <= 0:
		_in_network_call = 0
		_calling_player = null

## Route SendCustomNetworkEvent through the provider. Local targets are delivered immediately.
func send_network_event(behaviour: Node, target: int, event_name: String, args: Array) -> void:
	var lp = local_player()
	match target:
		NetworkEventTarget_Self:
			behaviour._udon_receive_network_event(event_name, args, lp)
		NetworkEventTarget_Owner:
			if is_owner(behaviour):
				behaviour._udon_receive_network_event(event_name, args, lp)
			else:
				provider.send_network_event(behaviour, target, event_name, args)
		NetworkEventTarget_All:
			behaviour._udon_receive_network_event(event_name, args, lp)
			provider.send_network_event(behaviour, NetworkEventTarget_Others, event_name, args)
		_:
			provider.send_network_event(behaviour, target, event_name, args)

## Called by the provider when a remote event arrives.
func receive_network_event(behaviour: Node, event_name: String, args: Array, sender) -> void:
	if is_instance_valid(behaviour) and behaviour.has_method("_udon_receive_network_event"):
		if not behaviour.udon_network_callable().has(event_name) and not args.is_empty():
			push_warning("network event '%s' with arguments on %s is not [NetworkCallable]" % [event_name, behaviour.name])
		behaviour._udon_receive_network_event(event_name, args, sender)

## Serialize a behaviour's synced variables through the provider. Returns a SerializationResult.
func serialize(behaviour: Node, data: Dictionary) -> Dictionary:
	return provider.serialize(behaviour, data)

## Called by the provider when a remote snapshot arrives.
func receive_serialization(behaviour: Node, data: Dictionary, result: Dictionary = {}) -> void:
	if is_instance_valid(behaviour) and behaviour.has_method("udon_deserialize"):
		behaviour.udon_deserialize(data, result)

# ---------------------------------------------------------------------------
# Objects
# ---------------------------------------------------------------------------

func instantiate(node: Node) -> Node:
	return provider.instantiate(node, null, Vector3.ZERO, Quaternion(), false)

func instantiate_in(node: Node, parent: Node, world_position_stays: bool = false) -> Node:
	return provider.instantiate(node, parent, Vector3.ZERO, Quaternion(), world_position_stays)

func instantiate_at(node: Node, pos: Vector3, rot: Quaternion, parent: Node = null) -> Node:
	var n: Node = provider.instantiate(node, parent, pos, rot, false)
	if n is Node3D:
		n.global_position = pos
		U.set_global_rotation(n, rot)
	return n

func destroy(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	if node is Node:
		provider.destroy(node)

func destroy_delayed(node, delay: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var t := get_tree().create_timer(delay)
	t.timeout.connect(func(): destroy(node))

func get_player_objects(player) -> Array:
	return provider.get_player_objects(player)

func find_component_in_player_objects(player, component):
	for go in provider.get_player_objects(player):
		var c = U.get_component_in_children(go, U.type_of(component), true)
		if c != null:
			return c
	return null

# ---------------------------------------------------------------------------
# Component adapters
# ---------------------------------------------------------------------------

func pickup(node: Node):
	return provider.pickup(node)

## Does `node` carry the VRC component `kind` ("pickup", "station", "object_sync", "object_pool",
## "video", ...)? See UdonWorldProvider.has_adapter.
func has_component(node: Node, kind: String) -> bool:
	return provider.has_adapter(node, kind)

func station(node: Node):
	return provider.station(node)

func object_sync(node: Node):
	return provider.object_sync(node)

func object_pool(node: Node):
	return provider.object_pool(node)

func video(node: Node):
	return provider.video(node)

func avatar_pedestal_use(node: Node, player) -> void:
	provider.avatar_pedestal_use(node, player)

func avatar_pedestal_switch(node: Node, id: String) -> void:
	provider.avatar_pedestal_switch(node, id)

func screen_camera():
	return provider.screen_camera()

func new_image_downloader():
	return provider.new_image_downloader()

func load_url_string(url: String, behaviour: Node):
	return provider.load_url_string(url, behaviour)

# ---------------------------------------------------------------------------
# Input (Unity Input class)
# ---------------------------------------------------------------------------

func get_key(keycode: int) -> bool:
	return provider.get_key(keycode)

func get_key_down(keycode: int) -> bool:
	return provider.get_key_down(keycode)

func get_key_up(keycode: int) -> bool:
	return provider.get_key_up(keycode)

func get_key_name(key_name: String) -> bool:
	return provider.get_key(U.keycode_from_name(key_name))

func get_key_name_down(key_name: String) -> bool:
	return provider.get_key_down(U.keycode_from_name(key_name))

func get_key_name_up(key_name: String) -> bool:
	return provider.get_key_up(U.keycode_from_name(key_name))

func get_axis(axis: String) -> float:
	return provider.get_axis(axis)

func get_axis_raw(axis: String) -> float:
	return provider.get_axis(axis)

func get_button(button: String) -> bool:
	return provider.get_button(button, 0)

func get_button_down(button: String) -> bool:
	return provider.get_button(button, 1)

func get_button_up(button: String) -> bool:
	return provider.get_button(button, 2)

func get_mouse_button(index: int) -> bool:
	return provider.get_mouse_button(index, 0)

func get_mouse_button_down(index: int) -> bool:
	return provider.get_mouse_button(index, 1)

func get_mouse_button_up(index: int) -> bool:
	return provider.get_mouse_button(index, 2)

func mouse_position() -> Vector3:
	var p: Vector2 = provider.mouse_position()
	return Vector3(p.x, p.y, 0.0)

func mouse_scroll_delta() -> Vector2:
	return provider.mouse_scroll_delta()

func any_key() -> bool:
	return provider.any_key(false)

func any_key_down() -> bool:
	return provider.any_key(true)

func is_using_hand_controller() -> bool:
	return provider.is_using_hand_controller()

func last_input_method() -> int:
	return provider.last_input_method()

func enable_object_highlight(node, enabled: bool) -> void:
	provider.enable_object_highlight(node, enabled)

# ---------------------------------------------------------------------------
# Persistence (PlayerData)
# ---------------------------------------------------------------------------

func player_data_set(key: String, value) -> void:
	provider.player_data_set(key, value)

func player_data_get(player, key: String, default):
	return provider.player_data_get(player, key, default)

func player_data_has(player, key: String) -> bool:
	return provider.player_data_has(player, key)

func player_data_remove(key: String) -> void:
	provider.player_data_remove(key)

# ---------------------------------------------------------------------------
# Cross-class statics (when class_name is not emitted)
# ---------------------------------------------------------------------------

func register_class(class_name_: String, script: Script) -> void:
	_static_registry[class_name_] = script

func call_static(class_name_: String, method: String, args: Array):
	var s = _static_registry.get(class_name_)
	if s == null:
		push_error("Udon.call_static: class '%s' is not registered (Udon.register_class)" % class_name_)
		return null
	return s.callv(method, args)

func static_get(class_name_: String, member: String):
	var s = _static_registry.get(class_name_)
	if s == null:
		return null
	return s.get(member)

# ---------------------------------------------------------------------------
# Extras: network statistics, MIDI, economy, menus, player objects
# ---------------------------------------------------------------------------

## VRC NetworkStats: a provider may override `network_stat(key)`; defaults are zero.
func network_stat(key: String, default):
	if provider.has_method("network_stat"):
		return provider.network_stat(key, default)
	return default

## VRCMidiPlayer commands are forwarded to the provider (`midi_command(node, cmd, args)`).
func midi_command(node: Node, cmd: String, args: Array):
	if provider.has_method("midi_command"):
		return provider.midi_command(node, cmd, args)
	match cmd:
		"is_playing":
			return false
		"get_time":
			return 0.0
		"data":
			return {"tracks": [], "tempo": 120.0, "total_time": 0.0}
		_:
			return null

## VRC Economy (Store / UdonProduct): forwarded to the provider; defaults own nothing.
func economy(cmd: String, args: Array):
	if provider.has_method("economy"):
		return provider.economy(cmd, args)
	match cmd:
		"is_owned", "player_owns", "any_owns":
			return false
		"owners", "world_products":
			return []
		_:
			return null

func open_menu(node: Node) -> void:
	if provider.has_method("open_menu"):
		provider.open_menu(node)

func player_data_all(player) -> Array:
	var out: Array = []
	if player == null:
		return out
	for k in provider._player_data.get(player.player_id, {}).keys():
		out.append({"Key": k, "State": 0, "Owner": player})
	return out

func player_object_init(node: Node) -> void:
	if provider.has_method("player_object_init"):
		provider.player_object_init(node)

func players_in_range(pos: Vector3, radius: float) -> Array:
	var out: Array = []
	for p in provider.get_players():
		if p.get_position().distance_to(pos) <= radius:
			out.append(p)
	return out
