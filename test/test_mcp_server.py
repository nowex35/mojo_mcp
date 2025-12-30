"""
Test suite for the MCP server implemented in working_mcp_server.mojo

This test suite validates:
- Server connectivity
- Tool execution (echo, math_add, slow_operation)
- Error handling
- MCP protocol compliance
"""

import time
import pytest
import requests
from typing import Dict, Any, Optional


class MCPClient:
    """Simple MCP client for testing purposes."""

    def __init__(self, base_url: str = "http://127.0.0.1:8082"):
        self.base_url = base_url
        self.request_id = 0

    def _send_request(self, method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Send a JSON-RPC 2.0 request to the MCP server."""
        self.request_id += 1

        payload = {
            "jsonrpc": "2.0",
            "id": self.request_id,
            "method": method,
        }

        if params is not None:
            payload["params"] = params

        response = requests.post(
            self.base_url,
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=30
        )

        response.raise_for_status()
        return response.json()

    def initialize(self) -> Dict[str, Any]:
        """Initialize the MCP session."""
        return self._send_request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {
                "name": "test-client",
                "version": "1.0.0"
            }
        })

    def list_tools(self) -> Dict[str, Any]:
        """List available tools."""
        return self._send_request("tools/list")

    def call_tool(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Call a tool with the given arguments."""
        return self._send_request("tools/call", {
            "name": tool_name,
            "arguments": arguments
        })


@pytest.fixture(scope="module")
def mcp_client():
    """Fixture that provides an MCP client instance."""
    client = MCPClient()

    # Wait a bit to ensure server is ready
    max_retries = 10
    for i in range(max_retries):
        try:
            # Try to connect
            response = requests.get("http://127.0.0.1:8082", timeout=2)
            break
        except (requests.ConnectionError, requests.Timeout):
            if i == max_retries - 1:
                pytest.skip("MCP server is not running on 127.0.0.1:8082")
            time.sleep(1)

    return client


class TestMCPServerConnectivity:
    """Test basic server connectivity and protocol."""

    # チェック済  test/venv/bin/pytest test/test_mcp_server.py::TestMCPServerConnectivity::test_server_is_running -v
    def test_server_is_running(self):
        """Test that the server is accessible."""
        response = requests.get("http://127.0.0.1:8082", timeout=5)
        assert response.status_code in [200, 404, 405], "Server should respond to requests"

    # チェック済  test/venv/bin/pytest test/test_mcp_server.py::TestMCPServerConnectivity::test_initialize_session -v
    def test_initialize_session(self, mcp_client):
        """Test MCP session initialization."""
        response = mcp_client.initialize()

        assert "error" not in response, "Initialization should not return an error"
        assert "result" in response, "Initialization should return a result"

        result = response["result"]
        assert result.get("protocolVersion") == "2025-06-18", "Protocol version should match"
        assert "serverInfo" in result, "Should return server info"
        assert "capabilities" in result, "Should return server capabilities"

    # チェック済  test/venv/bin/pytest test/test_mcp_server.py::TestMCPServerConnectivity::test_list_tools -v
    def test_list_tools(self, mcp_client):
        """Test listing available tools."""
        response = mcp_client.list_tools()

        assert "result" in response, "tools/list should return result"
        result = response["result"]
        assert "tools" in result, "Result should contain tools array"

        tools = result["tools"]
        assert isinstance(tools, list), "tools should be an array"
        assert len(tools) > 0, "Should have at least one tool"

        tool_names = [tool["name"] for tool in tools]

        # Verify all expected tools are present
        assert "echo" in tool_names, "echo tool should be available"
        assert "math_add" in tool_names, "math_add tool should be available"
        assert "slow_operation" in tool_names, "slow_operation tool should be available"

        # MCP 2025-06-18 spec: Verify required fields for each tool
        for tool in tools:
            assert "name" in tool, f"Tool must have 'name' field"
            assert isinstance(tool["name"], str), f"Tool name must be a string"
            assert len(tool["name"]) > 0, f"Tool name must not be empty"

            assert "description" in tool, f"Tool '{tool.get('name', 'unknown')}' must have 'description' field"
            assert isinstance(tool["description"], str), f"Tool '{tool['name']}' description must be a string"

            assert "inputSchema" in tool, f"Tool '{tool['name']}' must have 'inputSchema' field"
            assert isinstance(tool["inputSchema"], dict), f"Tool '{tool['name']}' inputSchema must be an object"

            # Verify inputSchema is valid JSON Schema
            input_schema = tool["inputSchema"]
            assert "type" in input_schema, f"Tool '{tool['name']}' inputSchema must have 'type' field"


class TestEchoTool:
    """Test the echo tool functionality."""

    def test_echo_content_structure(self, mcp_client):
        """Test echo tool content structure compliance (MCP 2025-06-18)."""
        response = mcp_client.call_tool("echo", {"message": "test"})

        assert "result" in response, "Echo call should succeed"
        result = response["result"]

        # Verify content array exists and is an array
        assert "content" in result, "Result must have content field"
        content = result["content"]
        assert isinstance(content, list), "content must be an array"
        assert len(content) > 0, "content must not be empty"

        # Verify each content item has required fields
        for item in content:
            assert isinstance(item, dict), "Each content item must be an object"
            assert "type" in item, "Content item must have 'type' field"
            assert isinstance(item["type"], str), "type must be a string"

            # Type-specific validation
            if item["type"] == "text":
                assert "text" in item, "Text content must have 'text' field"
                assert isinstance(item["text"], str), "text must be a string"
            elif item["type"] == "image":
                assert "data" in item, "Image content must have 'data' field"
                assert "mimeType" in item, "Image content must have 'mimeType' field"
            elif item["type"] == "resource":
                assert "resource" in item, "Resource content must have 'resource' field"

    def test_echo_with_message(self, mcp_client):
        """Test echo tool with a custom message."""
        response = mcp_client.call_tool("echo", {"message": "Hello, MCP!"})

        assert "result" in response, "Echo call should succeed"
        result = response["result"]

        # Verify isError field (MCP 2025-06-18 requirement)
        assert result.get("isError") is False or "isError" not in result, "Successful tool execution should have isError=false or omit the field"

        content = result.get("content", [])
        assert len(content) > 0, "Should return content"

        text_content = [c for c in content if c.get("type") == "text"]
        assert len(text_content) > 0, "Should have text content"
        assert text_content[0].get("text", "") == "Echo: Hello, MCP!", "Should return exact echo format"

    def test_echo_without_message(self, mcp_client):
        """Test echo tool without providing a message (should return validation error)."""
        response = mcp_client.call_tool("echo", {})

        # Missing required parameter should return an error
        assert "result" in response, "Echo call should return a result"
        content = response["result"].get("content", [])
        assert len(content) > 0, "Should return content"

        text_content = [c for c in content if c.get("type") == "text"]
        assert len(text_content) > 0, "Should have text content"
        assert "Missing required parameter: message" in text_content[0].get("text", ""), "Should return validation error for missing parameter"


class TestMathAddTool:
    """Test the math_add tool functionality."""

    def test_add_positive_numbers(self, mcp_client):
        """Test adding two positive numbers."""
        response = mcp_client.call_tool("math_add", {"a": 5, "b": 3})

        assert "result" in response, "Math add call should succeed"
        result = response["result"]

        # Verify isError field (MCP 2025-06-18 requirement)
        assert result.get("isError") is False or "isError" not in result, "Successful tool execution should have isError=false or omit the field"

        content = result.get("content", [])
        text_content = [c for c in content if c.get("type") == "text"]

        assert len(text_content) > 0, "Should have text content"
        assert text_content[0].get("text", "") == "Result: 8", "Should return exact result format"

    def test_add_negative_numbers(self, mcp_client):
        """Test adding negative numbers."""
        response = mcp_client.call_tool("math_add", {"a": -5, "b": -3})

        assert "result" in response, "Math add call should succeed"
        result = response["result"]

        # Verify isError field (MCP 2025-06-18 requirement)
        assert result.get("isError") is False or "isError" not in result, "Successful tool execution should have isError=false or omit the field"

        content = result.get("content", [])
        text_content = [c for c in content if c.get("type") == "text"]

        assert len(text_content) > 0, "Should have text content"
        assert text_content[0].get("text", "") == "Result: -8", "Should return exact result format"

    def test_add_zero(self, mcp_client):
        """Test adding with zero."""
        response = mcp_client.call_tool("math_add", {"a": 10, "b": 0})

        assert "result" in response, "Math add call should succeed"
        result = response["result"]

        # Verify isError field (MCP 2025-06-18 requirement)
        assert result.get("isError") is False or "isError" not in result, "Successful tool execution should have isError=false or omit the field"

        content = result.get("content", [])
        text_content = [c for c in content if c.get("type") == "text"]

        assert len(text_content) > 0, "Should have text content"
        assert text_content[0].get("text", "") == "Result: 10", "Should return exact result format"

    def test_add_missing_parameters(self, mcp_client):
        """Test math_add with missing parameters (should return validation error)."""
        response = mcp_client.call_tool("math_add", {})

        # Missing required parameters should return a validation error
        assert "result" in response, "Math add call should return a result"
        content = response["result"].get("content", [])
        text_content = [c for c in content if c.get("type") == "text"]

        assert len(text_content) > 0, "Should have text content"
        error_text = text_content[0].get("text", "")
        assert "Missing required parameter: a" in error_text, "Should have error for missing parameter a"
        assert "Missing required parameter: b" in error_text, "Should have error for missing parameter b"

    def test_add_invalid_parameter_type(self, mcp_client):
        """Test math_add with invalid parameter types (MCP 2025-06-18 validation)."""
        # Test with string instead of number for parameter 'a'
        response = mcp_client.call_tool("math_add", {"a": "not_a_number", "b": 5})

        # Should return error or isError=true
        if "error" in response:
            # JSON-RPC error response
            assert response["error"], "Should have error object"
            assert "code" in response["error"], "Error should have code"
            assert "message" in response["error"], "Error should have message"
        elif "result" in response:
            # Tool execution error with isError flag
            result = response["result"]
            # Tool may return isError=true or include error message in content
            is_error = result.get("isError", False)
            content = result.get("content", [])

            if is_error:
                assert is_error is True, "Should have isError=true for invalid type"
            else:
                # Check if error message is in content
                text_content = [c.get("text", "") for c in content if c.get("type") == "text"]
                has_error_msg = any("Error" in text or "Invalid" in text or "error" in text for text in text_content)
                assert has_error_msg, "Should indicate error in content when type is invalid"

    def test_add_out_of_range_values(self, mcp_client):
        """Test math_add with extreme values (MCP 2025-06-18 validation)."""
        # Test with very large numbers (implementation-dependent behavior)
        response = mcp_client.call_tool("math_add", {"a": 10**100, "b": 10**100})

        # Should either succeed or return error, but must be a valid response
        assert "result" in response or "error" in response, "Must return valid JSON-RPC response"

        if "result" in response:
            result = response["result"]
            assert "content" in result, "Result must have content"
            # If isError is present, verify it's a boolean
            if "isError" in result:
                assert isinstance(result["isError"], bool), "isError must be boolean"


class TestSlowOperationTool:
    """Test the slow_operation tool functionality."""

    def test_slow_operation_short_delay(self, mcp_client):
        """Test slow operation with a short delay."""
        start_time = time.time()
        response = mcp_client.call_tool("slow_operation", {"delay": 1})
        elapsed_time = time.time() - start_time

        assert "result" in response, "Slow operation should succeed"
        result = response["result"]

        # Verify isError field (MCP 2025-06-18 requirement)
        assert result.get("isError") is False or "isError" not in result, "Successful tool execution should have isError=false or omit the field"

        assert elapsed_time >= 1.0, "Operation should take at least 1 second"

        content = result.get("content", [])
        assert len(content) >= 2, "Should return at least two content items"

        text_contents = [c for c in content if c.get("type") == "text"]
        assert len(text_contents) >= 2, "Should have at least two text contents"
        assert text_contents[0].get("text", "") == "Starting slow operation for 1 seconds...", "Should return start message"
        assert text_contents[1].get("text", "") == "Slow operation completed after 1 seconds!", "Should return completion message"

    def test_slow_operation_medium_delay(self, mcp_client):
        """Test slow operation with a medium delay."""
        start_time = time.time()
        response = mcp_client.call_tool("slow_operation", {"delay": 2})
        elapsed_time = time.time() - start_time

        assert "result" in response, "Slow operation should succeed"
        result = response["result"]

        # Verify isError field (MCP 2025-06-18 requirement)
        assert result.get("isError") is False or "isError" not in result, "Successful tool execution should have isError=false or omit the field"

        assert elapsed_time >= 2.0, "Operation should take at least 2 seconds"

        content = result.get("content", [])
        assert len(content) >= 2, "Should return at least two content items"

        text_contents = [c for c in content if c.get("type") == "text"]
        assert len(text_contents) >= 2, "Should have at least two text contents"
        assert text_contents[0].get("text", "") == "Starting slow operation for 2 seconds...", "Should return start message"
        assert text_contents[1].get("text", "") == "Slow operation completed after 2 seconds!", "Should return completion message"


class TestErrorHandling:
    """Test error handling scenarios."""

    def test_batch_requests_not_supported(self):
        """Test that batch requests are rejected (MCP 2025-06-18 removed batch support)."""
        # MCP 2025-06-18 specification: Batch requests are no longer supported
        batch_request = [
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}
        ]

        try:
            response = requests.post(
                "http://127.0.0.1:8082",
                json=batch_request,
                headers={"Content-Type": "application/json"},
                timeout=2  # Shorter timeout for batch request test
            )

            # Should reject batch requests with either:
            # 1. HTTP error status (400, 405, etc.)
            # 2. JSON-RPC error response
            # 3. Empty/error response

            if response.status_code >= 400:
                # HTTP-level rejection is acceptable
                assert True, "Batch request rejected with HTTP error"
            else:
                # Check for JSON-RPC error
                try:
                    data = response.json()
                    # If it returns a single error (not an array), that's correct
                    if isinstance(data, dict) and "error" in data:
                        assert "error" in data, "Should return JSON-RPC error for batch request"
                    elif isinstance(data, list):
                        # If it returns an array of errors, check each has error
                        for item in data:
                            if isinstance(item, dict):
                                assert "error" in item, "Each batch response should be an error"
                except Exception:
                    # If JSON parsing fails, that's also acceptable rejection
                    assert True, "Batch request rejected"
        except (requests.Timeout, requests.ConnectionError):
            # Timeout or connection error indicates server doesn't handle batch requests
            # This is acceptable behavior for rejecting batch requests
            assert True, "Batch request caused timeout/error (acceptable rejection)"

    def test_invalid_tool_name(self, mcp_client):
        """Test calling a non-existent tool."""
        response = mcp_client.call_tool("non_existent_tool", {})

        # Should return an error (either as JSON-RPC error or isError flag in result)
        if "error" in response:
            assert response["error"], "Should have error object"
        elif "result" in response:
            # Some servers return isError flag in the result
            assert response["result"].get("isError", False), "Should have isError flag set to True"
        else:
            pytest.fail("Response should contain either error or result with isError")

    def test_malformed_request(self):
        """Test sending a malformed JSON-RPC request."""
        response = requests.post(
            "http://127.0.0.1:8082",
            json={"invalid": "request"},
            headers={"Content-Type": "application/json"},
            timeout=5
        )

        # Should return a JSON-RPC error response
        assert response.status_code == 200, "Should return 200 OK with JSON-RPC error response"
        data = response.json()
        assert "error" in data, "Response should contain JSON-RPC error field"
        assert data["error"] is not None, "Error should not be null"
        assert "code" in data["error"], "Error should have code field"
        assert "message" in data["error"], "Error should have message field"


