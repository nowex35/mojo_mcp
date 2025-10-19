from lightbug_http.mcp import MCPServer
from lightbug_http.mcp.tools import MCPToolResult, MCPToolRequest, create_string_parameter,create_number_parameter
from time import sleep

fn example_echo_tool(request: MCPToolRequest) raises -> MCPToolResult:
    var result = MCPToolResult()

    var message = request.get_string("message", "No message provided")

    result.add_text_content("Echo: " + message)
    return result

fn example_math_tool(request: MCPToolRequest) raises -> MCPToolResult:
    var result = MCPToolResult()

    try:
        var a_int = request.get_int("a", 0)
        var b_int = request.get_int("b", 0)
        var sum = a_int + b_int

        result.add_text_content("Result: " + String(sum))
    except:
        result.add_text_content("Error: Invalid values provided. Please provide valid integer values for 'a' and 'b'.")

    return result

fn example_slow_tool(request: MCPToolRequest) raises -> MCPToolResult:
    """Example tool that takes a long time to demonstrate timeout functionality."""
    var result = MCPToolResult()

    # Get the delay parameter
    var delay_seconds: UInt = request.get_int("delay", 5)

    result.add_text_content("Starting slow operation for " + String(delay_seconds) + " seconds...")

    # Simulate slow work using actual sleep
    sleep(delay_seconds)

    result.add_text_content("Slow operation completed after " + String(delay_seconds) + " seconds!")
    return result

fn main() raises:

    var mcp_server = MCPServer(server_name="lightbug-mcp", server_version="1.0.0")

    # Register tools
    mcp_server.tool(
        name="echo",
        description="Echoes back the provided message",
        parameters=create_string_parameter("message", "The message to echo", True),
        executor=example_echo_tool
    )

    mcp_server.tool(
        name="math_add",
        description="Performs addition of two numbers",
        parameters=[create_number_parameter("a", "First number", True), create_number_parameter("b", "Second number", True)],
        executor=example_math_tool
    )

    mcp_server.tool(
        name="slow_operation",
        description="A tool that simulates a slow operation to test timeout functionality",
        parameters=create_number_parameter("delay", "Delay in seconds for the operation", True),
        executor=example_slow_tool
    )

    mcp_server.start(address="127.0.0.1:8083")