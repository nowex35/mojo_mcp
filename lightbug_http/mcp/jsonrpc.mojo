from python import Python, PythonObject
from utils import Variant
from .utils import JSONBuilder, escape_json_string

alias JSONRPCVersion = "2.0"

# Forward declarations for MessageType
# (Actual structs defined below)
alias MessageType = Variant[JSONRPCRequest, JSONRPCResponse, JSONRPCNotification]

# JSON-RPC 2.0 standard error codes
alias PARSE_ERROR = -32700
alias INVALID_REQUEST = -32600
alias METHOD_NOT_FOUND = -32601
alias INVALID_PARAMS = -32602
alias INTERNAL_ERROR = -32603
# Server error range: -32000 to -32099
alias SERVER_NOT_INITIALIZED = -32000
alias SERVER_ALREADY_INITIALIZED = -32001
alias UNSUPPORTED_PROTOCOL_VERSION = -32002
alias TOOL_NOT_FOUND = -32003
alias TOOL_EXECUTION_FAILED = -32004

@value
struct JSONRPCError(Movable):
    """JSON-RPC 2.0 Error object."""

    var code: Int # エラーコード
    var message: String # エラーメッセージ
    var data: String  # オプションの追加エラーデータとしてJSON文字列

    fn __init__(out self, code: Int, message: String, data: String = ""):
        self.code = code
        self.message = message
        self.data = data

    fn to_json(self) -> String:
        """Convert error to JSON string."""
        var builder = JSONBuilder()
        builder.add_int("code", self.code)
        builder.add_string("message", self.message)
        if self.data:
            builder.add_raw("data", self.data)
        return builder.build()

@value
struct JSONRPCRequest(Movable):
    """JSON-RPC 2.0 Request message.

    Must include:
    - jsonrpc: "2.0"
    - id: string or number (non-null)
    - method: string
    - params: object (optional)
    """

    var jsonrpc: String # JSON-RPCバージョン
    var id: String  # Can be string or number, stored as string
    var method: String # メソッド名 "tools/call"や"initialize"など。
    var params: String  # JSON string for parameters

    fn __init__(out self, id: String, method: String, params: String = "{}"):
        self.jsonrpc = JSONRPCVersion
        self.id = id
        self.method = method
        self.params = params

    fn __init__(out self, id: Int, method: String, params: String = "{}"):
        self.jsonrpc = JSONRPCVersion
        self.id = String(id)
        self.method = method
        self.params = params

    fn to_json(self) -> String:
        """Convert request to JSON string."""
        var builder = JSONBuilder()
        builder.add_string("jsonrpc", self.jsonrpc)
        builder.add_string("id", self.id)
        builder.add_string("method", self.method)
        if self.params != "{}":
            builder.add_raw("params", self.params)
        return builder.build()

    fn is_valid(self) -> Bool:
        """Validate JSON-RPC request format."""
        return (self.jsonrpc == JSONRPCVersion and
                len(self.id) > 0 and
                len(self.method) > 0)

    @staticmethod
    fn from_json(json_str: String) raises -> JSONRPCRequest:
        """Parse JSONRPCRequest from JSON string.

        Args:
            json_str: JSON string to parse

        Returns:
            Parsed JSONRPCRequest

        Raises:
            Error if parsing fails or request is invalid
        """
        var json = Python.import_module("json")
        var data = json.loads(json_str)

        if "method" not in data:
            raise Error("Request missing required 'method' field")

        var id_str = String(data["id"]) if "id" in data else ""
        var method = String(data["method"])
        var params = String(data.get("params", "{}"))

        var request = JSONRPCRequest(id_str, method, params)
        if not request.is_valid():
            raise Error("Invalid JSON-RPC request")

        return request

