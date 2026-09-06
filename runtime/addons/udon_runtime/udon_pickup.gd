## `VRC_Pickup` surface. Default adapter over a plain node; a game may return its own object
## from `UdonWorldProvider.pickup()` as long as it exposes these members.
extends RefCounted

var node: Node = null
## Set by a networked provider to replicate grab/drop.
var provider = null
var is_held: bool = false
var current_player = null
var current_hand: int = 0          # PickupHand: None=0 Left=1 Right=2
var pickupable: bool = true
var interaction_text: String = ""
var use_text: String = "Use"
var proximity: float = 2.0
var orientation: int = 0           # PickupOrientation: Any=0 Grip=1 Gun=2
var disallow_theft: bool = false
var exact_grip: Node3D = null
var exact_gun: Node3D = null
var auto_hold: int = 0             # AutoHoldMode: AutoDetect=0 Yes=1 No=2
var allow_manipulation_when_equipped: bool = false
var throw_boost_min_speed: float = 1.0
var throw_boost_scale: float = 1.0

func _init(n: Node = null) -> void:
	node = n

## Called by the game when the local player grabs the object.
func pick_up(player, hand: int) -> void:
	is_held = true
	current_player = player
	current_hand = hand
	if provider != null and provider.has_method("replicate_pickup"):
		provider.replicate_pickup(node, true, hand)
	_dispatch("OnPickup")

func drop(_player = null) -> void:
	if not is_held:
		return
	is_held = false
	current_player = null
	current_hand = 0
	if provider != null and provider.has_method("replicate_pickup"):
		provider.replicate_pickup(node, false, 0)
	_dispatch("OnDrop")

func use_down() -> void:
	_dispatch("OnPickupUseDown")

func use_up() -> void:
	_dispatch("OnPickupUseUp")

func generate_haptic_event(_duration: float, _amplitude: float, _frequency: float) -> void:
	pass

func _dispatch(event_name: String) -> void:
	if node != null and node.has_method(event_name):
		node.call(event_name)
