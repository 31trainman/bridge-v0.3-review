# bridge.gd — TCP command bridge (Agent X Bridge v0.3)
# Uses Godot 4 APIs: TCPServer.listen/is_connection_available/take_connection,
# StreamPeerTCP.get_status. Binds to localhost ONLY (fix #8: no remote access).
extends Node

const PORT := 9123
const MAX_LINE_BYTES := 16384
const MAX_CONNECTIONS_HELD := 4

var server := TCPServer.new()
var clients: Array = []   # [{peer: StreamPeerTCP, buf: PackedByteArray}]

func _ready() -> void:
	# Binding to 127.0.0.1: unreachable from the network (fix #8).
	if server.listen(PORT, "127.0.0.1") != OK:
		push_error("Bridge: could not listen on port %d" % PORT)
		set_process(false)
		return

func _process(_delta: float) -> void:
	if server.is_listening():
		while server.is_connection_available() and clients.size() < MAX_CONNECTIONS_HELD:
			var peer := server.take_connection()
			clients.append({"peer": peer, "buf": PackedByteArray()})
	# Read + drop dead connections
	var i := clients.size() - 1
	while i >= 0:
		var c = clients[i]
		var peer: StreamPeerTCP = c["peer"]
		# fix #5: poll status and clean up failed/closed peers
		var status := peer.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			peer.disconnect_from_host()
			clients.remove_at(i)
			i -= 1
			continue
		var available := peer.get_available_bytes()
		if available > 0:
			var buf: PackedByteArray = c["buf"]
			if buf.size() + available > MAX_LINE_BYTES:
				# oversized input: kill connection (fix #8)
				peer.disconnect_from_host()
				clients.remove_at(i)
				i -= 1
				continue
			buf.append_array(peer.get_data(available)[1])
			c["buf"] = buf
			# newline-delimited JSON commands
			var text := buf.get_string_from_utf8()
			var nl := text.find("\n")
			while nl != -1:
				var line := text.substr(0, nl).strip_edges()
				text = text.substr(nl + 1)
				if line != "":
					_handle_line(peer, line)
				nl = text.find("\n")
			c["buf"] = text.to_utf8_buffer()
		i -= 1

func _handle_line(peer: StreamPeerTCP, line: String) -> void:
	var parsed = JSON.parse_string(line)
	var response: Dictionary
	if typeof(parsed) != TYPE_DICTIONARY:
		response = {"ok": false, "reason": "invalid JSON"}
	else:
		# fix #8: single whitelisted dispatcher — no shell, no paths, no eval
		response = Forge.execute_command(parsed)
	var err := peer.put_data((JSON.stringify(response) + "\n").to_utf8_buffer())
	if err != OK:
		push_warning("Bridge: failed to send response (%d)" % err)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		for c in clients:
			c["peer"].disconnect_from_host()
		server.stop()
