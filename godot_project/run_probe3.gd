extends SceneTree
func _init() -> void:
	ProjectSettings.set_setting("sandbox/binary_translation/auto_bake", false)
	await process_frame
	await process_frame
	var s = load("res://probes/p_reentry.sgd")
	var a := Node.new(); a.set_script(s); root.add_child(a)
	var b := Node.new(); b.set_script(s); root.add_child(b)
	for m in ["ping", "ping2", "ping3", "ping4", "ping8"]:
		print("PROBE ", m, " -> ", a.call(m, b))
	quit(0)
