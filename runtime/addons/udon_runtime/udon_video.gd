## `BaseVRCVideoPlayer` surface over a VideoStreamPlayer (or a game-provided player).
extends RefCounted

var node: Node = null
var is_playing: bool = false
var is_ready: bool = false
var loop: bool = false
var auto_resync: bool = true
var width: int = 0
var height: int = 0
var _url: String = ""

func _init(n: Node = null) -> void:
	node = n

func _vp() -> VideoStreamPlayer:
	if node is VideoStreamPlayer:
		return node
	if node != null:
		for c in node.get_children():
			if c is VideoStreamPlayer:
				return c
	return null

func load_url(url: String) -> void:
	_url = url
	is_ready = true
	_dispatch("OnVideoReady")

func play_url(url: String) -> void:
	load_url(url)
	play()

func play() -> void:
	var vp := _vp()
	if vp != null:
		vp.play()
	is_playing = true
	_dispatch("OnVideoStart")
	_dispatch("OnVideoPlay")

func pause() -> void:
	var vp := _vp()
	if vp != null:
		vp.paused = true
	is_playing = false
	_dispatch("OnVideoPause")

func stop() -> void:
	var vp := _vp()
	if vp != null:
		vp.stop()
	is_playing = false
	_dispatch("OnVideoEnd")

func get_time() -> float:
	var vp := _vp()
	return vp.stream_position if vp != null else 0.0

func set_time(t: float) -> void:
	var vp := _vp()
	if vp != null:
		vp.stream_position = t

func get_duration() -> float:
	var vp := _vp()
	return vp.get_stream_length() if vp != null else 0.0

func _dispatch(event_name: String) -> void:
	if node != null and node.has_method(event_name):
		node.call(event_name)
