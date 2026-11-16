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

## Switches GameState/API into online mode for an authenticated character.
func go_online(token: String, character_id: int) -> void:
	if token.is_empty() or character_id <= 0:
		connection_failed.emit("Missing session or character.")
		return
	online_mode = true
	online_character_id = character_id
	Api.token = token
	Api.character_id = character_id
	online_ready.emit(character_id)

## Returns to local-only saves without dropping the API session token.
func go_offline() -> void:
	if not online_mode:
		return
	online_mode = false
	online_character_id = 0
	online_ended.emit()

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
	if multiplayer_peer != null:
		multiplayer_peer.close_connections()
		multiplayer_peer = null
	multiplayer.multiplayer_peer = null
	is_server = false
	our_id = 1
	connected_peers.clear()
	disconnected.emit()
