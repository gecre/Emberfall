extends Node

## Emitted when hosting or joining succeeds.
signal connected(is_server: bool, our_id: int)
## Emitted when a remote peer connects.
signal peer_connected(peer_id: int)
## Emitted when a remote peer disconnects.
signal peer_disconnected(peer_id: int)
## Emitted when the local peer disconnects.
signal disconnected
## Emitted when host/join fails.
signal connection_failed(reason: String)
## Emitted when cloud-save mode is enabled for an authenticated character.
signal online_ready(character_id: int)
## Emitted when cloud-save mode is turned off.
signal online_ended

# Real-time WebSocket stage relay signals
signal stage_players_received(stage: int, players: Array)
signal remote_player_joined(player_data: Dictionary)
signal remote_player_moved(id: int, pos: Vector2, vel: Vector2, facing: float, swing: bool)
signal remote_player_left(id: int)
## Emitted when a chat message arrives. channel = "stage" | "global" | "whisper"
signal chat_message_received(channel: String, sender_name: String, whisper_to: String, text: String)

# Trading & Street Stalls signals
signal trade_requested(from_id: int, from_name: String)
signal trade_responded(from_id: int, from_name: String, accepted: bool)
signal trade_offer_updated(from_id: int, items: Array, gold: int, locked: bool)
signal trade_confirmed_by_partner(from_id: int)
signal trade_cancelled_by_partner(from_id: int)
signal player_stall_changed(peer_id: int, stall_data: Variant)
signal stall_buy_completed(success: bool, item: Dictionary, price: int, error: String)
signal stall_item_sold_notification(buyer_name: String, item: Dictionary, price: int)
signal friend_notify_received(from_name: String, message: String)

const MAX_PLAYERS := 8
const DEFAULT_PORT := 7576

var multiplayer_peer: ENetMultiplayerPeer = null
var is_server := false
var our_id: int = 1
## Peer IDs of connected remote peers (excludes self).
var connected_peers: Array = []
## True while the local character is backed by the account server.
var online_mode := false
var online_character_id := 0

# WebSocket relay state
var _ws := WebSocketPeer.new()
var _current_stage := 0
var _last_spawn_pos := Vector2.ZERO
var _reconnect_timer := 0.0
var _was_connected := false


func _ready() -> void:
	pass


func _process(delta: float) -> void:
	if not online_mode:
		return

	_ws.poll()
	var state := _ws.get_ready_state()

	if state == WebSocketPeer.STATE_OPEN:
		if not _was_connected:
			_was_connected = true
			if _current_stage > 0:
				_send_stage_join()

		while _ws.get_available_packet_count() > 0:
			var packet := _ws.get_packet()
			var text := packet.get_string_from_utf8()
			var parsed: Variant = JSON.parse_string(text)
			if typeof(parsed) == TYPE_DICTIONARY:
				_handle_ws_message(parsed)

	elif state == WebSocketPeer.STATE_CLOSED:
		if _was_connected:
			_was_connected = false
		_reconnect_timer += delta
		if _reconnect_timer >= 3.0:
			_reconnect_timer = 0.0
			_connect_ws()


## Gets the matching wss:// or ws:// URL from Api.base_url.
func _get_ws_url() -> String:
	var base := Api.base_url.strip_edges()
	var url := base
	if url.ends_with("/api"):
		url = url.substr(0, url.length() - 4)
	if url.begins_with("https://"):
		url = "wss://" + url.substr(8)
	elif url.begins_with("http://"):
		url = "ws://" + url.substr(7)
	return url.rstrip("/") + "/ws"


func _connect_ws() -> void:
	var url := _get_ws_url()
	var err := _ws.connect_to_url(url)
	if err != OK:
		print("[network] Could not connect WebSocket: %d" % err)


