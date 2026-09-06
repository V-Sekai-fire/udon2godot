extends SceneTree
## Runs the converted coverage fixtures (tests/coverage/*.cs → converted_coverage/*.sgd).
## Each fixture exposes `RunTests()`, optionally `AfterFrames()`, and the fields
## `failures`, `failCount`, `total`. The runner builds the scene nodes each fixture expects.

var _U: Node
var _Udon: Node
var total_fail: int = 0
var total_checks: int = 0

func _init() -> void:
	ProjectSettings.set_setting("sandbox/binary_translation/auto_bake", false)
	await process_frame
	await process_frame
	_U = root.get_node("U")
	_Udon = root.get_node("Udon")
	var only: Array = OS.get_cmdline_user_args()
	var names: Array = ["TMath", "TMathB", "TStrings", "TArrays", "TTransform", "TPhysics", "TMedia", "TUI", "TVRC", "T2D"]
	for n in names:
		if not only.is_empty() and not only.has(n):
			continue
		await run_fixture(n)
	print("COVERAGE DONE: %d checks, %d failure(s)" % [total_checks, total_fail])
	quit(mini(total_fail, 125))

func run_fixture(name: String) -> void:
	var path := "res://converted_coverage/%s.sgd" % name
	var script = load(path)
	if script == null:
		print("== %s: LOAD FAILED" % name)
		total_fail += 1
		return
	var host := Node3D.new()
	host.name = "Host_" + name
	root.add_child(host)
	var target := Node3D.new()
	target.name = "T"
	target.set_script(script)
	_build_scene(name, target, host)
	host.add_child(target)
	if not target.has_method("RunTests"):
		print("== %s: COMPILE FAILED" % name)
		total_fail += 1
		host.queue_free()
		return
	_wire(name, target, host, script)
	await process_frame
	await process_frame
	target.call("RunTests")
	if target.has_method("AfterFrames"):
		if name == "TVRC":
			# a remote player joins after the tests ran
			var p = load("res://addons/udon_runtime/udon_player.gd").new()
			p.player_id = 2
			p.display_name = "Remote"
			_Udon.provider.add_player(p)
		var frames: int = 90 if name in ["TPhysics", "T2D"] else 8
		for i in range(frames):
			await process_frame
		target.call("AfterFrames")
	var fc: int = int(target.get("failCount"))
	var tot: int = int(target.get("total"))
	var fails: Array = target.get("failures")
	var done: bool = bool(target.get("done"))
	total_fail += fc
	total_checks += tot
	print("== %s: %d/%d passed%s" % [name, tot - fc, tot, "" if done else "  (ABORTED: RunTests did not finish)"])
	if not done:
		total_fail += 1
	for i in range(fc):
		print("   FAIL %s" % str(fails[i]))
	host.queue_free()
	await process_frame

func _box_body(name: String, size: Vector3, pos: Vector3, rigid: bool) -> CollisionObject3D:
	var b: CollisionObject3D = RigidBody3D.new() if rigid else StaticBody3D.new()
	b.name = name
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	cs.shape = sh
	b.add_child(cs)
	b.position = pos
	return b