@value
struct JSONRPCResponse(Movable):
    """JSON-RPC 2.0 Response message.

    Must include:
    - jsonrpc: "2.0"
    - id: matching the request id
    - result OR error (but not both)
    """

    var jsonrpc: String
    var id: String
    var result: String  # JSON string for result
    var error: String   # JSON string for error (empty if success)

    fn __init__(out self, id: String, result: String = "", error: String = ""):
        self.jsonrpc = JSONRPCVersion
        self.id = id
        self.result = result
        self.error = error

    @staticmethod
    fn success(id: String, result: String) -> JSONRPCResponse:
        """Create a success response."""
        return JSONRPCResponse(id, result, "")

    @staticmethod
    fn error_response(id: String, error: JSONRPCError) -> JSONRPCResponse:
        """Create an error response."""
        return JSONRPCResponse(id, "", error.to_json())

    fn to_json(self) -> String:
        """Convert response to JSON string."""
        var builder = JSONBuilder()
        builder.add_string("jsonrpc", self.jsonrpc)
        builder.add_string("id", self.id)

        if self.error:
            builder.add_raw("error", self.error)
        else:
            builder.add_raw("result", self.result)

        return builder.build()

    fn is_valid(self) -> Bool:
        """Validate JSON-RPC response format."""
        return (self.jsonrpc == JSONRPCVersion and
                len(self.id) > 0 and
                (len(self.result) > 0) != (len(self.error) > 0))  # XOR: exactly one should be present

    @staticmethod
    fn from_json(json_str: String) raises -> JSONRPCResponse:
        """Parse JSONRPCResponse from JSON string.

        Args:
            json_str: JSON string to parse

        Returns:
            Parsed JSONRPCResponse

        Raises:
            Error if parsing fails or response is invalid
        """
        var json = Python.import_module("json")
        var data = json.loads(json_str)

        if "id" not in data:
            raise Error("Response missing required 'id' field")

        var id_str = String(data["id"])
        var result = String(data.get("result", ""))
        var error = String(data.get("error", ""))

        var response = JSONRPCResponse(id_str, result, error)
        if not response.is_valid():
            raise Error("Invalid JSON-RPC response")

        return response

@value
struct JSONRPCNotification(Movable):
    """JSON-RPC 2.0 Notification message.

    Must include:
    - jsonrpc: "2.0"
    - method: string
    - params: object (optional)

    Must NOT include:
    - id
    """

    var jsonrpc: String
    var method: String
    var params: String  # JSON string for parameters

    fn __init__(out self, method: String, params: String = "{}"):
        self.jsonrpc = JSONRPCVersion
        self.method = method
        self.params = params

    fn to_json(self) -> String:
        """Convert notification to JSON string."""
        var builder = JSONBuilder()
        builder.add_string("jsonrpc", self.jsonrpc)
        builder.add_string("method", self.method)
        if self.params != "{}":
            builder.add_raw("params", self.params)
        return builder.build()

    fn is_valid(self) -> Bool:
        """Validate JSON-RPC notification format."""
        return (self.jsonrpc == JSONRPCVersion and
                len(self.method) > 0)

    @staticmethod
    fn from_json(json_str: String) raises -> JSONRPCNotification:
        """Parse JSONRPCNotification from JSON string.

        Args:
            json_str: JSON string to parse

        Returns:
            Parsed JSONRPCNotification

        Raises:
            Error if parsing fails or notification is invalid
        """
        var json = Python.import_module("json")
        var data = json.loads(json_str)

        if "method" not in data:
            raise Error("Notification missing required 'method' field")

        var method = String(data["method"])
        var params = String(data.get("params", "{}"))

        var notification = JSONRPCNotification(method, params)
        if not notification.is_valid():
            raise Error("Invalid JSON-RPC notification")

        return notification

# Standard JSON-RPC errors
fn parse_error() -> JSONRPCError:
    """Parse error - Invalid JSON was received by the server."""
    return JSONRPCError(PARSE_ERROR, "Parse error")

