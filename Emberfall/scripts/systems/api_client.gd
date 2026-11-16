extends Node

## REST client for the Emberfall account/cloud-save server.
##
## Autoloaded as `Api`. Requests are queued because a single HTTPRequest node
## can only handle one call at a time. The server URL can be set three ways,
## highest priority last:
##   1. DEFAULT_BASE_URL
##   2. user://emberfall_server.json  -> {"base_url": "https://..."}
##   3. EMBERFALL_API_URL environment variable (handy for tests/CI)

signal logged_in(token: String, account: Dictionary)
signal registered(token: String, account: Dictionary)
signal auth_failed(error: String)
signal characters_loaded(characters: Array)
signal character_loaded(character: Dictionary)
signal character_created(character: Dictionary)
signal character_create_failed(error: String)
signal character_deleted(character_id: int)
signal character_saved(saved_at: String)
signal save_failed(error: String)
signal request_failed(error: String)
signal friends_loaded(friends: Array)
signal friend_requests_loaded(requests: Array, sent: Array)
signal friend_request_sent(to_name: String)
signal friend_request_failed(error: String)
signal friend_responded(ok: bool)
signal friend_removed(ok: bool)
## Emitted when a server was found on the local network.
signal server_discovered(base_url: String)
## Emitted when the search for a server on the local network found nothing.
signal discovery_failed()

const DEFAULT_BASE_URL := "https://emberfall-production-4a8bfbd3.up.railway.app/api"
const CONFIG_PATH := "user://emberfall_server.json"
const REQUEST_TIMEOUT := 15.0

## Port the server answers discovery requests on.
const DISCOVERY_PORT := 7576
## Payload the server expects in a discovery request.
const DISCOVERY_MAGIC := "EMBERFALL_DISCOVER"
## Hosts that usually mean "the computer running the server": the standard
## Android emulator (10.0.2.2) and Genymotion (10.0.3.2) aliases for the
## host machine.
const DISCOVERY_HOSTS := ["10.0.2.2", "10.0.3.2"]
## How long the search for a server lasts.
const DISCOVERY_DURATION := 8.0
const DISCOVERY_PROBE_TIMEOUT := 5.0
## Set to false to skip the broadcast that asks the servers on the network.
const DISCOVERY_USE_BROADCAST := true

var base_url := DEFAULT_BASE_URL
var token := ""
var username := ""
var account_id := 0
var character_id := 0

var _http: HTTPRequest
var _queue: Array = []
var _busy := false
var _current: Dictionary = {}

# Server discovery state.
var _discovering := false
var _discovery_found := false
var _discovery_probes: Array = []
var _probed_urls: Array = []
var _udp_socket: PacketPeerUDP = null
var _discovery_until := 0


func _ready() -> void:
	_load_config()
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	# A phone cannot reach 127.0.0.1, so look for the server by itself.
	# The search waits for the first frame, otherwise the request would time
	# out before the game is running.
	if _is_mobile() and is_loopback():
		call_deferred("_start_auto_discovery")


## True on phones and tablets, where 127.0.0.1 means the device itself.
func _is_mobile() -> bool:
	var name := OS.get_name()
	return name == "Android" or name == "iOS"


## Starts the search once the game is running.
func _start_auto_discovery() -> void:
	print("[api] looking for a server, starting at %s" % base_url)
	discover_server()


func _load_config() -> void:
	if FileAccess.file_exists(CONFIG_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
		if typeof(parsed) == TYPE_DICTIONARY:
			var configured := str(parsed.get("base_url", "")).strip_edges()
			if not configured.is_empty() and not configured.contains("127.0.0.1") and not configured.contains("localhost"):
				base_url = configured
	var override := OS.get_environment("EMBERFALL_API_URL").strip_edges()
	if not override.is_empty():
		base_url = override
	base_url = base_url.rstrip("/")


## Points the client at a different server at runtime.
func set_base_url(url: String) -> void:
	base_url = url.strip_edges().rstrip("/")
	if base_url.is_empty():
		base_url = DEFAULT_BASE_URL


## Remembers the current server so the next launch keeps using it.
## On a phone the address is the PC's address on the shared Wi-Fi network,
## because 127.0.0.1 points at the phone itself.
func save_base_url() -> void:
	var file := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"base_url": base_url}))
	file.close()


## True when the server address points at this device (127.0.0.1 or localhost).
func is_loopback() -> bool:
	return base_url.contains("127.0.0.1") or base_url.contains("localhost")


# ---------------------------------------------------------------------------
# Server discovery
# ---------------------------------------------------------------------------

## Looks for the account server on the local network and switches to it.
## The emulator reaches the computer through 10.0.2.2, a phone on the same
## Wi-Fi is found through the discovery broadcast the server answers.
func discover_server() -> void:
	if _discovering:
		return
	_discovering = true
	_discovery_found = false
	_probed_urls.clear()
	_discovery_until = Time.get_ticks_msec() + int(DISCOVERY_DURATION * 1000.0)
	for url in _discovery_candidates():
		_start_probe(url)
	if not DISCOVERY_USE_BROADCAST:
		return
	_start_broadcast()