func _build_scene(name: String, target: Node3D, host: Node3D) -> void:
	match name:
		"TTransform":
			var child := Node3D.new()
			child.name = "Child"
			var gc := Node3D.new()
			gc.name = "GrandChild"
			child.add_child(gc)
			target.add_child(child)
			var other := Node3D.new()
			other.name = "Other"
			host.add_child(other)
			target.add_child(_box_body("Body", Vector3.ONE, Vector3(0, 3, 0), true))
			var mesh := MeshInstance3D.new()
			mesh.name = "Mesh"
			mesh.mesh = BoxMesh.new()
			target.add_child(mesh)
		"TPhysics":
			var body := _box_body("Body", Vector3.ONE, Vector3(0, 5, 0), true)
			target.add_child(body)
			host.add_child(_box_body("Floor", Vector3(100, 1, 100), Vector3(0, -0.5, 0), false))
			var area := Area3D.new()
			area.name = "Trigger"
			var cs := CollisionShape3D.new()
			cs.shape = SphereShape3D.new()
			area.add_child(cs)
			area.position = Vector3(0, 1, 0)
			host.add_child(area)
		"TMedia":
			var audio := AudioStreamPlayer3D.new()
			audio.name = "Audio"
			var gen := AudioStreamWAV.new()
			gen.format = AudioStreamWAV.FORMAT_8_BITS
			gen.mix_rate = 8000
			var data := PackedByteArray()
			data.resize(8000)
			for i in range(8000):
				data[i] = int(127 + 100 * sin(i * 0.1))
			gen.data = data
			audio.stream = gen
			target.add_child(audio)
			var anim := AnimationPlayer.new()
			anim.name = "Anim"
			var lib := AnimationLibrary.new()
			var a := Animation.new()
			a.length = 2.0
			var tr := a.add_track(Animation.TYPE_VALUE)
			a.track_set_path(tr, "../Mesh:rotation")
			a.track_insert_key(tr, 0.0, Vector3.ZERO)
			a.track_insert_key(tr, 2.0, Vector3(0, TAU, 0))
			lib.add_animation("spin", a)
			anim.add_animation_library("", lib)
			target.add_child(anim)
			var ps := GPUParticles3D.new()
			ps.name = "Particles"
			ps.emitting = false
			ps.process_material = ParticleProcessMaterial.new()
			target.add_child(ps)
			var mesh := MeshInstance3D.new()
			mesh.name = "Mesh"
			mesh.mesh = BoxMesh.new()
			mesh.material_override = StandardMaterial3D.new()
			target.add_child(mesh)
			var light := OmniLight3D.new()
			light.name = "Light"
			target.add_child(light)
			var cam := Camera3D.new()
			cam.name = "Cam"
			cam.position = Vector3(0, 1, 5)
			target.add_child(cam)
			cam.make_current()
			var line := Node3D.new()
			line.name = "Line"
			target.add_child(line)
		"TUI":
			var layer := CanvasLayer.new()
			layer.name = "UI"
			host.add_child(layer)
			var lbl := Label.new()
			lbl.name = "Text"
			layer.add_child(lbl)
			var tmp := Label.new()
			tmp.name = "TMP"
			layer.add_child(tmp)
			var sl := HSlider.new()
			sl.name = "Slider"
			layer.add_child(sl)
			var tg := CheckBox.new()
			tg.name = "Toggle"
			layer.add_child(tg)
			var img := TextureRect.new()
			img.name = "Image"
			layer.add_child(img)
			var inp := LineEdit.new()
			inp.name = "Input"
			layer.add_child(inp)
			var dd := OptionButton.new()
			dd.name = "Dropdown"
			layer.add_child(dd)
			var rect := Control.new()
			rect.name = "Rect"
			layer.add_child(rect)
			var btn := Button.new()
			btn.name = "Button"
			layer.add_child(btn)
			var l3 := Label3D.new()
			l3.name = "Label3D"
			target.add_child(l3)
		"TVRC":
			var other := Node3D.new()
			other.name = "Other"
			host.add_child(other)
			for n in ["Pickup", "Station", "Synced"]:
				var nd := Node3D.new()
				nd.name = n
				host.add_child(nd)
			var pool := Node3D.new()
			pool.name = "Pool"
			for i in range(2):
				var c := Node3D.new()
				c.name = "Item%d" % i
				pool.add_child(c)
			host.add_child(pool)
		"T2D":
			# the fixture works in metres like Unity 2D; Godot's default 980 px/s² would tunnel
			PhysicsServer2D.area_set_param(root.world_2d.space, PhysicsServer2D.AREA_PARAM_GRAVITY, 9.8)
			var root2d := Node2D.new()
			root2d.name = "World2D"
			host.add_child(root2d)
			var body := RigidBody2D.new()
			body.name = "Body2D"
			var cs := CollisionShape2D.new()
			var circ := CircleShape2D.new()
			circ.radius = 0.5
			cs.shape = circ
			body.add_child(cs)
			body.position = Vector2(0, -5)
			root2d.add_child(body)
			var floor2d := StaticBody2D.new()
			floor2d.name = "Floor2D"
			var fcs := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = Vector2(200, 1)
			fcs.shape = rect
			floor2d.add_child(fcs)
			floor2d.position = Vector2(0, 0.5)
			root2d.add_child(floor2d)
		_:
			pass

func _wire(name: String, t: Node3D, host: Node3D, script) -> void:
	match name:
		"TTransform":
			t.set("child", t.get_node("Child"))
			var other := host.get_node("Other")
			other.set_script(script)
			t.set("other", other)
			t.set("body", t.get_node("Body"))
			t.set("meshObj", t.get_node("Mesh"))
		"TPhysics":
			t.set("body", t.get_node("Body"))
			t.set("floorCol", host.get_node("Floor"))
			t.set("trigger", host.get_node("Trigger"))
		"TMedia":
			t.set("audio", t.get_node("Audio"))
			t.set("clip", t.get_node("Audio").stream)
			t.set("animator", t.get_node("Anim"))
			t.set("particles", t.get_node("Particles"))
			t.set("meshRenderer", t.get_node("Mesh"))
			t.set("light", t.get_node("Light"))
			t.set("cam", t.get_node("Cam"))
			t.set("line", t.get_node("Line"))
		"TUI":
			var ui := host.get_node("UI")
			t.set("uiText", ui.get_node("Text"))
			t.set("tmpText", ui.get_node("TMP"))
			t.set("slider", ui.get_node("Slider"))
			t.set("toggle", ui.get_node("Toggle"))
			t.set("image", ui.get_node("Image"))
			t.set("input", ui.get_node("Input"))
			t.set("dropdown", ui.get_node("Dropdown"))
			t.set("rect", ui.get_node("Rect"))
			t.set("button", ui.get_node("Button"))
			t.set("label3d", t.get_node("Label3D"))
		"TVRC":
			var other := host.get_node("Other")
			other.set_script(script)
			t.set("other", other)
			t.set("pickupObj", host.get_node("Pickup"))
			t.set("stationObj", host.get_node("Station"))
			t.set("syncedObj", host.get_node("Synced"))
			t.set("poolObj", host.get_node("Pool"))
			# OnStationEntered goes to the behaviours on the station's own node: the fixture is the station
			t.set("stationObj", t)
			_Udon.station(t)
			_Udon.pickup(host.get_node("Pickup"))
			_Udon.object_sync(host.get_node("Synced"))
			_Udon.object_pool(host.get_node("Pool"))
		"T2D":
			t.set("body", host.get_node("World2D/Body2D"))
			t.set("floorCol", host.get_node("World2D/Floor2D"))
		_:
			pass
