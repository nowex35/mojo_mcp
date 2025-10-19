from .jsonrpc import JSONRPCRequest, JSONRPCResponse, JSONRPCNotification
from .utils import current_time_ms

# MCP Protocol Version
alias MCP_PROTOCOL_VERSION = "2025-06-18"

@value
struct MCPClientInfo(Movable):
    """Information about the MCP client."""
    var name: String
    var version: String
    
    fn __init__(out self, name: String, version: String):
        self.name = name
        self.version = version
    
    fn to_json(self) -> String:
        return String('{"name":"', self.name, '","version":"', self.version, '"}')

@value 
struct MCPServerInfo(Movable):
    """Information about the MCP server."""
    var name: String
    var version: String

    fn __init__(out self, name: String, version: String):
        self.name = name
        self.version = version
    
    fn to_json(self) -> String:
        return String('{"name":"', self.name, '","version":"', self.version, '"}')

@value
struct MCPCapabilities(Movable):
    """MCP server or client capabilities."""
    var tools: Bool
    var resources: Bool
    var prompts: Bool
    var logging: Bool
    var roots: Bool
    var sampling: Bool
    
    fn __init__(
        out self, 
        tools: Bool = False,
        resources: Bool = False,
        prompts: Bool = False,
        logging: Bool = False,
        roots: Bool = False,
        sampling: Bool = False
        ):
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.logging = logging
        self.roots = roots
        self.sampling = sampling
    
    fn to_json(self) -> String:
        var json = String("{")
        var first = True

        if self.tools:
            json = json + '"tools":{"listChanged":false}'
            first = False
        if self.resources:
            if not first:
                json = json + ","
            json = json + '"resources":{"listChanged":false}'
            first = False
        if self.prompts:
            if not first:
                json = json + ","
            json = json + '"prompts":{"listChanged":false}'
            first = False
        if self.logging:
            if not first:
                json = json + ","
            json = json + '"logging":{}'
            first = False
        if self.roots:
            if not first:
                json = json + ","
            json = json + '"roots":{"listChanged":false}'
            first = False
        if self.sampling:
            if not first:
                json = json + ","
            json = json + '"sampling":{}'

        json = json + "}"
        return json

# MCP-specific message creation functions
fn create_initialize_response(id: String, server_info: MCPServerInfo,
                            capabilities: MCPCapabilities) -> JSONRPCResponse:
    """Create an MCP initialize response."""
    var result = String('{"protocolVersion":"', MCP_PROTOCOL_VERSION,
                       '","capabilities":', capabilities.to_json(),
                       ',"serverInfo":', server_info.to_json(), '}')
    return JSONRPCResponse.success(id, result)

fn create_initialized_notification() -> JSONRPCNotification:
    """Create an MCP initialized notification."""
    return JSONRPCNotification("initialized", "{}")

# MCP message validation functions

fn is_mcp_method(method: String) -> Bool:
    """Check if a method name is a valid MCP method."""
    var mcp_methods = ["initialize", "initialized"]
    var mcp_prefixes = ["tools/", "resources/", "prompts/", "logging/", "roots/", "sampling/"]
    
    # Check exact matches
    for mcp_method in mcp_methods:
        if method == mcp_method:
            return True
    
    # Check prefix matches
    for prefix in mcp_prefixes:
        if method.startswith(prefix):
            return True
    
    return False

# Protocol version validation
fn is_compatible_version(version: String) -> Bool:
    """Check if a protocol version is compatible with this implementation."""
    return version == MCP_PROTOCOL_VERSION

@value
struct MCPMessage(Movable):
    """Wrapper for MCP messages with metadata."""
    var request_id: String
    var method: String
    var timestamp: Int
    var raw_json: String
    
    fn __init__(out self, request_id: String, method: String, raw_json: String):
        self.request_id = request_id
        self.method = method
        self.timestamp = current_time_ms()
        self.raw_json = raw_json
    
    fn is_valid_mcp_message(self) -> Bool:
        """Check if this is a valid MCP message."""
        return is_mcp_method(self.method)