from python import Python, PythonObject
from utils import Variant
from .jsonrpc import (
    JSONRPCRequest,
    JSONRPCResponse,
    JSONRPCNotification,
    JSONRPCError,
    parse_error,
    invalid_request
)

alias MessageType = Variant[JSONRPCRequest, JSONRPCResponse, JSONRPCNotification]

struct JSONRPCParser:
    """Parser for JSON-RPC 2.0 messages."""

    fn __init__(out self):
        pass

    fn parse_message(self, json_str: String) raises -> MessageType:
        """Parse a JSON-RPC message from string.

        Args:
            json_str: JSON string to parse

        Returns:
            Parsed message as JSONRPCRequest, JSONRPCResponse, or JSONRPCNotification

        Raises:
            Error if parsing fails or message is invalid
        """
        try:
            var json = Python.import_module("json")
            var data = json.loads(json_str)

            # Check for required jsonrpc field
            if "jsonrpc" not in data or data["jsonrpc"] != "2.0":
                raise Error("Invalid or missing jsonrpc version")

            # Check if this is a response (has result or error)
            if "result" in data or "error" in data:
                return self._parse_response(data)

            # Check if this is a request (has id) or notification (no id)
            if "id" in data:
                return self._parse_request(data)
            else:
                return self._parse_notification(data)

        except e:
            raise Error("Failed to parse JSON-RPC message: " + String(e))

    fn _parse_request(self, data: PythonObject) raises -> MessageType:
        """Parse JSON-RPC request from Python object."""
        if "method" not in data:
            raise Error("Request missing required 'method' field")

        var id_str = String(data["id"]) if "id" in data else ""
        var method = String(data["method"])
        var params = String(data.get("params", "{}"))

        var request = JSONRPCRequest(id_str, method, params)
        if not request.is_valid():
            raise Error("Invalid JSON-RPC request")

        return MessageType(request)

    fn _parse_response(self, data: PythonObject) raises -> MessageType:
        """Parse JSON-RPC response from Python object."""
        if "id" not in data:
            raise Error("Response missing required 'id' field")

        var id_str = String(data["id"])
        var result = String(data.get("result", ""))
        var error = String(data.get("error", ""))

        var response = JSONRPCResponse(id_str, result, error)
        if not response.is_valid():
            raise Error("Invalid JSON-RPC response")

        return MessageType(response)

    fn _parse_notification(self, data: PythonObject) raises -> MessageType:
        """Parse JSON-RPC notification from Python object."""
        if "method" not in data:
            raise Error("Notification missing required 'method' field")

        var method = String(data["method"])
        var params = String(data.get("params", "{}"))

        var notification = JSONRPCNotification(method, params)
        if not notification.is_valid():
            raise Error("Invalid JSON-RPC notification")

        return MessageType(notification)

struct JSONRPCSerializer:
    """Serializer for JSON-RPC 2.0 messages."""

    fn __init__(out self):
        pass

    fn serialize_request(self, request: JSONRPCRequest) -> String:
        """Serialize JSON-RPC request to JSON string."""
        return request.to_json()

    fn serialize_response(self, response: JSONRPCResponse) -> String:
        """Serialize JSON-RPC response to JSON string."""
        return response.to_json()

    fn serialize_notification(self, notification: JSONRPCNotification) -> String:
        """Serialize JSON-RPC notification to JSON string."""
        return notification.to_json()

    fn serialize_error_response(self, id: String, error: JSONRPCError) -> String:
        """Serialize JSON-RPC error response to JSON string."""
        var response = JSONRPCResponse.error_response(id, error)
        return response.to_json()

# Utility functions for common operations
fn create_error_response(id: String, code: Int, message: String, data: String = "") -> String:
    """Create a JSON-RPC error response."""
    var error = JSONRPCError(code, message, data)
    var response = JSONRPCResponse.error_response(id, error)
    return response.to_json()

fn create_success_response(id: String, result: String) -> String:
    """Create a JSON-RPC success response."""
    var response = JSONRPCResponse.success(id, result)
    return response.to_json()

fn validate_json_rpc_message(json_str: String) -> Bool:
    """Validate if a string is a valid JSON-RPC message."""
    try:
        var parser = JSONRPCParser()
        _ = parser.parse_message(json_str)
        return True
    except:
        return False