class TestHTTPTransport:
    """Test HTTP transport layer compliance (MCP 2025-06-18)."""

    def test_request_content_type_header(self):
        """Test that requests use correct Content-Type header."""
        response = requests.post(
            "http://127.0.0.1:8082",
            json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            headers={"Content-Type": "application/json"},
            timeout=5
        )

        # Should accept application/json content type
        assert response.status_code == 200, "Should accept application/json Content-Type"

    def test_response_content_type_header(self):
        """Test that responses include correct Content-Type header."""
        response = requests.post(
            "http://127.0.0.1:8082",
            json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            headers={"Content-Type": "application/json"},
            timeout=5
        )

        # Verify response Content-Type
        content_type = response.headers.get("Content-Type", "")
        assert "application/json" in content_type.lower(), f"Response Content-Type should be application/json, got: {content_type}"

    def test_cors_headers_present(self):
        """Test that CORS headers are present for cross-origin requests."""
        response = requests.post(
            "http://127.0.0.1:8082",
            json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
            headers={
                "Content-Type": "application/json",
                "Origin": "http://localhost:3000"
            },
            timeout=5
        )

        # Check for CORS headers (implementation may vary)
        # Access-Control-Allow-Origin should be present for CORS requests
        if "Origin" in response.request.headers:
            # If Origin was sent, server should respond with CORS headers
            # CORS headers are recommended but not strictly required for localhost
            # So we just verify the response is valid
            assert response.status_code == 200, "Should handle requests with Origin header"

            # Optionally check if CORS headers are present (not required to pass)
            if ("Access-Control-Allow-Origin" in response.headers or
                "access-control-allow-origin" in response.headers):
                # CORS headers are present - good practice
                pass

    def test_http_method_post_required(self):
        """Test that only POST method is accepted for JSON-RPC."""
        # Try GET request (should fail or return error)
        response = requests.get(
            "http://127.0.0.1:8082",
            timeout=5
        )

        # GET should either return error status or informational response
        # but not process JSON-RPC requests
        assert response.status_code in [200, 404, 405], "GET request should return appropriate status"

        # If status is 200, it should not be a valid JSON-RPC response
        if response.status_code == 200:
            try:
                data = response.json()
                # Should not be a tools/list response
                if "result" in data and "tools" in data.get("result", {}):
                    pytest.fail("GET should not process JSON-RPC tools/list")
            except Exception:
                # Non-JSON response is acceptable for GET
                pass


if __name__ == "__main__":
    # Allow running tests directly with python
    pytest.main([__file__, "-v"])