## Addresses to try: the emulator aliases and the current address.
func _discovery_candidates() -> Array:
	var candidates: Array = []
	var port := _base_port()
	for host in DISCOVERY_HOSTS:
		candidates.append("http://%s:%d/api" % [host, port])
	if not is_loopback():
		candidates.append(base_url)
	return candidates


## The port the current address uses, so a server on another port is found too.
func _base_port() -> int:
	var without_scheme := base_url
	if without_scheme.contains("://"):
		without_scheme = without_scheme.split("://")[1]
	if without_scheme.contains("/"):
		without_scheme = without_scheme.split("/")[0]
	if without_scheme.contains(":"):
		return int(without_scheme.split(":")[1])
	return 7575


## Asks every server on the network to identify itself.
func _start_broadcast() -> void:
	if _udp_socket != null:
		return
	_udp_socket = PacketPeerUDP.new()
	if _udp_socket.bind(0) != OK:
		_udp_socket = null
		return
	_udp_socket.set_broadcast_enabled(true)
	# The whole network first, then the alias the emulator uses for the
	# computer the game runs on.
	for host in ["255.255.255.255"] + DISCOVERY_HOSTS:
		_udp_socket.set_dest_address(host, DISCOVERY_PORT)
		_udp_socket.put_packet(DISCOVERY_MAGIC.to_utf8_buffer())


## Stops listening for answers.
func _stop_broadcast() -> void:
	if _udp_socket != null:
		_udp_socket.close()
		_udp_socket = null


## Asks one address whether a server is there.
func _start_probe(url: String) -> void:
	if _discovery_found:
		return
	if _probed_urls.has(url):
		return
	_probed_urls.append(url)
	var request := HTTPRequest.new()
	request.timeout = DISCOVERY_PROBE_TIMEOUT
	add_child(request)
	_discovery_probes.append({"request": request, "url": url})
	request.request_completed.connect(_on_probe_completed.bind(request, url))
	var err := request.request("%s/health" % url, PackedStringArray(["Accept: application/json"]), HTTPClient.METHOD_GET)
	if err != OK:
		_finish_probe(request)


## Removes a finished probe.
func _finish_probe(request: HTTPRequest) -> void:
	for entry in _discovery_probes:
		if entry["request"] == request:
			_discovery_probes.erase(entry)
			break
	request.queue_free()


## A candidate answered (or did not).
func _on_probe_completed(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray, request: HTTPRequest, url: String) -> void:
	_finish_probe(request)
	print("[api] probe %s -> result %d, code %d" % [url, result, code])
	if _discovery_found:
		return
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		_discovery_found = true
		_discovering = false
		set_base_url(url)
		save_base_url()
		_stop_broadcast()
		server_discovered.emit(url)


## Handles an answer from a server on the network.
func _handle_discovery_reply(packet: PackedByteArray) -> void:
	var text := packet.get_string_from_utf8()
	print("[api] discovery reply: %s" % text)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var urls: Variant = parsed.get("base_urls", [])
	if typeof(urls) != TYPE_ARRAY:
		return
	for entry in urls:
		var url := str(entry)
		if url.is_empty() or url == base_url:
			continue
		if _probed_urls.has(url):
			continue
		_probed_urls.append(url)
		_start_probe(url)


func _process(_delta: float) -> void:
	if _udp_socket != null:
		while _udp_socket.get_available_packet_count() > 0:
			_handle_discovery_reply(_udp_socket.get_packet())
	if _discovering and Time.get_ticks_msec() >= _discovery_until:
		_discovering = false
		_stop_broadcast()
		if not _discovery_found:
			discovery_failed.emit()


func has_session() -> bool:
	return not token.is_empty()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

func register(user: String, password: String) -> void:
	_enqueue(HTTPClient.METHOD_POST, "/register", {
		"username": user,
		"password": password,
	}, "register")


func login(user: String, password: String) -> void:
	_enqueue(HTTPClient.METHOD_POST, "/login", {
		"username": user,
		"password": password,
	}, "login")


func list_characters() -> void:
	_enqueue(HTTPClient.METHOD_GET, "/characters", null, "list")


func load_character(id: int) -> void:
	_enqueue(HTTPClient.METHOD_GET, "/characters/%d" % id, null, "load")


func create_character(character_name: String, player_class: String, data: Dictionary) -> void:
	_enqueue(HTTPClient.METHOD_POST, "/characters", {
		"name": character_name,
		"class": player_class,
		"data": data,
	}, "create")


func save_character(data: Dictionary) -> void:
	if character_id <= 0:
		save_failed.emit("No character is selected.")
		return
	_enqueue(HTTPClient.METHOD_PUT, "/characters/%d" % character_id, {
		"data": data,
	}, "save")