func _handle_ws_message(msg: Dictionary) -> void:
	var type := str(msg.get("type", ""))
	match type:
		"error":
			var err_text := str(msg.get("error", "Network error"))
			print("[network] Server error: %s" % err_text)
			connection_failed.emit(err_text)
			online_mode = false
			_ws.close()

		"welcome":
			our_id = int(msg.get("id", 1))

		"stage_players":
			var stage := int(msg.get("stage", 1))
			var players: Array = msg.get("players", [])
			stage_players_received.emit(stage, players)

		"player_joined":
			remote_player_joined.emit(msg)

		"player_moved":
			var id := int(msg.get("id", 0))
			var p_arr: Array = msg.get("pos", [0, 0])
			var v_arr: Array = msg.get("vel", [0, 0])
			var pos := Vector2(float(p_arr[0]), float(p_arr[1]))
			var vel := Vector2(float(v_arr[0]), float(v_arr[1]))
			var facing := float(msg.get("facing", 1.0))
			var swing := bool(msg.get("swing", false))
			remote_player_moved.emit(id, pos, vel, facing, swing)

		"player_left":
			var id := int(msg.get("id", 0))
			remote_player_left.emit(id)

		"chat":
			var channel := str(msg.get("channel", "stage"))
			var sname := str(msg.get("name", "Someone"))
			var whisper_to := str(msg.get("whisper_to", ""))
			var text := str(msg.get("text", ""))
			chat_message_received.emit(channel, sname, whisper_to, text)

		"trade_request":
			var from_id := int(msg.get("from_id", 0))
			var from_name := str(msg.get("from_name", "Player"))
			trade_requested.emit(from_id, from_name)

		"trade_response":
			var from_id := int(msg.get("from_id", 0))
			var from_name := str(msg.get("from_name", "Player"))
			var accepted := bool(msg.get("accepted", false))
			trade_responded.emit(from_id, from_name, accepted)

		"trade_offer":
			var from_id := int(msg.get("from_id", 0))
			var items: Array = msg.get("items", [])
			var gold := int(msg.get("gold", 0))
			var locked := bool(msg.get("locked", false))
			trade_offer_updated.emit(from_id, items, gold, locked)

		"trade_confirm":
			var from_id := int(msg.get("from_id", 0))
			trade_confirmed_by_partner.emit(from_id)

		"trade_cancel":
			var from_id := int(msg.get("from_id", 0))
			trade_cancelled_by_partner.emit(from_id)

		"player_stall_updated":
			var pid := int(msg.get("id", 0))
			var stall: Variant = msg.get("stall")
			player_stall_changed.emit(pid, stall)

		"stall_buy_result":
			var success := bool(msg.get("success", false))
			var it: Dictionary = msg.get("item", {})
			var pr := int(msg.get("price", 0))
			var err := str(msg.get("error", ""))
			stall_buy_completed.emit(success, it, pr, err)

		"stall_item_sold":
			var bname := str(msg.get("buyer_name", "Someone"))
			var it: Dictionary = msg.get("item", {})
			var pr := int(msg.get("price", 0))
			stall_item_sold_notification.emit(bname, it, pr)

		"friend_notify":
			var from_name := str(msg.get("from_name", ""))
			var message := str(msg.get("message", ""))
			friend_notify_received.emit(from_name, message)


func _send_json(data: Dictionary) -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(data))


func _send_stage_join() -> void:
	_send_json({
		"type": "join_stage",
		"stage": _current_stage,
		"name": GameState.player_name,
		"account_name": Api.username,
		"class": GameState.player_class,
		"level": GameState.level,
		"equipment": GameState.equipment,
		"pos": [_last_spawn_pos.x, _last_spawn_pos.y]
	})


## Switches GameState/API and real-time multiplayer into online mode.
func go_online(token: String, character_id: int) -> void:
	if token.is_empty() or character_id <= 0:
		connection_failed.emit("Missing session or character.")
		return
	online_mode = true
	online_character_id = character_id
	Api.token = token
	Api.character_id = character_id
	_reconnect_timer = 0.0
	_connect_ws()
	online_ready.emit(character_id)


