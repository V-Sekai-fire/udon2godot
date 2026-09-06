## `VRCObjectPool` surface: a fixed set of child nodes that are activated on spawn.
extends RefCounted

var node: Node = null
var pool: Array = []

func _init(n: Node = null) -> void:
	node = n
	if n != null:
		for c in n.get_children():
			pool.append(c)
			U.set_active(c, false)

func try_to_spawn() -> Node:
	for c in pool:
		if is_instance_valid(c) and not U.is_active(c):
			U.set_active(c, true)
			if c.has_method("OnSpawn"):
				c.call("OnSpawn")
			return c
	return null

func return_object(obj: Node) -> void:
	if obj != null and pool.has(obj):
		U.set_active(obj, false)

func shuffle() -> void:
	pool.shuffle()
