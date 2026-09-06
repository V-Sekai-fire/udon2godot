extends SceneTree
## Load every .sgd in one or more directories and report which fail to compile.
##   godot --headless --path godot_project -s compile_check.gd [-- res://dir ...]
func _init() -> void:
	ProjectSettings.set_setting("sandbox/binary_translation/auto_bake", false)
	await process_frame
	await process_frame
	var dirs: Array = OS.get_cmdline_user_args()
	if dirs.is_empty():
		dirs = ["res://converted_corpus"]
	var ok := 0
	var bad := 0
	for dir_path in dirs:
		var dir := DirAccess.open(dir_path)
		if dir == null:
			print("MISSING DIR: ", dir_path)
			continue
		dir.list_dir_begin()
		var files: Array = []
		var f := dir.get_next()
		while f != "":
			if f.ends_with(".sgd"):
				files.append(f)
			f = dir.get_next()
		files.sort()
		for name in files:
			var s = load(dir_path + "/" + name)
			var n := Node3D.new()
			n.set_script(s)
			root.add_child(n)
			var compiled: bool = n.has_method("udon_class")
			if compiled:
				ok += 1
				if dirs.size() > 1:
					print("COMPILED: ", dir_path, "/", name)
			else:
				bad += 1
				print("COMPILE FAILED: ", dir_path, "/", name)
			n.queue_free()
			await process_frame
	print("COMPILE CHECK: %d ok, %d failed" % [ok, bad])
	quit(bad)