## Returns to local-only saves and closes WebSocket relay.
func go_offline() -> void:
	if not online_mode:
		return
	online_mode = false
	online_character_id = 0
	_current_stage = 0
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_json({"type": "leave_stage"})
		_ws.close()
	online_ended.emit()


## Registers the local player into a stage room on the server.
func join_stage(stage_number: int, spawn_pos: Vector2 = Vector2.ZERO) -> void:
	_current_stage = stage_number
	_last_spawn_pos = spawn_pos
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send_stage_join()


## Broadcasts current position, velocity, facing and swing to same-stage peers.
func send_movement(pos: Vector2, vel: Vector2, facing: float, swing: bool) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({
		"type": "move",
		"pos": [pos.x, pos.y],
		"vel": [vel.x, vel.y],
		"facing": facing,
		"swing": swing
	})


## Broadcasts a chat message to everyone in the current stage.
func send_chat(text: String) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({
		"type": "chat",
		"text": text
	})


## Broadcasts a chat message to all players on the server.
func send_global_chat(text: String) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({
		"type": "global_chat",
		"text": text
	})


## Sends a private whisper to a player by name.
func send_whisper(target_name: String, text: String) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({
		"type": "whisper",
		"target": target_name,
		"text": text
	})


# --- Trading ---
func request_trade(target_id: int) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({"type": "trade_request", "target_id": target_id})


func respond_trade(target_id: int, accept: bool) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({"type": "trade_response", "target_id": target_id, "accepted": accept})


func send_trade_offer(target_id: int, items: Array, gold: int, locked: bool) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({
		"type": "trade_offer",
		"target_id": target_id,
		"items": items,
		"gold": gold,
		"locked": locked
	})


func confirm_trade(target_id: int) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({"type": "trade_confirm", "target_id": target_id})


func cancel_trade(target_id: int) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({"type": "trade_cancel", "target_id": target_id})


# --- Street Stalls (Player Shops) ---
func open_stall(title: String, items: Array) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({
		"type": "stall_open",
		"title": title,
		"items": items
	})


func close_stall() -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({"type": "stall_close"})


func buy_from_stall(seller_id: int, item_name: String) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({
		"type": "stall_buy",
		"seller_id": seller_id,
		"item_name": item_name
	})


func notify_friend_request(target_name: String) -> void:
	if not online_mode or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_send_json({
		"type": "friend_notify",
		"target_name": target_name,
		"message": "%s sent you a friend request!" % GameState.player_name
	})


# --- Legacy ENet P2P support (kept intact) ---
func host(port: int = DEFAULT_PORT) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		connection_failed.emit("Host failed (%d)" % err)
		return
	_bind(peer)
	is_server = true
	our_id = 1
	connected.emit(true, our_id)


func join(address: String, port: int = DEFAULT_PORT) -> void:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		connection_failed.emit("Join failed (%d)" % err)
		return
	_bind(peer)
	is_server = false
	our_id = multiplayer.get_unique_id()
	connected.emit(false, our_id)


func _bind(peer: ENetMultiplayerPeer) -> void:
	multiplayer_peer = peer
	multiplayer.multiplayer_peer = peer
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)


func _on_peer_connected(id: int) -> void:
	if id == multiplayer.get_unique_id():
		return
	if not connected_peers.has(id):
		connected_peers.append(id)
		peer_connected.emit(id)


func _on_peer_disconnected(id: int) -> void:
	if id == multiplayer.get_unique_id():
		return
	connected_peers.erase(id)
	peer_disconnected.emit(id)


func shutdown() -> void:
	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.close()
	if multiplayer_peer != null:
		multiplayer_peer.close_connections()
		multiplayer_peer = null
	multiplayer.multiplayer_peer = null
	is_server = false
	our_id = 1
	connected_peers.clear()
	disconnected.emit()
