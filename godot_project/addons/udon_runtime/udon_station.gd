## `VRCStation` surface (seats / vehicles).
extends RefCounted

var node: Node = null
var provider = null
var player_mobility: int = 0       # Mobility: Mobile=0 Immobilize=1 ImmobilizeForVehicle=2
var seated: bool = true
var disable_station_exit: bool = false
var can_use_station_from_station: bool = true
var enter_location: Node3D = null
var exit_location: Node3D = null
var occupant = null

func _init(n: Node = null) -> void:
	node = n

func use_station(player) -> void:
	if occupant != null:
		return
	occupant = player
	if player != null and player.node != null and node is Node3D:
		var loc: Node3D = enter_location if enter_location != null else node
		player.node.global_position = loc.global_position
	if provider != null and provider.has_method("replicate_station") and player != null and player.is_local:
		provider.replicate_station(node, true)
	_dispatch("OnStationEntered", player)

func exit_station(player) -> void:
	if occupant == null:
		return
	occupant = null
	if player != null and player.node != null and exit_location != null:
		player.node.global_position = exit_location.global_position
	if provider != null and provider.has_method("replicate_station") and player != null and player.is_local:
		provider.replicate_station(node, false)
	_dispatch("OnStationExited", player)

func _dispatch(event_name: String, player) -> void:
	if node != null and node.has_method(event_name):
		node.call(event_name, player)
