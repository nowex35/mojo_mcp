from python import Python

alias JSONRPCVersion = "2.0"

# JSON-RPC 2.0 standard error codes
alias PARSE_ERROR = -32700
alias INVALID_REQUEST = -32600
alias METHOD_NOT_FOUND = -32601
alias INVALID_PARAMS = -32602
alias INTERNAL_ERROR = -32603
# Server error range: -32000 to -32099

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
        var json = String('{"code":', String(self.code), ',"message":"', self.message, '"')
        if self.data:
            json = json + ',"data":' + self.data
        json = json + "}"
        return json

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
        var json = String('{"jsonrpc":"', self.jsonrpc, '","id":"', self.id,
                         '","method":"', self.method, '"')
        if self.params != "{}":
            json = json + ',"params":' + self.params
        json = json + "}"
        return json

    fn is_valid(self) -> Bool:
        """Validate JSON-RPC request format."""
        return (self.jsonrpc == JSONRPCVersion and
                len(self.id) > 0 and
                len(self.method) > 0)

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
        var json = String('{"jsonrpc":"', self.jsonrpc, '","id":"', self.id, '"')

        if self.error:
            json = json + ',"error":' + self.error
        else:
            json = json + ',"result":' + self.result

        json = json + "}"
        return json

    fn is_valid(self) -> Bool:
        """Validate JSON-RPC response format."""
        return (self.jsonrpc == JSONRPCVersion and
                len(self.id) > 0 and
                (len(self.result) > 0) != (len(self.error) > 0))  # XOR: exactly one should be present

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
        var json = String('{"jsonrpc":"', self.jsonrpc, '","method":"', self.method, '"')
        if self.params != "{}":
            json = json + ',"params":' + self.params
        json = json + "}"
        return json

    fn is_valid(self) -> Bool:
        """Validate JSON-RPC notification format."""
        return (self.jsonrpc == JSONRPCVersion and
                len(self.method) > 0)

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
    return JSONRPCError(-32000, "Server not initialized")

fn server_already_initialized() -> JSONRPCError:
    """Server already initialized error."""
    return JSONRPCError(-32001, "Server already initialized")

fn unsupported_protocol_version(version: String) -> JSONRPCError:
    """Unsupported protocol version error."""
    return JSONRPCError(-32002, "Unsupported protocol version: " + version)

fn tool_not_found(tool_name: String) -> JSONRPCError:
    """Tool not found error."""
    return JSONRPCError(-32003, "Tool not found: " + tool_name)

fn tool_execution_failed(tool_name: String, reason: String) -> JSONRPCError:
    """Tool execution failed error."""
    return JSONRPCError(-32004, "Tool execution failed for " + tool_name + ": " + reason)

fn feature_not_implemented(feature: String) -> JSONRPCError:
    """Feature not implemented error."""
    return JSONRPCError(-32601, feature + " is not currently implemented")


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