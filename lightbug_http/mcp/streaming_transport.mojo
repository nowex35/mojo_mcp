from memory import Span
from lightbug_http.io.bytes import bytes, Bytes, ByteView
from lightbug_http.streaming.streamable_service import StreamableHTTPService
from lightbug_http.streaming.streamable_exchange import StreamableHTTPExchange
from .jsonrpc import JSONRPCRequest, JSONRPCResponse, JSONRPCNotification, parse_error, invalid_request, internal_error
from .parser import JSONRPCParser, JSONRPCSerializer, MessageType
from .server import MCPServer

@value
struct SSEEvent:
    var id: UInt64
    var type: String
    var data: String

@value
struct StreamingTransport(StreamableHTTPService):
    """Streaming HTTP transport for MCP.

    This transport handles:
    - HTTP POST requests for client-to-server communication
    - Chunked transfer encoding for large responses
    - Server-Sent Events for real-time updates
    - Content-Type validation (application/json)
    - Session management via Mcp-Session-Id headers
    """

    var mcp_handler: MCPServer
    var allowed_origins: List[String]
    var require_origin_validation: Bool
    var _event_buffer: List[SSEEvent]
    var _next_event_id: UInt64
    var _buffer_capacity: Int

    fn __init__(out self,
                mcp_handler: MCPServer,
                allowed_origins: List[String] = List[String](),
                require_origin_validation: Bool = False):
        """Initialize the streaming transport.

        Args:
            mcp_handler: The MCP server instance to handle requests
            allowed_origins: List of allowed origins for CORS (empty = allow all)
            require_origin_validation: Whether to validate Origin header
        """
        self.mcp_handler = mcp_handler
        self.allowed_origins = allowed_origins
        self.require_origin_validation = require_origin_validation
        self._event_buffer = List[SSEEvent]()
        self._next_event_id = 1
        self._buffer_capacity = 1000

    fn _emit_sse_event(mut self, mut exchange: StreamableHTTPExchange, event_type: String, data: String) raises:
        """Assign an incremental ID, buffer the event, and send via SSE."""
        var id = self._next_event_id
        self._next_event_id += 1

        # Append to buffer, enforce capacity (drop oldest when full)
        self._event_buffer.append(SSEEvent(id, event_type, data))
        if len(self._event_buffer) > self._buffer_capacity:
            # Remove oldest (index 0)
            _ = self._event_buffer.pop(0)

        exchange.write_sse_event(event_type, data, String(id))

    fn _replay_events_since(self, mut exchange: StreamableHTTPExchange, last_event_id: UInt64) raises:
        """Replay buffered events with id > last_event_id in order."""
        for e in self._event_buffer:
            if e.id > last_event_id:
                exchange.write_sse_event(e.type, e.data, String(e.id))

    fn _parse_event_id(self, s: String) -> UInt64:
        try:
            return UInt64(atol(s))
        except:
            return 0

    fn call(mut self, mut exchange: StreamableHTTPExchange) raises:
        """Handle incoming streaming HTTP requests for MCP transport.

        Args:
            exchange: The streaming HTTP exchange containing request and response
        """
        # Handle OPTIONS requests for CORS preflight
        if exchange.method == "OPTIONS":
            self._handle_preflight(exchange)
            return

        var path = exchange.uri.path

        # Route to appropriate handler
        if path == "/mcp" or path == "/":
            self._handle_mcp_request(exchange)
        elif path == "/health":
            self._handle_health_check(exchange)
        elif path == "/sse":
            self._handle_sse_endpoint(exchange)
        else:
            self._send_error(exchange, 404, "Not Found")

    fn _handle_preflight(mut self, mut exchange: StreamableHTTPExchange) raises:
        """Handle CORS preflight OPTIONS requests.

        Args:
            exchange: The streaming HTTP exchange
        """
        print("[MCP] Handling OPTIONS preflight request")

        exchange.set_status(204)  # No Content
        self._add_cors_headers(exchange)

        # Add additional CORS preflight headers
        exchange.add_header("Access-Control-Max-Age", "86400")  # 24 hours
        exchange.add_header("Content-Length", "0")

        exchange._use_chunked_encoding = False
        exchange.send_headers()

        print("[MCP] Preflight response sent")

    fn _handle_mcp_request(mut self, mut exchange: StreamableHTTPExchange) raises:
        """Handle MCP JSON-RPC requests.

        Args:
            exchange: The streaming HTTP exchange
        """
        # Only accept POST and GET requests
        if exchange.method != "POST" and exchange.method != "GET":
            print("[MCP] Rejecting unsupported method:", exchange.method)
            self._send_error(exchange, 405, "Method not allowed. Use POST or GET")
            return

        # GET is only for SSE endpoints
        if exchange.method == "GET":
            print("[MCP] GET request - routing to SSE handler")
            self._handle_sse_request(exchange)
            return

        # Validate Accept header (MCP spec requirement)
        if not self._validate_accept_header(exchange):
            print("[MCP] Invalid Accept header")
            self._send_error(exchange, 406, "Not Acceptable. Client must accept both application/json and text/event-stream")
            return

        # Validate Content-Type
        if not self._validate_content_type(exchange):
            print("[MCP] Invalid Content-Type")
            self._send_error(exchange, 400, "Invalid Content-Type. Expected application/json")
            return

        # Validate Origin if required
        if self.require_origin_validation and not self._validate_origin(exchange):
            print("[MCP] Invalid Origin")
            self._send_error(exchange, 403, "Invalid Origin header")
            return

        print("[MCP] Reading request body...")
        print("[MCP] Headers:")
        for entry in exchange.headers._inner.items():
            print("[MCP]   ", entry.key, ":", entry.value)

        # Read request body - handle both chunked and content-length
        var body = Bytes()

        # Check if we have a Content-Length header
        var has_content_length = "Content-Length" in exchange.headers

        if has_content_length:
            # We know how much to read
            while True:
                try:
                    var chunk = exchange.read_body_chunk()
                    if len(chunk) == 0:
                        break
                    body.extend(chunk^)
                except:
                    # EOF is expected when we've read everything
                    break
        else:
            # No content length, read until EOF or empty chunk
            while True:
                try:
                    var chunk = exchange.read_body_chunk()
                    if len(chunk) == 0:
                        break
                    body.extend(chunk^)
                except:
                    # EOF means we're done
                    break

        # Convert Bytes to String
        var body_str: String
        if len(body) > 0:
            body_str = String(ByteView(Span(body)))
        else:
            body_str = ""

        if len(body_str) == 0:
            print("[MCP] Empty request body")
            self._send_error(exchange, 400, "Empty request body")
            return

        print("[MCP] Received body:", len(body_str), "bytes")
        print("[MCP] Request JSON:", body_str)

        # Parse and process MCP message
        var response_json: String
        try:
            response_json = self._process_mcp_message(body_str, exchange)
            print("[MCP] Response generated:", len(response_json), "bytes")
            if len(response_json) > 0:
                print("[MCP] Response JSON:", response_json)
            else:
                print("[MCP] Empty response (notification)")
        except e:
            print("[MCP] Error processing message:", String(e))
            self._send_error(exchange, 500, "Internal server error")
            return

        # Send response
        print("[MCP] Sending response...")
        exchange.set_status(200)
        self._add_cors_headers(exchange)

        # Add session ID to response if we have one
        var session_id = self._extract_session_id(exchange)
        if session_id != "":
            exchange.add_header("Mcp-Session-Id", session_id)

        # Determine response mode based on request content and Accept header
        var use_sse = self._should_use_sse(body_str, exchange)

        if use_sse:
            # SSE streaming mode for multiple requests or client preference
            exchange.add_header("Content-Type", "text/event-stream")
            exchange.add_header("Cache-Control", "no-cache")
            exchange.add_header("Connection", "keep-alive")
            exchange._use_chunked_encoding = False

            exchange.send_headers()

            # Send response as SSE event
            if len(response_json) > 0:
                exchange.write_sse_event("message", response_json)

            # Don't end stream - keep connection open for more events
            print("[MCP] SSE stream initiated")
        else:
            # Regular JSON response with Content-Length
            exchange.add_header("Content-Type", "application/json")

            var response_body: Bytes
            if len(response_json) > 0:
                response_body = bytes(response_json)
            else:
                response_body = bytes("{}")

            # Use Content-Length for regular responses (not chunked)
            exchange.add_header("Content-Length", String(len(response_body)))
            exchange._use_chunked_encoding = False

            exchange.send_headers()
            exchange.write_chunk(response_body)

            print("[MCP] Regular JSON response sent:", len(response_body), "bytes")
            print("[MCP] Response headers:")
            print("[MCP]   Content-Type: application/json")
            print("[MCP]   Content-Length:", len(response_body))

    fn _handle_health_check(mut self, mut exchange: StreamableHTTPExchange) raises:
        """Handle health check requests.

        Args:
            exchange: The streaming HTTP exchange
        """
        exchange.set_status(200)
        exchange.add_header("Content-Type", "application/json")

        var health = bytes('{"status":"healthy","service":"mcp-streaming"}')
        exchange.add_header("Content-Length", String(len(health)))
        exchange._use_chunked_encoding = False

        exchange.send_headers()
        exchange.write_chunk(health)

        print("[MCP] Health check response sent")

    fn _handle_sse_request(mut self, mut exchange: StreamableHTTPExchange) raises:
        """Handle SSE requests (GET method with optional Last-Event-ID).

        Args:
            exchange: The streaming HTTP exchange
        """
        var last_event_id = self._extract_last_event_id(exchange)

        if last_event_id != "":
            print("[MCP] SSE reconnection request with Last-Event-ID:", last_event_id)
            self._handle_sse_resume(exchange, last_event_id)
        else:
            print("[MCP] New SSE connection")
            self._handle_sse_endpoint(exchange)

    fn _handle_sse_endpoint(mut self, mut exchange: StreamableHTTPExchange) raises:
        """Handle Server-Sent Events endpoint for streaming updates.

        Args:
            exchange: The streaming HTTP exchange
        """
        print("[MCP] Starting SSE stream")

        # Start SSE stream
        exchange.start_sse_stream()

        # Send connection event with ID (buffered)
        self._emit_sse_event(exchange, "connect", "MCP Streaming Transport Connected")

        # In a real implementation, this would stream actual MCP events
        # For now, just send a completion event
        self._emit_sse_event(exchange, "ready", "Ready for MCP communication")

        print("[MCP] SSE stream established (connection stays open)")

    fn _handle_sse_resume(mut self, mut exchange: StreamableHTTPExchange, last_event_id: String) raises:
        """Handle SSE reconnection with event replay.

        Args:
            exchange: The streaming HTTP exchange
            last_event_id: The last event ID received by client
        """
        print("[MCP] Resuming SSE stream from event:", last_event_id)

        # Start SSE stream
        exchange.start_sse_stream()

        # Replay buffered events newer than last_event_id
        var last_id_num = self._parse_event_id(last_event_id)
        self._replay_events_since(exchange, last_id_num)

        # Send a reconnect marker as a regular event
        self._emit_sse_event(exchange, "reconnect", "SSE stream resumed from " + last_event_id)

        # Send ready event
        self._emit_sse_event(exchange, "ready", "Ready for MCP communication")

        print("[MCP] SSE stream resumed")

    fn _process_mcp_message(mut self, json_body: String, exchange: StreamableHTTPExchange) raises -> String:
        """Process an MCP JSON-RPC message and return the response.

        Args:
            json_body: The JSON-RPC message body
            exchange: The streaming HTTP exchange for session extraction

        Returns:
            The JSON-RPC response as a string
        """
        var parser = JSONRPCParser()
        var serializer = JSONRPCSerializer()

        # Extract session ID from headers
        var session_id = self._extract_session_id(exchange)

        try:
            var message = parser.parse_message(json_body)

            # Handle different message types
            if message.isa[JSONRPCRequest]():
                var request = message[JSONRPCRequest]
                # Pass session ID to handler for session management
                var response = self.mcp_handler.handle_request_with_session(request, session_id)
                var serialized_response = serializer.serialize_response(response)
                return serialized_response
            elif message.isa[JSONRPCNotification]():
                var notification = message[JSONRPCNotification]
                self.mcp_handler.handle_notification_with_session(notification, session_id)
                return ""  # Notifications don't expect responses
            else:
                # Responses are not expected in server context
                var error_response = self._create_error_response("", invalid_request())
                return error_response

        except e:
            # Return parse error for invalid JSON-RPC
            var error_response = self._create_error_response("", parse_error())
            return error_response

    fn _validate_accept_header(self, exchange: StreamableHTTPExchange) raises -> Bool:
        """Validate that the request Accept header includes required MIME types.

        MCP Spec: Client MUST include Accept header with both application/json
        and text/event-stream.

        Args:
            exchange: The streaming HTTP exchange

        Returns:
            True if Accept header contains both required MIME types
        """
        if "Accept" not in exchange.headers:
            # No Accept header - be permissive and allow
            return True

        var accept = exchange.headers["Accept"]
        var accept_lower = accept.lower()

        # Check for both required MIME types
        var has_json = ("application/json" in accept_lower or
                       "*/*" in accept_lower or
                       "application/*" in accept_lower)
        var has_sse = ("text/event-stream" in accept_lower or
                      "*/*" in accept_lower or
                      "text/*" in accept_lower)

        return has_json and has_sse

    fn _validate_content_type(self, exchange: StreamableHTTPExchange) raises -> Bool:
        """Validate that the request has the correct Content-Type.

        Args:
            exchange: The streaming HTTP exchange

        Returns:
            True if Content-Type is application/json
        """
        if "Content-Type" in exchange.headers:
            var content_type = exchange.headers["Content-Type"]
            return content_type.startswith("application/json")
        return False

    fn _validate_origin(self, exchange: StreamableHTTPExchange) raises -> Bool:
        """Validate the Origin header against allowed origins.

        Args:
            exchange: The streaming HTTP exchange

        Returns:
            True if origin is allowed
        """
        if not self.require_origin_validation:
            return True

        if "Origin" not in exchange.headers:
            return False

        var origin = exchange.headers["Origin"]

        # If no specific origins are configured, allow localhost only
        if len(self.allowed_origins) == 0:
            return (origin.startswith("http://localhost") or
                   origin.startswith("http://127.0.0.1") or
                   origin.startswith("https://localhost") or
                   origin.startswith("https://127.0.0.1"))

        # Check against configured allowed origins
        for allowed_origin in self.allowed_origins:
            if origin == allowed_origin:
                return True

        return False

    fn _extract_session_id(self, exchange: StreamableHTTPExchange) raises -> String:
        """Extract session ID from Mcp-Session-Id header.

        Args:
            exchange: The streaming HTTP exchange

        Returns:
            The session ID, or empty string if not present
        """
        if "Mcp-Session-Id" in exchange.headers:
            var session_id = String(exchange.headers["Mcp-Session-Id"].strip())
            return session_id

        return ""

    fn _extract_last_event_id(self, exchange: StreamableHTTPExchange) raises -> String:
        """Extract Last-Event-ID from header for SSE resumption.

        Args:
            exchange: The streaming HTTP exchange

        Returns:
            The last event ID, or empty string if not present
        """
        if "Last-Event-ID" in exchange.headers:
            var last_event_id = String(exchange.headers["Last-Event-ID"].strip())
            return last_event_id

        return ""

    fn _should_use_sse(self, request_body: String, exchange: StreamableHTTPExchange) raises -> Bool:
        """Determine if SSE should be used for the response.

        MCP Spec: Use SSE when request contains multiple JSON-RPC requests,
        or when client explicitly prefers text/event-stream.

        Args:
            request_body: The JSON-RPC request body
            exchange: The streaming HTTP exchange

        Returns:
            True if SSE should be used
        """
        # Check if request body contains JSON array (multiple requests)
        var trimmed = request_body.strip()
        if trimmed.startswith("["):
            # Multiple JSON-RPC requests - use SSE
            return True

        # Check Accept header preference
        if "Accept" in exchange.headers:
            var accept = exchange.headers["Accept"]
            var accept_lower = accept.lower()

            # If client prefers SSE over JSON (text/event-stream comes first)
            var sse_pos = accept_lower.find("text/event-stream")
            var json_pos = accept_lower.find("application/json")

            if sse_pos != -1 and json_pos != -1:
                if sse_pos < json_pos:
                    # Client prefers SSE
                    return True

        # Default to regular JSON
        return False

    fn _add_cors_headers(mut self, mut exchange: StreamableHTTPExchange) raises:
        """Add CORS headers to the response.

        Args:
            exchange: The streaming HTTP exchange
        """
        # CORS headers
        if "Origin" in exchange.headers:
            exchange.add_header("Access-Control-Allow-Origin", exchange.headers["Origin"])
        else:
            exchange.add_header("Access-Control-Allow-Origin", "*")

        exchange.add_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        exchange.add_header("Access-Control-Allow-Headers", "Content-Type, Authorization, Mcp-Session-Id")
        exchange.add_header("Access-Control-Max-Age", "86400")

        # MCP-specific headers
        exchange.add_header("Cache-Control", "no-cache, no-store, must-revalidate")

    fn _send_error(mut self, mut exchange: StreamableHTTPExchange, status: Int, message: String) raises:
        """Send an error response.

        Args:
            exchange: The streaming HTTP exchange
            status: HTTP status code
            message: Error message
        """
        try:
            exchange.set_status(status)
            self._add_cors_headers(exchange)
            exchange.add_header("Content-Type", "application/json")
            var error_json = String('{"error":"') + message + String('"}')
            exchange.write_chunk(bytes(error_json))
            exchange.end_stream()
        except:
            # If we can't send the error, at least close cleanly
            pass

    fn _create_error_response(self, id: String, error: JSONRPCError) -> String:
        """Create a JSON-RPC error response.

        Args:
            id: The request ID
            error: The JSON-RPC error

        Returns:
            The error response as JSON string
        """
        var serializer = JSONRPCSerializer()
        return serializer.serialize_error_response(id, error)