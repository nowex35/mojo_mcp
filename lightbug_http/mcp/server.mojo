from collections import Dict
from .jsonrpc import JSONRPCRequest, JSONRPCResponse, JSONRPCNotification, JSONRPCError, method_not_found, internal_error, unsupported_protocol_version, tool_execution_failed, log_error, server_not_initialized
from .messages import MCPServerInfo, MCPCapabilities, create_initialize_response, MCP_PROTOCOL_VERSION, is_compatible_version
from .session import SessionManager
from .tools import MCPTool, MCPToolRegistry, ToolExecutionFunc
from .utils import generate_uuid, current_time_ms, parse_json_string, parse_json_object_string, parse_json_object
from .timeout import TimeoutManager, TimeoutConfig, CancellationNotification, create_cancellation_error
from lightbug_http.streaming.server import StreamingServer
from .streaming_transport import StreamingTransport

# Connection states
alias ConnectionState = Int
alias DISCONNECTED: ConnectionState = 0
alias CONNECTING: ConnectionState = 1
alias INITIALIZING: ConnectionState = 2
alias INITIALIZED: ConnectionState = 3
alias READY: ConnectionState = 4
alias ERROR: ConnectionState = 5

# Forward declaration for the handler interface
trait MCPHandler:
    """Interface for handling MCP messages."""

    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle a JSON-RPC request and return a response."""
        pass

    fn handle_notification(mut self, notification: JSONRPCNotification) raises:
        """Handle a JSON-RPC notification (no response expected)."""
        pass

    fn handle_request_with_session(mut self, request: JSONRPCRequest, session_id: String) raises -> JSONRPCResponse:
        """Handle a JSON-RPC request with session management and return a response."""
        pass

    fn handle_notification_with_session(mut self, notification: JSONRPCNotification, session_id: String) raises:
        """Handle a JSON-RPC notification with session management (no response expected)."""
        pass

@value
struct MCPConnection(Movable):
    """Represents a client connection to the MCP server."""
    var connection_id: String
    var state: ConnectionState
    var protocol_version: String
    var client_name: String
    var client_version: String
    var client_capabilities: MCPCapabilities
    var session_start_time: Int

    fn __init__(out self, connection_id: String):
        self.connection_id = connection_id
        self.state = CONNECTING
        self.protocol_version = ""
        self.client_name = ""
        self.client_version = ""
        self.client_capabilities = MCPCapabilities()
        self.session_start_time = current_time_ms()

    fn is_initialized(self) -> Bool:
        """Check if the connection has completed initialization."""
        return self.state >= INITIALIZED

    fn is_ready(self) -> Bool:
        """Check if the connection is ready for normal operations."""
        return self.state == READY

@value
struct MCPServer(MCPHandler):
    """Main MCP server implementation."""

    var server_info: MCPServerInfo
    var server_capabilities: MCPCapabilities
    var connections: Dict[String, MCPConnection]
    var session_manager: SessionManager
    var tools_registry: MCPToolRegistry
    var tools_handler: ToolsHandler
    var resources_handler: ResourcesHandler
    var prompts_handler: PromptsHandler
    var templates_handler: TemplatesHandler
    var timeout_manager: TimeoutManager
    var is_running: Bool

    fn __init__(out self,
                server_name: String = "lightbug-mcp-server",
                server_version: String = "1.0.0",
                enable_timeouts: Bool = True):
        self.server_info = MCPServerInfo(server_name, server_version)
        self.server_capabilities = MCPCapabilities(
            tools=True,
            resources=False,
            prompts=False,
            logging=False
        )
        self.connections = Dict[String, MCPConnection]()
        self.session_manager = SessionManager()
        self.tools_registry = MCPToolRegistry()
        self.tools_handler = ToolsHandler(self.tools_registry)
        self.resources_handler = ResourcesHandler()
        self.prompts_handler = PromptsHandler()
        self.templates_handler = TemplatesHandler()

        if enable_timeouts:
            var default_config = TimeoutConfig(
                default_timeout_ms=30000,    # 30 seconds default (changed for testing)
                maximum_timeout_ms=300000,   # 5 minutes maximum
                progress_reset_timeout_ms=5000,  # 5 seconds additional on progress
                enable_progress_reset=True
            )
            self.timeout_manager = TimeoutManager(default_config)
        else:
            self.timeout_manager = TimeoutManager()

        self.is_running = False

    fn start(mut self,
            address: String = "127.0.0.1:8081",
            max_concurrent_connections: UInt = 1000,
            ) raises:
        """Start the MCP server using the streaming backend with configuration."""
        if self.is_running:
            raise Error("Server is already running")

        self.is_running = True

        try:
            var transport_handler = StreamingTransport(self)

            var server = StreamingServer(
                name=self.server_info.name,
                max_concurrent_connections=max_concurrent_connections,
            )

            server.listen_and_serve(address, transport_handler)

        except e:
            print("Server error: " + String(e))
        finally:
            # Cleanup
            print("\nShutting down...")
            self.stop()
            print("MCP server stopped.")


    fn stop(mut self) raises:
        """Stop the MCP server and close all connections."""
        if not self.is_running:
            return

        # Close all active connections - collect IDs first to avoid aliasing issues
        var connection_ids = List[String]()
        for connection_id in self.connections:
            connection_ids.append(connection_id)

        for i in range(len(connection_ids)):
            self._close_connection(connection_ids[i])

        self.is_running = False

    fn handle_request(mut self, request: JSONRPCRequest, custom_timeout_ms: Int = -1) raises -> JSONRPCResponse:
        """Handle incoming JSON-RPC requests with timeout management."""

        if not self.is_running:
            var error = server_not_initialized()
            log_error(error, "handle_request")
            return JSONRPCResponse.error_response(request.id, error)

        # Check for expired requests and send cancellation notifications
        try:
            var expired_requests = self.timeout_manager.check_expired_requests()
            for i in range(len(expired_requests)):
                var expired_id = expired_requests[i]
                var _ = CancellationNotification(expired_id, "timeout")
                # Log the cancellation (in a real implementation, this would be sent to the client)
                print("Request ", expired_id, " has timed out and was cancelled")
        except:
            pass  # Continue even if timeout checking fails

        # Check if this request was already cancelled
        if self.timeout_manager.is_request_cancelled(request.id):
            var error = create_cancellation_error(request.id, request.method)
            return JSONRPCResponse.error_response(request.id, error)

        # Add request to timeout tracking (except for initialize which doesn't need timeout)
        if request.method != "initialize":
            try:
                self.timeout_manager.add_request(request, custom_timeout_ms)
            except:
                pass  # Continue even if timeout tracking fails

        try:
            # Route request based on method
            var response: JSONRPCResponse
            if request.method == "initialize":
                response = self._handle_initialize(request)
            elif request.method.startswith("tools/"):
                response = self._handle_tools_request(request)
            elif request.method.startswith("resources/templates/"):
                response = self._handle_templates_request(request)
            elif request.method.startswith("resources/"):
                response = self._handle_resources_request(request)
            elif request.method.startswith("prompts/"):
                response = self._handle_prompts_request(request)
            else:
                var error = method_not_found()
                response = JSONRPCResponse.error_response(request.id, error)

            try:
                self.timeout_manager.complete_request(request.id)
            except:
                pass
            return response

        except e:
            try:
                self.timeout_manager.complete_request(request.id)
            except:
                pass
            var error = internal_error()
            log_error(error, "handle_request_failed")
            return JSONRPCResponse.error_response(request.id, error)

    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle incoming JSON-RPC requests (overload for interface compliance)."""
        return self.handle_request(request, -1)

    fn handle_notification(mut self, notification: JSONRPCNotification) raises:
        """Handle incoming JSON-RPC notifications."""
        if not self.is_running:
            return

        if notification.method == "initialized":
            self._handle_initialized(notification)
        elif notification.method == "notifications/progress":
            self._handle_progress_notification(notification)
        elif notification.method == "notifications/cancelled":
            self._handle_cancellation_notification(notification)
        elif notification.method.startswith("notifications/"):
            # Handle other notification types
            pass

    fn handle_request_with_session(mut self, request: JSONRPCRequest, session_id: String) raises -> JSONRPCResponse:
        """Handle incoming JSON-RPC requests with session management."""
        if not self.is_running:
            var error = server_not_initialized()
            log_error(error, "handle_request_with_session")
            return JSONRPCResponse.error_response(request.id, error)

        # Perform session cleanup
        _ = self.session_manager.cleanup_expired_sessions()

        # Handle session-aware request
        if request.method == "initialize":
            return self._handle_initialize_with_session(request, session_id)
        else:
            # For other requests, validate session if provided
            if session_id != "":
                try:
                    self.session_manager.update_session_activity(session_id)
                except:
                    # Invalid session ID, continue with regular handling
                    pass

            # Delegate to regular handler with default timeout
            return self.handle_request(request, -1)

    fn handle_notification_with_session(mut self, notification: JSONRPCNotification, session_id: String) raises:
        """Handle incoming JSON-RPC notifications with session management."""
        if not self.is_running:
            return

        # Update session activity if session exists
        if session_id != "":
            try:
                self.session_manager.update_session_activity(session_id)
            except:
                # Invalid session ID, continue with regular handling
                pass

        # Delegate to regular handler
        self.handle_notification(notification)

    fn _handle_initialize(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle the initialize request from a client."""
        try:
            # Extract connection ID from request (or generate one)
            var connection_id = generate_uuid()

            # Parse initialization parameters
            var init_params = self._parse_initialize_params(request.params)

            # Validate protocol version
            if not is_compatible_version(init_params.protocol_version):
                var error = unsupported_protocol_version(init_params.protocol_version)
                log_error(error, "initialize")
                return JSONRPCResponse.error_response(request.id, error)

            # Validate client capabilities compatibility
            var _ = self._negotiate_capabilities(init_params.client_capabilities)

            # Create new connection
            var connection = MCPConnection(connection_id)
            connection.state = INITIALIZING
            connection.protocol_version = init_params.protocol_version
            connection.client_name = init_params.client_name
            connection.client_version = init_params.client_version
            connection.client_capabilities = init_params.client_capabilities

            # Store the connection
            self.connections[connection_id] = connection

            # Create initialize response with server capabilities
            var response = create_initialize_response(
                request.id,
                self.server_info,
                self.server_capabilities
            )
            return response

        except e:
            var error = internal_error()
            log_error(error, "initialize_failed")
            return JSONRPCResponse.error_response(request.id, error)

    fn _handle_initialize_with_session(mut self, request: JSONRPCRequest, session_id: String) raises -> JSONRPCResponse:
        """Handle the initialize request with session management."""
        try:
            var connection_id = generate_uuid()

            var init_params = self._parse_initialize_params(request.params)

            if not is_compatible_version(init_params.protocol_version):
                var error = unsupported_protocol_version(init_params.protocol_version)
                log_error(error, "initialize_with_session")
                return JSONRPCResponse.error_response(request.id, error)

            var _ = session_id
            if session_id == "":
                var client_builder = JSONBuilder()
                client_builder.add_string("name", init_params.client_name)
                client_builder.add_string("version", init_params.client_version)
                var client_info = client_builder.build()
                var _ = self.session_manager.create_session(connection_id, client_info)
            else:
                try:
                    var session = self.session_manager.get_session(session_id)
                    if session.connection_id != connection_id:
                        self.session_manager.terminate_session_by_connection(session.connection_id)
                        var client_builder = JSONBuilder()
                        client_builder.add_string("name", init_params.client_name)
                        client_builder.add_string("version", init_params.client_version)
                        var client_info = client_builder.build()
                        var _ = self.session_manager.create_session(connection_id, client_info)
                    else:
                        self.session_manager.update_session_activity(session_id)
                except:
                    var client_builder = JSONBuilder()
                    client_builder.add_string("name", init_params.client_name)
                    client_builder.add_string("version", init_params.client_version)
                    var client_info = client_builder.build()
                    var _ = self.session_manager.create_session(connection_id, client_info)

            var _ = self._negotiate_capabilities(init_params.client_capabilities)

            var connection = MCPConnection(connection_id)
            connection.state = INITIALIZING
            connection.protocol_version = init_params.protocol_version
            connection.client_name = init_params.client_name
            connection.client_version = init_params.client_version
            connection.client_capabilities = init_params.client_capabilities

            self.connections[connection_id] = connection

            var response = create_initialize_response(
                request.id,
                self.server_info,
                self.server_capabilities
            )

            return response

        except e:
            var error = internal_error()
            log_error(error, "initialize_with_session_failed")
            return JSONRPCResponse.error_response(request.id, error)

    fn _handle_initialized(mut self, notification: JSONRPCNotification) raises:
        """Handle the initialized notification from a client."""
        for connection_id in self.connections:
            var connection = self.connections[connection_id]
            if connection.state == INITIALIZING:
                connection.state = READY
                self.connections[connection_id] = connection

    fn _handle_tools_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle tools/* requests."""

        if request.method == "tools/list":
            var tools = self.tools_registry.list_tools()
            var tool_jsons = List[String]()
            for i in range(len(tools)):
                try:
                    tool_jsons.append(tools[i].to_json())
                except e:
                    continue
            var builder = JSONBuilder()
            builder.add_array("tools", tool_jsons)
            var result_json = builder.build()
            return JSONRPCResponse.success(request.id, result_json)
        elif request.method == "tools/call":
            try:
                var tool_info = self._parse_tool_call_params(request.params)

                var result = self.tools_registry.execute_tool(tool_info.name, tool_info.arguments)

                # Return the result as a successful JSON-RPC response
                return JSONRPCResponse.success(request.id, result.to_json())

            except e:
                # This handles parsing errors or unexpected failures
                var error = tool_execution_failed("unknown", String(e))
                log_error(error, "tools_call")
                return JSONRPCResponse.error_response(request.id, error)
        else:
            var error = method_not_found()
            return JSONRPCResponse.error_response(request.id, error)

    fn _handle_resources_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle resources/* requests."""
        return self.resources_handler.handle_request(request)

    fn _handle_prompts_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle prompts/* requests."""
        return self.prompts_handler.handle_request(request)

    fn _handle_templates_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle resources/templates/* requests."""
        return self.templates_handler.handle_request(request)

    fn _parse_initialize_params(self, params_json: String) raises -> InitializeParams:
        """Parse initialize request parameters."""
        var params = InitializeParams()

        # Parse protocolVersion
        params.protocol_version = parse_json_string(params_json, "protocolVersion", MCP_PROTOCOL_VERSION)

        # Parse clientInfo.name and clientInfo.version
        params.client_name = parse_json_object_string(params_json, "clientInfo", "name", "unknown")
        params.client_version = parse_json_object_string(params_json, "clientInfo", "version", "unknown")

        return params

    fn _close_connection(mut self, connection_id: String) raises:
        """Close a client connection."""
        if connection_id in self.connections:
            _ = self.connections.pop(connection_id)

    fn get_connection_count(self) -> Int:
        """Get the number of active connections."""
        return len(self.connections)

    fn get_server_info(self) -> MCPServerInfo:
        """Get server information."""
        return self.server_info

    fn get_server_capabilities(self) -> MCPCapabilities:
        """Get server capabilities."""
        return self.server_capabilities

    fn _negotiate_capabilities(self, client_capabilities: MCPCapabilities) -> MCPCapabilities:
        """Negotiate capabilities between server and client.

        Returns the intersection of server and client capabilities.
        Only features supported by both sides will be enabled.
        """
        var negotiated = MCPCapabilities()

        negotiated.tools = self.server_capabilities.tools and client_capabilities.tools

        negotiated.resources = self.server_capabilities.resources and client_capabilities.resources

        negotiated.prompts = self.server_capabilities.prompts and client_capabilities.prompts

        negotiated.logging = self.server_capabilities.logging and client_capabilities.logging

        negotiated.roots = self.server_capabilities.roots and client_capabilities.roots

        negotiated.sampling = self.server_capabilities.sampling and client_capabilities.sampling

        return negotiated

    fn tool(mut self, name: String, description: String, parameters: MCPToolParameter, executor: ToolExecutionFunc) raises:
        """Register a new tool with the server."""
        var tool = MCPTool(name, description, parameters)
        self.tools_registry.register_tool(tool, executor)
        var _ = self.tools_registry.list_tools()

    fn tool(mut self, name: String, description: String, parameters: List[MCPToolParameter], executor: ToolExecutionFunc) raises:
        """Register a new tool with the server (multiple parameters)."""
        var tool = MCPTool(name, description, parameters)
        self.tools_registry.register_tool(tool, executor)
        var _ = self.tools_registry.list_tools()

    fn get_active_session_count(self) -> Int:
        """Get the number of active sessions."""
        return self.session_manager.get_active_session_count()

    fn cleanup_expired_sessions(mut self) -> Int:
        """Force cleanup of expired sessions and return the number cleaned."""
        return self.session_manager.force_cleanup()

    fn terminate_session(mut self, session_id: String) raises:
        """Terminate a specific session."""
        self.session_manager.terminate_session(session_id)

    fn _parse_tool_call_params(self, params_json: String) raises -> ToolCallParams:
        """Parse tool call parameters from JSON."""
        var name = parse_json_string(params_json, "name", "unknown")
        var arguments: String

        try:
            arguments = parse_json_object(params_json, "arguments")
        except:
            # If arguments parsing fails, use default empty object
            arguments = "{}"

        return ToolCallParams(name, arguments)

    # Timeout and progress handling methods
    fn _handle_progress_notification(mut self, notification: JSONRPCNotification) raises:
        """Handle progress notifications to reset request timeouts."""
        try:
            var request_id = self._extract_request_id_from_progress(notification.params)
            if request_id != "":
                var success = self.timeout_manager.update_progress(request_id)
                if success:
                    print("Progress updated for request: ", request_id)
        except:
            print("Error handling progress notification")

    fn _handle_cancellation_notification(mut self, notification: JSONRPCNotification) raises:
        """Handle explicit cancellation notifications."""
        try:
            var request_id = self._extract_request_id_from_cancellation(notification.params)
            if request_id != "":
                var success = self.timeout_manager.cancel_request(request_id)
                if success:
                    print("Request explicitly cancelled: ", request_id)
        except:
            print("Error handling cancellation notification")

    fn _extract_request_id_from_progress(self, params_json: String) -> String:
        """Extract request ID from progress notification params."""
        var request_id_start = params_json.find('"requestId"')
        if request_id_start == -1:
            return ""

        var colon_pos = params_json.find(':', request_id_start)
        if colon_pos == -1:
            return ""

        var quote_start = params_json.find('"', colon_pos)
        if quote_start == -1:
            return ""

        var quote_end = params_json.find('"', quote_start + 1)
        if quote_end == -1:
            return ""

        return params_json[quote_start + 1:quote_end]

    fn _extract_request_id_from_cancellation(self, params_json: String) -> String:
        """Extract request ID from cancellation notification params."""
        var id_start = params_json.find('"id"')
        if id_start == -1:
            return ""

        var colon_pos = params_json.find(':', id_start)
        if colon_pos == -1:
            return ""

        var quote_start = params_json.find('"', colon_pos)
        if quote_start == -1:
            return ""

        var quote_end = params_json.find('"', quote_start + 1)
        if quote_end == -1:
            return ""

        return params_json[quote_start + 1:quote_end]

    # Timeout configuration methods
    fn configure_timeouts(mut self, config: TimeoutConfig):
        """Configure timeout settings for the server."""
        self.timeout_manager = TimeoutManager(config)

    fn get_timeout_stats(self) raises -> TimeoutStats:
        """Get current timeout statistics."""
        var stats = TimeoutStats()
        stats.pending_requests = self.timeout_manager.get_pending_request_count()
        stats.cancelled_requests = self.timeout_manager.get_cancelled_request_count()
        return stats

    fn cleanup_timeout_data(mut self) raises:
        """Clean up old timeout tracking data."""
        self.timeout_manager.cleanup_completed_requests()

# Helper structures
@value
struct TimeoutStats(Movable):
    """Statistics for timeout management."""
    var pending_requests: Int
    var cancelled_requests: Int

    fn __init__(out self):
        self.pending_requests = 0
        self.cancelled_requests = 0

@value
struct InitializeParams(Movable):
    """Parameters for the initialize request."""
    var protocol_version: String
    var client_name: String
    var client_version: String
    var client_capabilities: MCPCapabilities

    fn __init__(out self):
        self.protocol_version = MCP_PROTOCOL_VERSION
        self.client_name = "unknown"
        self.client_version = "unknown"
        self.client_capabilities = MCPCapabilities()

# Forward declarations for handlers
trait RequestHandler:
    """Base trait for MCP request handlers."""
    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        pass

@value
struct ToolsHandler(RequestHandler):
    """Handler for tools/* requests."""
    var tools_registry: MCPToolRegistry

    fn __init__(out self, tools_registry: MCPToolRegistry):
        self.tools_registry = tools_registry

    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle tools requests."""
        if request.method == "tools/list":
            return self._handle_tools_list(request)
        elif request.method == "tools/call":
            return self._handle_tools_call(request)
        else:
            var error = method_not_found()
            return JSONRPCResponse.error_response(request.id, error)

    fn _handle_tools_list(self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle tools/list request."""
        var tools = self.tools_registry.list_tools()

        var tools_array = String("[")
        var added_count = 0

        for i in range(len(tools)):
            try:
                var tool_json = tools[i].to_json()
                if added_count > 0:
                    tools_array = tools_array + ","
                tools_array = tools_array + tool_json
                added_count += 1
            except e:
                continue

        tools_array = tools_array + "]"

        var result_builder = JSONBuilder()
        result_builder.add_raw("tools", tools_array)
        var result_json = result_builder.build()
        return JSONRPCResponse.success(request.id, result_json)

    fn _handle_tools_call(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle tools/call request."""
        try:
            var tool_info = self._parse_tool_call_params(request.params)

            var result = self.tools_registry.execute_tool(tool_info.name, tool_info.arguments)

            # Check if the result is an error and return it as a successful response
            # (the error is in the result content, not a JSON-RPC error)
            return JSONRPCResponse.success(request.id, result.to_json())

        except e:
            # This handles parsing errors or unexpected failures
            var error = tool_execution_failed("unknown", String(e))
            log_error(error, "tools_call")
            return JSONRPCResponse.error_response(request.id, error)

    fn _parse_tool_call_params(self, params_json: String) raises -> ToolCallParams:
        """Parse tool call parameters from JSON."""
        var name = parse_json_string(params_json, "name", "unknown")
        var arguments: String

        try:
            arguments = parse_json_object(params_json, "arguments")
        except:
            # If arguments parsing fails, use default empty object
            arguments = "{}"

        return ToolCallParams(name, arguments)

@value
struct ToolCallParams(Movable):
    """Parameters for tool call request."""
    var name: String
    var arguments: String

    fn __init__(out self, name: String = "unknown", arguments: String = "{}"):
        self.name = name
        self.arguments = arguments

@value
struct ResourcesHandler(RequestHandler):
    """Handler for resources/* requests."""

    fn __init__(out self):
        pass

    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle resources requests."""
        var error: JSONRPCError

        if request.method == "resources/list":
            error = JSONRPCError(-32601, "resources/list method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "resources/read":
            error = JSONRPCError(-32601, "resources/read method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "resources/updated":
            error = JSONRPCError(-32601, "resources/updated notification is not currently implemented. This feature is postponed for future release.")
        else:
            error = JSONRPCError(-32601, "Unknown resources method: " + request.method + ". Resources feature is postponed for future implementation.")

        return JSONRPCResponse.error_response(request.id, error)

@value
struct PromptsHandler(RequestHandler):
    """Handler for prompts/* requests."""

    fn __init__(out self):
        pass

    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle prompts requests."""
        var error: JSONRPCError

        if request.method == "prompts/list":
            error = JSONRPCError(-32601, "prompts/list method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "prompts/get":
            error = JSONRPCError(-32601, "prompts/get method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "prompts/updated":
            error = JSONRPCError(-32601, "prompts/updated notification is not currently implemented. This feature is postponed for future release.")
        else:
            error = JSONRPCError(-32601, "Unknown prompts method: " + request.method + ". Prompts feature is postponed for future implementation.")

        return JSONRPCResponse.error_response(request.id, error)

@value
struct TemplatesHandler(RequestHandler):
    """Handler for resources/templates/* requests."""

    fn __init__(out self):
        pass

    fn handle_request(mut self, request: JSONRPCRequest) raises -> JSONRPCResponse:
        """Handle templates requests."""
        var error: JSONRPCError

        if request.method == "resources/templates/list":
            error = JSONRPCError(-32601, "resources/templates/list method is not currently implemented. This feature is postponed for future release.")
        elif request.method == "resources/templates/read":
            error = JSONRPCError(-32601, "resources/templates/read method is not currently implemented. This feature is postponed for future release.")
        else:
            error = JSONRPCError(-32601, "Unknown templates method: " + request.method + ". Templates feature is postponed for future implementation.")

        return JSONRPCResponse.error_response(request.id, error)
