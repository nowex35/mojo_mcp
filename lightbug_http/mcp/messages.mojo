from .jsonrpc import JSONRPCResponse, JSONRPCNotification
from .utils import current_time_ms, JSONBuilder

# MCP Protocol Version
alias MCP_PROTOCOL_VERSION = "2025-06-18"


@value
struct MCPServerInfo(Movable):
    """Information about the MCP server."""
    var name: String
    var version: String

    fn __init__(out self, name: String, version: String):
        self.name = name
        self.version = version

    fn to_json(self) -> String:
        var builder = JSONBuilder()
        builder.add_string("name", self.name)
        builder.add_string("version", self.version)
        return builder.build()

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
        var builder = JSONBuilder()

        if self.tools:
            builder.add_raw("tools", '{"listChanged":false}')
        if self.resources:
            builder.add_raw("resources", '{"listChanged":false}')
        if self.prompts:
            builder.add_raw("prompts", '{"listChanged":false}')
        if self.logging:
            builder.add_raw("logging", '{}')
        if self.roots:
            builder.add_raw("roots", '{"listChanged":false}')
        if self.sampling:
            builder.add_raw("sampling", '{}')

        return builder.build()

# MCP-specific message creation functions
fn create_initialize_response(id: String, server_info: MCPServerInfo,
                            capabilities: MCPCapabilities) -> JSONRPCResponse:
    """Create an MCP initialize response."""
    var builder = JSONBuilder()
    builder.add_string("protocolVersion", MCP_PROTOCOL_VERSION)
    builder.add_raw("capabilities", capabilities.to_json())
    builder.add_raw("serverInfo", server_info.to_json())
    var result = builder.build()
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