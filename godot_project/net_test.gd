extends SceneTree
## Two-process multiplayer test for UdonNetworkProvider.
##
##   godot --headless --path . -s net_test.gd -- host   [port]
##   godot --headless --path . -s net_test.gd -- client [port]
##
## Both processes load converted/Counter.sgd on /root/CounterHost. The client takes ownership,
## bumps the counter (RequestSerialization + SendCustomNetworkEvent(All)), and sets player data.
## Each side prints `  ok/FAIL` lines and `NET DONE: N failure(s)`.

var failures: int = 0
var role: String = "host"
var port: int = 27777
var _Udon: Node
var _U: Node
var net = null
var joined: Array = []
var left: Array = []
var owner_events: Array = []

func check(cond: bool, what: String) -> void:
	if cond:
		print("  ok   [%s] %s" % [role, what])
	else:
		failures += 1
		print("  FAIL [%s] %s" % [role, what])

func _init() -> void:
	ProjectSettings.set_setting("sandbox/binary_translation/auto_bake", false)
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		role = args[0]
	if args.size() > 1:
		port = int(args[1])
	await process_frame
	await process_frame
	_Udon = root.get_node("Udon")
	_U = root.get_node("U")
	# Loaded dynamically: a static class reference would compile the provider before the autoloads exist.
	net = load("res://addons/udon_runtime/udon_network_provider.gd").new()
	net.local_display_name = "Host" if role == "host" else "Client"
	net.sync_rate_hz = 20.0
	net.player_data_path = "user://net_test_%s.json" % role
	_Udon.set_provider(net)
	net.player_joined.connect(func(p): joined.append(p.player_id))
	net.player_left.connect(func(p): left.append(p.player_id))

	# Scene: the converted Counter on the same path in both processes.
	var script = load("res://converted/Counter.sgd")
	var target := Node3D.new()
	target.name = "Target"
	root.add_child(target)
	var host := Node3D.new()
	host.name = "CounterHost"
	host.set_script(script)
	host.set("target", target)
	host.set("other", host)
	root.add_child(host)
	await process_frame

	if role == "host":
		await run_host(host)
	else:
		await run_client(host)
	print("NET DONE: %d failure(s)" % failures)
	quit(1 if failures > 0 else 0)

func wait_until(pred: Callable, timeout_s: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_s * 1000.0:
		if pred.call():
			return true
		await process_frame
	return pred.call()

func run_host(host: Node) -> void:
	check(net.host(port) == OK, "host() on port %d" % port)
	check(_Udon.local_player() != null and _Udon.local_player().player_id == 1, "local player is peer 1")
	check(_Udon.is_master() and _Udon.is_owner(host), "host is master and default owner")
	check(joined == [1], "OnPlayerJoined fired for self on host")
	# Wait for the client to join.
	var ok := await wait_until(func(): return _Udon.player_count() == 2, 20.0)
	check(ok, "client joined (player count 2)")
	check(joined.size() == 2 and joined[1] != 1, "OnPlayerJoined fired for client")
	var client = _Udon.get_player_by_id(joined[1]) if joined.size() > 1 else null
	check(client != null and client.display_name == "Client", "client display name replicated")
	# The client requests ownership and bumps the counter.
	ok = await wait_until(func(): return not _Udon.is_owner(host), 15.0)
	check(ok, "ownership transferred to client (host no longer owner)")
	check(_Udon.owner_of(host) == client, "owner_of() is the client player")
	ok = await wait_until(func(): return host.get("count") == 1, 15.0)
	check(ok, "synced variable `count` arrived via RequestSerialization: " + str(host.get("count")))
	check(host.get("Total") >= 1, "network event OnBump(All) delivered on host: Total=" + str(host.get("Total")))
	check(host.get("_phase") == 5, "FieldChangeCallback property set on deserialization: _phase=" + str(host.get("_phase")))
	ok = await wait_until(func(): return _Udon.player_data_get(client, "score", 0) == 42, 15.0)
	check(ok, "PlayerData from client replicated to host")
	# Host sends an Owner-targeted event: must land on the client only.
	host.SendCustomNetworkEvent(0, "OnBump", [10])
	await process_frame
	check(host.get("Total") < 10, "Owner-targeted event not executed locally on non-owner host")
	# Continuous sync: host owns nothing here; check server time monotonic.
	var t1: int = _Udon.server_time_ms()
	await process_frame
	check(_Udon.server_time_ms() >= t1, "server time monotonic")
	# Wait for the client to leave.
	ok = await wait_until(func(): return left.size() == 1, 25.0)
	check(ok, "OnPlayerLeft fired when client disconnected")
	check(_Udon.is_owner(host), "ownership fell back to master after client left")

func run_client(host: Node) -> void:
	check(net.join("127.0.0.1", port) == OK, "join()")
	var ok := await wait_until(func(): return net.is_network_settled(), 20.0)
	check(ok, "connected and settled")
	check(_Udon.local_player() != null and _Udon.local_player().player_id != 1, "local player has a peer id")
	check(joined.has(1) and joined.has(_Udon.local_player().player_id), "OnPlayerJoined fired for host and self: " + str(joined))
	check(not _Udon.is_master(), "client is not master")
	check(_Udon.owner_of(host) != null and _Udon.owner_of(host).player_id == 1, "host owns the object initially")
	# Interact: SetOwner(local) → count++ → RequestSerialization → SendCustomNetworkEvent(All, OnBump)
	host.call("Interact")
	ok = await wait_until(func(): return _Udon.is_owner(host), 15.0)
	check(ok, "ownership granted to client (OnOwnershipRequest default true)")
	# Interact again now that we own it so serialization is accepted.
	host.set("count", 0)
	host.call("Interact")
	check(host.get("count") == 1, "count bumped locally")
	# Player data.
	_Udon.player_data_set("score", 42)
	check(_Udon.player_data_get(_Udon.local_player(), "score", 0) == 42, "PlayerData set locally")
	# Owner-targeted event from host must arrive here: wait for Total to include the +10.
	ok = await wait_until(func(): return host.get("Total") >= 11, 15.0)
	check(ok, "Owner-targeted event from host delivered to owner (client): Total=" + str(host.get("Total")))
	check(net.server_time_ms() > 0, "server time offset applied: %d" % net.server_time_ms())
	await create_timer(1.0).timeout
	net.leave()