fn invalid_request() -> JSONRPCError:
    """Invalid Request - The JSON sent is not a valid Request object."""
    return JSONRPCError(INVALID_REQUEST, "Invalid Request")

fn method_not_found() -> JSONRPCError:
    """Method not found - The method does not exist / is not available."""
    return JSONRPCError(METHOD_NOT_FOUND, "Method not found")

fn invalid_params() -> JSONRPCError:
    """Invalid params - Invalid method parameter(s)."""
    return JSONRPCError(INVALID_PARAMS, "Invalid params")

fn internal_error() -> JSONRPCError:
    """Internal error - Internal JSON-RPC error."""
    return JSONRPCError(INTERNAL_ERROR, "Internal error")


# Server error functions (MCP-specific errors)
fn server_not_initialized() -> JSONRPCError:
    """Server not initialized error."""
    return JSONRPCError(SERVER_NOT_INITIALIZED, "Server not initialized")

fn server_already_initialized() -> JSONRPCError:
    """Server already initialized error."""
    return JSONRPCError(SERVER_ALREADY_INITIALIZED, "Server already initialized")

fn unsupported_protocol_version(version: String) -> JSONRPCError:
    """Unsupported protocol version error."""
    return JSONRPCError(UNSUPPORTED_PROTOCOL_VERSION, "Unsupported protocol version: " + version)

fn tool_not_found(tool_name: String) -> JSONRPCError:
    """Tool not found error."""
    return JSONRPCError(TOOL_NOT_FOUND, "Tool not found: " + tool_name)

fn tool_execution_failed(tool_name: String, reason: String) -> JSONRPCError:
    """Tool execution failed error."""
    return JSONRPCError(TOOL_EXECUTION_FAILED, "Tool execution failed for " + tool_name + ": " + reason)


# Utility function to create custom errors
fn create_error(code: Int, message: String) -> JSONRPCError:
    """Create a custom JSON-RPC error."""
    return JSONRPCError(code, message)

fn log_error(error: JSONRPCError, context: String = ""):
    """Log an error for debugging to stderr (MCP-compliant)."""
    var log_message = "JSON-RPC Error: " + error.message
    if context != "":
        log_message = log_message + " (Context: " + context + ")"
    try:
        var python = Python.import_module("sys")
        python.stderr.write("[MCP-JSONRPC] " + log_message + "\n")
        python.stderr.flush()
    except:
        pass


# Message parsing function
fn parse_message(json_str: String) raises -> MessageType:
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
            var response = JSONRPCResponse.from_json(json_str)
            return MessageType(response)

        # Check if this is a request (has id) or notification (no id)
        if "id" in data:
            var request = JSONRPCRequest.from_json(json_str)
            return MessageType(request)
        else:
            var notification = JSONRPCNotification.from_json(json_str)
            return MessageType(notification)

    except e:
        raise Error("Failed to parse JSON-RPC message: " + String(e))


# Utility functions for creating responses (replaces JSONRPCSerializer functionality)
fn create_error_response(id: String, code: Int, message: String, data: String = "") -> String:
    """Create a JSON-RPC error response.

    Args:
        id: Request ID
        code: Error code
        message: Error message
        data: Optional error data

    Returns:
        JSON-RPC error response as string
    """
    var error = JSONRPCError(code, message, data)
    var response = JSONRPCResponse.error_response(id, error)
    return response.to_json()


fn create_success_response(id: String, result: String) -> String:
    """Create a JSON-RPC success response.

    Args:
        id: Request ID
        result: Result data as JSON string

    Returns:
        JSON-RPC success response as string
    """
    var response = JSONRPCResponse.success(id, result)
    return response.to_json()


fn validate_json_rpc_message(json_str: String) -> Bool:
    """Validate if a string is a valid JSON-RPC message.

    Args:
        json_str: JSON string to validate

    Returns:
        True if valid JSON-RPC message, False otherwise
    """
    try:
        _ = parse_message(json_str)
        return True
    except:
        return False