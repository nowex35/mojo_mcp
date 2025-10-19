from lightbug_http.http import HTTPRequest, HTTPResponse, OK
from lightbug_http.io.bytes import bytes
from lightbug_http.mcp.mcp_common_response import BadRequest, MethodNotAllowed, InternalError
from lightbug_http.header import Headers, HeaderKey
from lightbug_http.strings import to_string
from lightbug_http.io.bytes import Bytes
from lightbug_http.service import HTTPService
from .parser import JSONRPCParser, JSONRPCSerializer, MessageType
from .jsonrpc import JSONRPCError, parse_error, invalid_request, method_not_found, internal_error, JSONRPCRequest, JSONRPCResponse, JSONRPCNotification
from .server import MCPServer

# Forward declaration for the handler interface
trait MCPTransport:
    """Common interface for all MCP transport implementations."""

    fn start(mut self) raises:
        """Start the transport layer."""
        pass

    fn stop(mut self):
        """Stop the transport layer."""
        pass

    fn is_running(self) -> Bool:
        """Check if the transport is currently running."""
        pass

@value
struct MCPTransportError(Movable):
    """Transport-level error for MCP."""
    var code: Int
    var message: String
    var details: String
    
    fn __init__(out self, code: Int, message: String, details: String = ""):
        self.code = code
        self.message = message
        self.details = details

@value
struct HTTPTransport(HTTPService):
    """HTTP transport for MCP using streamable HTTP.
    
    This transport handles:
    - HTTP POST requests for client-to-server communication
    - Content-Type validation (application/json)
    - Origin header validation for security
    - CORS headers for browser compatibility
    """
    
    var mcp_handler: MCPServer
    var allowed_origins: List[String]
    var require_origin_validation: Bool
    
    fn __init__(out self, mcp_handler: MCPServer, 
                allowed_origins: List[String] = List[String](),
                require_origin_validation: Bool = True):
        self.mcp_handler = mcp_handler
        self.allowed_origins = allowed_origins
        self.require_origin_validation = require_origin_validation
    
    fn func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        """Handle incoming HTTP requests for MCP transport."""
        
        # Only allow POST method for MCP
        if req.method != "POST":
            return MethodNotAllowed()
        
        # Validate Content-Type
        if not self._validate_content_type(req):
            return BadRequest("Invalid Content-Type. Expected application/json.")
        
        # Validate Origin header if required
        if self.require_origin_validation and not self._validate_origin(req):
            return BadRequest("Invalid Origin header.")
        
        # Parse request body as JSON-RPC message
        var request_body = to_string(req.body_raw)
        if len(request_body) == 0:
            return BadRequest("Empty request body.")
        
        try:
            # Process the MCP message
            var response = self._process_mcp_message(request_body, req)

            # Create HTTP response with appropriate headers
            _ = self._create_response_headers(req)
            return OK(bytes(response), content_type="application/json")
            
        except e:
            # Handle any processing errors
            _ = self._create_error_response("", internal_error())
            _ = self._create_response_headers(req)
            return InternalError()
    
    fn _validate_content_type(self, req: HTTPRequest) raises -> Bool:
        """Validate that the request has the correct Content-Type."""
        if HeaderKey.CONTENT_TYPE in req.headers:
            var content_type = req.headers[HeaderKey.CONTENT_TYPE]
            var is_valid = content_type.startswith("application/json")
            return is_valid
        return False
    
    fn _validate_origin(self, req: HTTPRequest) raises -> Bool:
        """Validate the Origin header against allowed origins."""
        if not self.require_origin_validation:
            return True
            
        if "Origin" not in req.headers:
            return False
        
        var origin = req.headers["Origin"]
        
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
    
    fn _process_mcp_message(mut self, json_body: String, req: HTTPRequest) raises -> String:
        """Process an MCP JSON-RPC message and return the response."""
        var parser = JSONRPCParser()
        var serializer = JSONRPCSerializer()
        
        # Extract session ID from headers
        var session_id = self._extract_session_id(req)
        
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
    
    fn _create_error_response(self, id: String, error: JSONRPCError) -> String:
        """Create a JSON-RPC error response."""
        var serializer = JSONRPCSerializer()
        return serializer.serialize_error_response(id, error)
    
    fn _create_response_headers(self, req: HTTPRequest) raises -> Headers:
        """Create appropriate response headers including CORS."""
        var headers = Headers()
        
        # CORS headers
        if "Origin" in req.headers:
            headers["Access-Control-Allow-Origin"] = req.headers["Origin"]
        else:
            headers["Access-Control-Allow-Origin"] = "*"
        
        headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
        headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, Mcp-Session-Id"
        headers["Access-Control-Max-Age"] = "86400"  # 24 hours
        
        # MCP-specific headers
        headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        headers["Pragma"] = "no-cache"
        headers["Expires"] = "0"
        
        return headers
    
    fn _extract_session_id(self, req: HTTPRequest) raises -> String:
        """Extract session ID from Mcp-Session-Id header."""
        if "Mcp-Session-Id" in req.headers:
            var session_id = String(req.headers["Mcp-Session-Id"].strip())
            return session_id
        
        # No session ID provided
        return ""

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

# HTTP OPTIONS handler for CORS preflight
@value
struct MCPOptionsHandler(HTTPService):
    """Handler for HTTP OPTIONS requests (CORS preflight)."""
    
    fn __init__(out self):
        pass
    
    fn func(mut self, req: HTTPRequest) raises -> HTTPResponse:
        """Handle CORS preflight OPTIONS requests."""
        if req.method != "OPTIONS":
            return MethodNotAllowed()
        
        var headers = Headers()
        headers["Access-Control-Allow-Origin"] = "*"
        headers["Access-Control-Allow-Methods"] = "POST, OPTIONS"
        headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization, Mcp-Session-Id"
        headers["Access-Control-Max-Age"] = "86400"
        
        return OK(bytes(""), content_type="text/plain")

# Utility functions for transport configuration
fn create_mcp_transport(handler: MCPServer, 
                       allowed_origins: List[String] = List[String](),
                       require_origin_validation: Bool = True) -> HTTPTransport:
    """Create a configured MCP HTTP transport."""
    return HTTPTransport(handler, allowed_origins, require_origin_validation)

fn create_localhost_transport(handler: MCPServer) -> HTTPTransport:
    """Create an MCP transport that only allows localhost connections."""
    var allowed_origins = List[String]()
    allowed_origins.append("http://localhost")
    allowed_origins.append("http://127.0.0.1")
    allowed_origins.append("https://localhost")
    allowed_origins.append("https://127.0.0.1")
    
    return HTTPTransport(handler, allowed_origins, True)