## Permanently removes a character from the account.
func delete_character(id: int) -> void:
	if id <= 0:
		request_failed.emit("No character is selected.")
		return
	_enqueue(HTTPClient.METHOD_DELETE, "/characters/%d" % id, null, "delete")


func list_friends() -> void:
	_enqueue(HTTPClient.METHOD_GET, "/friends", null, "friends_list")


func list_friend_requests() -> void:
	_enqueue(HTTPClient.METHOD_GET, "/friends/requests", null, "friends_requests")


func send_friend_request(username: String) -> void:
	_enqueue(HTTPClient.METHOD_POST, "/friends/request", {"username": username}, "friends_send")


func respond_friend_request(requester_id: int, accept: bool) -> void:
	_enqueue(HTTPClient.METHOD_POST, "/friends/respond", {"requester_id": requester_id, "accept": accept}, "friends_respond")


func remove_friend(account_id: int) -> void:
	_enqueue(HTTPClient.METHOD_DELETE, "/friends/%d" % account_id, null, "friends_remove")


func logout() -> void:
	token = ""
	username = ""
	account_id = 0
	character_id = 0
	_queue.clear()


# ---------------------------------------------------------------------------
# Request queue
# ---------------------------------------------------------------------------

func _full_url(path: String) -> String:
	return "%s%s" % [base_url, path]


func _enqueue(method: int, path: String, body: Variant, kind: String) -> void:
	_queue.append({
		"method": method,
		"path": path,
		"body": body,
		"kind": kind,
	})
	_pump()


func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	var job: Dictionary = _queue.pop_front()
	_current = job
	_busy = true

	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	if not token.is_empty():
		headers.append("Authorization: Bearer %s" % token)
	var body_text := ""
	if job["body"] != null:
		body_text = JSON.stringify(job["body"])

	var err := _http.request(_full_url(str(job["path"])), headers, int(job["method"]), body_text)
	if err != OK:
		_busy = false
		_current = {}
		_fail(job, "Could not contact the server (%d).%s" % [err, _connection_hint()])
		_pump()


## Extra explanation when the address cannot possibly be right.
func _connection_hint() -> String:
	if not _is_mobile():
		return ""
	if not is_loopback():
		return ""
	return " This device cannot reach 127.0.0.1; set the server address to the address of the computer running the server."


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_busy = false
	var job := _current
	_current = {}

	if result != HTTPRequest.RESULT_SUCCESS:
		_fail(job, "Could not reach the server.%s" % _connection_hint())
		_pump()
		return

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	var payload: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
	var kind := str(job.get("kind", ""))

	if response_code >= 200 and response_code < 300:
		_handle_success(kind, payload)
	else:
		var message := str(payload.get("error", ""))
		if message.is_empty():
			message = "Request failed (HTTP %d)." % response_code
		if kind == "login" or kind == "register":
			auth_failed.emit(message)
		elif kind == "save":
			save_failed.emit(message)
		elif kind == "create":
			character_create_failed.emit(message)
		elif kind == "friends_send":
			friend_request_failed.emit(message)
		else:
			request_failed.emit(message)
	_pump()


func _handle_success(kind: String, payload: Dictionary) -> void:
	match kind:
		"login":
			_accept_session(payload)
			logged_in.emit(token, payload.get("account", {}))
		"register":
			_accept_session(payload)
			registered.emit(token, payload.get("account", {}))
		"list":
			characters_loaded.emit(payload.get("characters", []))
		"load", "create":
			var character: Variant = payload.get("character", {})
			if typeof(character) != TYPE_DICTIONARY:
				request_failed.emit("Server returned an invalid character.")
				return
			character_id = int(character.get("id", 0))
			if kind == "load":
				character_loaded.emit(character)
			else:
				character_created.emit(character)
		"save":
			character_saved.emit(str(payload.get("saved_at", "")))
		"delete":
			var removed := int(payload.get("deleted", 0))
			if character_id == removed:
				character_id = 0
			character_deleted.emit(removed)
		"friends_list":
			friends_loaded.emit(payload.get("friends", []))
		"friends_requests":
			friend_requests_loaded.emit(payload.get("requests", []), payload.get("sent", []))
		"friends_send":
			friend_request_sent.emit(str(payload.get("to", "")))
		"friends_respond":
			friend_responded.emit(true)
		"friends_remove":
			friend_removed.emit(true)
		_:
			pass


func _accept_session(payload: Dictionary) -> void:
	token = str(payload.get("token", ""))
	var account: Variant = payload.get("account", {})
	if typeof(account) == TYPE_DICTIONARY:
		account_id = int(account.get("id", 0))
		username = str(account.get("username", ""))


func _fail(job: Dictionary, message: String) -> void:
	match str(job.get("kind", "")):
		"login", "register":
			auth_failed.emit(message)
		"save":
			save_failed.emit(message)
		"create":
			character_create_failed.emit(message)
		_:
			request_failed.emit(message)
