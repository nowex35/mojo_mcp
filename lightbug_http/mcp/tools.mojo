from collections import Dict, List
from .utils import current_time_ms,add_json_key_value
from time import sleep
from lightbug_http._libc import fork, exit, kill, waitpid, SIGKILL, WNOHANG, c_int, pid_t
from memory import UnsafePointer
import os

# Tool input schema types
alias MCPToolInputType = String
alias TOOL_TYPE_STRING: MCPToolInputType = "string"
alias TOOL_TYPE_NUMBER: MCPToolInputType = "number"
alias TOOL_TYPE_BOOLEAN: MCPToolInputType = "boolean"
alias TOOL_TYPE_OBJECT: MCPToolInputType = "object"
alias TOOL_TYPE_ARRAY: MCPToolInputType = "array"

@value
struct MCPToolParameter(Movable):
    """A tool parameter definition with JSON Schema validation."""
    var name: String
    var type: MCPToolInputType
    var description: String
    var required: Bool
    var default_value: String  # JSON string representation
    var enum_values: List[String]  # For enum validation

    fn __init__(out self, name: String, type: MCPToolInputType,
                description: String, required: Bool = True,
                default_value: String = "", enum_values: List[String] = List[String]()):
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.default_value = default_value
        self.enum_values = enum_values

    fn to_json(self) -> String:
        """Convert parameter to JSON Schema format."""
        var json = String('{"type":"', escape_json_string(self.type), '","description":"', escape_json_string(self.description), '"')

        # Add enum values if present
        if len(self.enum_values) > 0:
            json = json + ',"enum":['
            for i in range(len(self.enum_values)):
                if i > 0:
                    json = json + ","
                json = json + '"' + escape_json_string(self.enum_values[i]) + '"'
            json = json + "]"

        # Add default value if present (Note: default_value should already be valid JSON)
        if self.default_value != "":
            json = json + ',"default":' + self.default_value

        json = json + "}"
        return json

@value
struct MCPTool(Movable):
    """Definition of an MCP tool with its metadata and parameters."""
    var name: String
    var description: String
    var input_schema: Dict[String, MCPToolParameter]
    var required_params: List[String]
    var version: String
    var enabled: Bool

    fn __init__(out self, name: String, description: String,
                parameters: MCPToolParameter,
                version: String = "1.0.0", enabled: Bool = True):
        self.name = name
        self.description = description
        self.input_schema = Dict[String, MCPToolParameter]()
        self.required_params = List[String]()
        self.version = version
        self.enabled = enabled

        self.add_parameter(parameters)

    fn __init__(out self, name: String, description: String,
                parameters: List[MCPToolParameter],
                version: String = "1.0.0", enabled: Bool = True):
        self.name = name
        self.description = description
        self.input_schema = Dict[String, MCPToolParameter]()
        self.required_params = List[String]()
        self.version = version
        self.enabled = enabled

        for param in parameters:
            self.add_parameter(param)

    fn add_parameter(mut self, param: MCPToolParameter):
        """Add a parameter to this tool."""
        self.input_schema[param.name] = param
        if param.required:
            self.required_params.append(param.name)

    fn to_json(self) raises -> String:
        """Convert tool definition to MCP JSON format."""
        var json = String('{"name":"', escape_json_string(self.name), '","description":"', escape_json_string(self.description), '"')

        # Add input schema with required parameters inside
        json = json + ',"inputSchema":{"type":"object","properties":{'
        var first = True
        for param_name in self.input_schema:
            if not first:
                json = json + ","
            var param = self.input_schema[param_name]
            json = json + '"' + escape_json_string(param_name) + '":' + param.to_json()
            first = False

        json = json + "}"

        # Add required parameters inside inputSchema
        if len(self.required_params) > 0:
            json = json + ',"required":['
            for i in range(len(self.required_params)):
                if i > 0:
                    json = json + ","
                json = json + '"' + escape_json_string(self.required_params[i]) + '"'
            json = json + "]"

        json = json + "}"

        # For maximum compatibility, we'll omit them for now

        json = json + "}"
        return json

    fn validate_arguments(self, arguments_json: String) raises -> ValidationResult:
        """Validate provided arguments against the tool's schema."""
        var result = ValidationResult()

        # Parse JSON arguments (simplified parsing)
        var parsed_args = self._parse_json_arguments(arguments_json)

        # Check required parameters
        for required_param in self.required_params:
            if required_param not in parsed_args:
                result.add_error("Missing required parameter: " + required_param)

        # Validate parameter types and constraints
        for param_name in parsed_args:
            if param_name in self.input_schema:
                var param_def = self.input_schema[param_name]
                var param_value = parsed_args[param_name]

                var param_validation = self._validate_parameter(param_def, param_value)
                if not param_validation.is_valid:
                    result.add_error("Parameter '" + param_name + "': " + param_validation.error_message)
            else:
                result.add_warning("Unknown parameter: " + param_name)

        return result

    fn _parse_json_arguments(self, arguments_json: String) -> Dict[String, String]:
        """Parse JSON arguments into a simple key-value map."""
        var args = Dict[String, String]()

        # Simplified JSON parsing - extract key-value pairs
        # This is a basic implementation; in production, use a proper JSON parser
        var json_str = arguments_json.strip()
        if json_str.startswith("{") and json_str.endswith("}"):
            json_str = json_str[1:-1]  # Remove braces

            var pairs = json_str.split(",")
            for i in range(len(pairs)):
                var pair = pairs[i].strip()
                if ":" in pair:
                    var parts = pair.split(":", 1)
                    if len(parts) >= 2:
                        var key = String(parts[0].strip().strip('"'))
                        var value = String(parts[1].strip())
                        args[key] = value

        return args

    fn _validate_parameter(self, param_def: MCPToolParameter, value: String) -> ParameterValidationResult:
        """Validate a single parameter against its definition."""
        var result = ParameterValidationResult()

        # Remove quotes from string values
        var clean_value = String(value.strip().strip('"'))

        # Type validation
        if param_def.type == TOOL_TYPE_STRING:
            # String validation - already clean
            pass
        elif param_def.type == TOOL_TYPE_NUMBER:
            # Number validation
            if not self._is_number(clean_value):
                result.is_valid = False
                result.error_message = "Expected number, got: " + clean_value
                return result
        elif param_def.type == TOOL_TYPE_BOOLEAN:
            # Boolean validation
            if clean_value != "true" and clean_value != "false":
                result.is_valid = False
                result.error_message = "Expected boolean (true/false), got: " + clean_value
                return result

        # Enum validation
        if len(param_def.enum_values) > 0:
            var valid_enum = False
            for enum_value in param_def.enum_values:
                if clean_value == enum_value:
                    valid_enum = True
                    break

            if not valid_enum:
                result.is_valid = False
                result.error_message = "Value must be one of: " + self._join_enum_values(param_def.enum_values)
                return result

        return result

    fn _is_number(self, value: String) -> Bool:
        """Check if a string represents a valid number."""
        if len(value) == 0:
            return False

        var has_dot = False
        var start_idx = 0

        # Check for negative sign
        if len(value) > 0 and String(value[0]) == "-":
            start_idx = 1
            if len(value) == 1:
                return False

        # Check each character
        for i in range(start_idx, len(value)):
            var char = String(value[i])
            if char == ".":
                if has_dot:
                    return False  # Multiple dots
                has_dot = True
            elif not (char >= "0" and char <= "9"):
                return False  # Non-digit character

        return True

    fn _join_enum_values(self, enum_values: List[String]) -> String:
        """Join enum values into a readable string."""
        var result = String()
        for i in range(len(enum_values)):
            if i > 0:
                result = result + ", "
            result = result + enum_values[i]
        return result

@value
struct ValidationResult(Movable):
    """Result of tool argument validation."""
    var is_valid: Bool
    var errors: List[String]
    var warnings: List[String]

    fn __init__(out self):
        self.is_valid = True
        self.errors = List[String]()
        self.warnings = List[String]()

    fn add_error(mut self, message: String):
        """Add a validation error."""
        self.errors.append(message)
        self.is_valid = False

    fn add_warning(mut self, message: String):
        """Add a validation warning."""
        self.warnings.append(message)

    fn get_error_summary(self) -> String:
        """Get a summary of all errors."""
        if len(self.errors) == 0:
            return ""

        var summary = String("Validation errors: ")
        for i in range(len(self.errors)):
            if i > 0:
                summary = summary + "; "
            summary = summary + self.errors[i]

        return summary

@value
struct ParameterValidationResult(Movable):
    """Result of single parameter validation."""
    var is_valid: Bool
    var error_message: String

    fn __init__(out self):
        self.is_valid = True
        self.error_message = ""

@value
struct MCPToolContent(Movable):
    """Content item in a tool result."""
    var type: String  # "text", "image", "resource"
    var data: String  # Text content, base64 data, or URI
    var mime_type: String  # MIME type for resources

    fn __init__(out self, type: String, data: String, mime_type: String = ""):
        self.type = type
        self.data = data
        self.mime_type = mime_type

    fn to_json(self) -> String:
        """Convert content to JSON format."""
        var json = String('{')
        json = add_json_key_value(json, "type", escape_json_string(self.type))

        if self.type == "text":
            json = add_json_key_value(json, "text", escape_json_string(self.data))
        elif self.type == "image":
            json = add_json_key_value(json, "data", escape_json_string(self.data))
            if self.mime_type != "":
                json = add_json_key_value(json, "mimeType", escape_json_string(self.mime_type))
        elif self.type == "resource":
            json = add_json_key_value(json, "resource", escape_json_string(self.data))
            if self.mime_type != "":
                json = add_json_key_value(json, "mimeType", escape_json_string(self.mime_type))

        json = json + "}"
        return json

@value
struct MCPToolResult(Movable):
    """Result of a tool execution."""
    var content: List[MCPToolContent]
    var is_error: Bool
    var error_message: String

    fn __init__(out self, is_error: Bool = False, error_message: String = ""):
        self.content = List[MCPToolContent]()
        self.is_error = is_error
        self.error_message = error_message

    fn add_text_content(mut self, text: String):
        """Add text content to the result."""
        var content = MCPToolContent("text", text)
        self.content.append(content)

    fn add_text_content(mut self, number: Int):
        """Add text content to the result."""
        var content = MCPToolContent("text", String(number))
        self.content.append(content)

    fn add_text_content(mut self, number: Float64):
        """Add text content to the result."""
        var content = MCPToolContent("text", String(number))
        self.content.append(content)

    fn add_text_content(mut self, boolean: Bool):
        """Add text content to the result."""
        var content = MCPToolContent("text", String(boolean))
        self.content.append(content)

    fn to_json(self) -> String:
        """Convert result to MCP JSON format."""
        if self.is_error:
            return String('{"isError":true,"content":[{"type":"text","text":"', escape_json_string(self.error_message), '"}]}')

        var json = String('{"content":[')
        for i in range(len(self.content)):
            if i > 0:
                json = json + ","
            json = json + self.content[i].to_json()
        json = json + "]}"
        return json

    @staticmethod
    fn from_json(json_str: String) raises -> MCPToolResult:
        """Parse MCPToolResult from JSON string (simplified parser)."""
        var result = MCPToolResult()

        # Check if this is an error result
        if '"isError":true' in json_str or "'isError':true" in json_str:
            result.is_error = True
            # Extract error message
            var text_start = json_str.find('"text":"')
            if text_start == -1:
                text_start = json_str.find("'text':'")
            if text_start != -1:
                var quote_char = '"' if '"text":"' in json_str else "'"
                var msg_start = json_str.find(quote_char, text_start + 8)
                if msg_start != -1:
                    var msg_end = json_str.find(quote_char, msg_start + 1)
                    if msg_end != -1:
                        result.error_message = json_str[msg_start + 1:msg_end]
        else:
            # Parse content array (simplified - only handles text content)
            var content_start = json_str.find('"content":[')
            if content_start == -1:
                content_start = json_str.find("'content':[")

            if content_start != -1:
                var array_start = json_str.find('[', content_start)
                if array_start != -1:
                    var depth = 0
                    var in_string = False

                    # Simple parse of text content
                    for i in range(array_start, len(json_str)):
                        var ch = json_str[i]
                        if ch == '"' and (i == 0 or json_str[i-1] != '\\'):
                            in_string = not in_string

                        if not in_string:
                            if ch == '[' or ch == '{':
                                depth += 1
                            elif ch == ']' or ch == '}':
                                depth -= 1
                                if depth == 0:
                                    break

                    # Extract text values (very simplified)
                    var text_marker = '"text":"'
                    var pos = json_str.find(text_marker, array_start)
                    while pos != -1 and pos < len(json_str):
                        var text_start = pos + len(text_marker)
                        var text_end = json_str.find('"', text_start)
                        if text_end != -1:
                            var text_value = json_str[text_start:text_end]
                            result.add_text_content(text_value)
                        pos = json_str.find(text_marker, text_end if text_end != -1 else pos + 1)
                        if pos <= text_end:
                            break

        return result

@value
struct MCPToolRequest(Movable):
    """Parsed and validated tool request parameters."""
    var parameters: Dict[String, String]
    var tool_name: String
    var raw_arguments: String

    fn __init__(out self, tool_name: String, raw_arguments: String):
        self.tool_name = tool_name
        self.raw_arguments = raw_arguments
        self.parameters = Dict[String, String]()

    fn get_string(self, name: String, default_value: String = "") -> String:
        """Get a string parameter value."""
        if name in self.parameters:
            try:
                var value = self.parameters[name]
                # Remove quotes if present
                if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
                    return value[1:-1]
                if len(value) >= 2 and value.startswith("'") and value.endswith("'"):
                    return value[1:-1]
                return value
            except:
                return default_value
        return default_value

    fn get_number(self, name: String, default_value: Float64 = 0.0) raises -> Float64:
        """Get a number parameter value."""
        if name in self.parameters:
            try:
                var value = self.parameters[name]
                # Remove quotes if present
                if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                if len(value) >= 2 and value.startswith("'") and value.endswith("'"):
                    value = value[1:-1]
                return atof(value)
            except:
                return default_value
        return default_value

    fn get_int(self, name: String, default_value: Int = 0) raises -> Int:
        """Get an integer parameter value."""
        if name in self.parameters:
            try:
                var value = self.parameters[name]
                # Remove quotes if present
                if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                if len(value) >= 2 and value.startswith("'") and value.endswith("'"):
                    value = value[1:-1]
                return atol(value)
            except:
                return default_value
        return default_value

    fn get_bool(self, name: String, default_value: Bool = False) -> Bool:
        """Get a boolean parameter value."""
        if name in self.parameters:
            try:
                var value = self.parameters[name]
                # Remove quotes if present
                if len(value) >= 2 and value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                if len(value) >= 2 and value.startswith("'") and value.endswith("'"):
                    value = value[1:-1]
                return value.lower() == "true"
            except:
                return default_value
        return default_value

    fn has_parameter(self, name: String) -> Bool:
        """Check if a parameter exists."""
        return name in self.parameters

    fn get_parameter_names(self) -> List[String]:
        """Get all parameter names."""
        var names = List[String]()
        for name in self.parameters:
            names.append(name)
        return names

# Tool execution function type
alias ToolExecutionFunc = fn(MCPToolRequest) raises -> MCPToolResult

@value
struct ToolExecutionInfo(Movable):
    """Information about a tool execution in progress."""
    var tool_name: String
    var start_time_ms: Int
    var timeout_ms: Int

    fn __init__(out self, tool_name: String, timeout_ms: Int):
        self.tool_name = tool_name
        self.start_time_ms = current_time_ms()
        self.timeout_ms = timeout_ms

    fn is_expired(self) -> Bool:
        """Check if this execution has exceeded its timeout."""
        var elapsed = current_time_ms() - self.start_time_ms
        return elapsed >= self.timeout_ms

    fn elapsed_time_ms(self) -> Int:
        """Get the elapsed execution time in milliseconds."""
        return current_time_ms() - self.start_time_ms

@value
struct MCPToolRegistry(Movable):
    """Registry for managing MCP tools."""
    var tools: Dict[String, MCPTool]
    var tool_executors: Dict[String, ToolExecutionFunc]
    var enabled: Bool
    var max_execution_time_ms: Int  # Maximum execution time in milliseconds
    var max_concurrent_executions: Int  # Maximum concurrent tool executions
    var current_executions: Int  # Current number of running executions
    var safety_checks_enabled: Bool
    var active_executions: Dict[String, ToolExecutionInfo]  # Track active tool executions
    var next_execution_id: Int  # Counter for generating execution IDs
    var use_fork_timeout: Bool  # Enable fork-based timeout enforcement (true cancellation)

    fn __init__(out self):
        self.tools = Dict[String, MCPTool]()
        self.tool_executors = Dict[String, ToolExecutionFunc]()
        self.enabled = True
        self.max_execution_time_ms = 30000  # 30 seconds default
        self.max_concurrent_executions = 10  # Maximum 10 concurrent executions
        self.current_executions = 0
        self.safety_checks_enabled = True
        self.active_executions = Dict[String, ToolExecutionInfo]()
        self.next_execution_id = 0
        self.use_fork_timeout = False  # Default to off for safety and compatibility

    fn register_tool(mut self, tool: MCPTool, executor: ToolExecutionFunc) raises:
        """Register a new tool with its executor function."""
        if tool.name in self.tools:
            raise Error("Tool already registered: " + tool.name)

        self.tools[tool.name] = tool
        self.tool_executors[tool.name] = executor

    fn list_tools(self) -> List[MCPTool]:
        """Get list of all registered tools."""
        var tool_list = List[MCPTool]()
        for tool_name in self.tools:
            try:
                var tool = self.tools[tool_name]
                if tool.enabled:
                    tool_list.append(tool)
            except:
                continue
        return tool_list

    fn execute_tool(mut self, tool_name: String, arguments_json: String) raises -> MCPToolResult:
        """Execute a tool with the provided arguments and safety checks."""
        if not self.enabled:
            var error_result = MCPToolResult(True, "Tool execution is disabled")
            return error_result

        if tool_name not in self.tools:
            var error_result = MCPToolResult(True, "Tool not found: " + tool_name)
            return error_result

        var tool = self.tools[tool_name]
        if not tool.enabled:
            var error_result = MCPToolResult(True, "Tool is disabled: " + tool_name)
            return error_result

        # Safety checks
        if self.safety_checks_enabled:
            if self.current_executions >= self.max_concurrent_executions:
                var error_result = MCPToolResult(True, "Maximum concurrent executions exceeded")
                return error_result

        # Check for expired executions before starting a new one
        try:
            self._cleanup_expired_executions()
        except:
            pass  # Continue even if cleanup fails

        # Validate arguments
        try:
            var validation = tool.validate_arguments(arguments_json)
            if not validation.is_valid:
                var error_result = MCPToolResult(True, validation.get_error_summary())
                return error_result
        except e:
            var error_result = MCPToolResult(True, "Argument validation failed")
            return error_result

        # Parse arguments into MCPToolRequest
        var request = MCPToolRequest(tool_name, arguments_json)
        try:
            var parsed_args = tool._parse_json_arguments(arguments_json)
            for param_name in parsed_args:
                request.parameters[param_name] = parsed_args[param_name]
        except e:
            var error_result = MCPToolResult(True, "Failed to parse arguments")
            return error_result

        # Generate execution ID and track the execution
        var execution_id = self._generate_execution_id()
        var exec_info = ToolExecutionInfo(tool_name, self.max_execution_time_ms)
        self.active_executions[execution_id] = exec_info

        # Execute the tool with safety monitoring
        self.current_executions += 1
        try:
            var executor = self.tool_executors[tool_name]

            # Use fork-based timeout if enabled, otherwise use standard execution
            var result: MCPToolResult
            if self.use_fork_timeout:
                result = self._execute_with_timeout_fork(executor, request, execution_id)
            else:
                result = self._execute_with_timeout_request(executor, request, execution_id)

            self.current_executions -= 1
            # Remove from active executions on success
            _ = self.active_executions.pop(execution_id, ToolExecutionInfo(tool_name, 0))
            return result
        except e:
            self.current_executions -= 1
            # Remove from active executions on error
            _ = self.active_executions.pop(execution_id, ToolExecutionInfo(tool_name, 0))
            var error_result = MCPToolResult(True, "Tool execution failed: " + String(e))
            return error_result

    fn _generate_execution_id(mut self) -> String:
        """Generate a unique execution ID."""
        var id = String("exec_") + String(self.next_execution_id)
        self.next_execution_id += 1
        return id

    fn _cleanup_expired_executions(mut self) raises:
        """Clean up expired tool executions and log warnings."""
        var expired_ids = List[String]()

        # Collect expired execution IDs
        for exec_id in self.active_executions:
            var exec_info = self.active_executions[exec_id]
            if exec_info.is_expired():
                expired_ids.append(exec_id)
                print("[WARNING] Tool execution timeout: ", exec_info.tool_name,
                      " exceeded ", exec_info.timeout_ms, "ms (elapsed: ",
                      exec_info.elapsed_time_ms(), "ms)")

        # Remove expired executions
        for i in range(len(expired_ids)):
            _ = self.active_executions.pop(expired_ids[i], ToolExecutionInfo("", 0))

    fn _execute_with_timeout_request(mut self, executor: ToolExecutionFunc, request: MCPToolRequest, execution_id: String) raises -> MCPToolResult:
        """Execute a tool function with timeout monitoring using MCPToolRequest.

        This implementation uses polling to check execution time:
        - The tool executes directly in the current process
        - Periodically checks if execution has exceeded timeout
        - Cannot truly cancel mid-execution (would require async/fork)
        """
        # Check if already expired before starting (shouldn't happen, but safety check)
        if execution_id in self.active_executions:
            var exec_info = self.active_executions[execution_id]
            if exec_info.is_expired():
                raise Error("Tool execution timeout before start: " + exec_info.tool_name)

        # Execute the tool
        var result = executor(request)

        # Check if execution exceeded timeout
        if execution_id in self.active_executions:
            var exec_info = self.active_executions[execution_id]
            if exec_info.is_expired():
                var elapsed = exec_info.elapsed_time_ms()
                print("[WARNING] Tool '", exec_info.tool_name, "' completed but exceeded timeout: ",
                      elapsed, "ms (max: ", exec_info.timeout_ms, "ms)")
                # Still return the result, but log the timeout warning
                # For true cancellation, use fork-based execution in server.mojo

        return result

    fn _execute_with_timeout_fork(mut self, executor: ToolExecutionFunc, request: MCPToolRequest, execution_id: String) raises -> MCPToolResult:
        """Execute a tool function with fork-based timeout enforcement.

        This implementation uses fork() to run the tool in a child process that can be killed on timeout:
        - Forks a child process to execute the tool
        - Parent monitors timeout and kills child if exceeded
        - Uses temporary file for IPC between parent and child
        - Provides true mid-execution cancellation capability
        """
        if execution_id not in self.active_executions:
            raise Error("Execution ID not found: " + execution_id)

        var exec_info = self.active_executions[execution_id]
        var timeout_ms = exec_info.timeout_ms

        # Create temporary file path for result IPC
        var temp_file = String("/tmp/mcp_tool_result_") + execution_id + ".json"

        # Fork child process
        var pid: pid_t
        try:
            pid = fork()
        except e:
            print("[FORK] Fork failed, falling back to non-fork execution:", String(e))
            # Fallback to regular execution on fork failure
            return self._execute_with_timeout_request(executor, request, execution_id)

        if pid == 0:
            # Child process: execute tool and write result to file
            try:
                var result = executor(request)
                var result_json = result.to_json()

                # Write result to temporary file
                try:
                    with open(temp_file, "w") as f:
                        f.write(result_json)
                except write_error:
                    print("[CHILD] Failed to write result to file:", String(write_error))

                # Exit child process successfully
                exit(0)
            except tool_error:
                # Tool execution failed - write error result
                try:
                    var error_result = MCPToolResult(True, String(tool_error))
                    var error_json = error_result.to_json()
                    with open(temp_file, "w") as f:
                        f.write(error_json)
                except:
                    pass

                # Exit with error status
                exit(1)
        else:
            # Parent process: monitor timeout and wait for child
            var start_time = current_time_ms()
            var child_completed = False
            var status_ptr = UnsafePointer[c_int].alloc(1)
            status_ptr[] = 0

            # Monitoring loop
            while True:
                # Check if child has completed (non-blocking)
                var wait_result = waitpid(pid, status_ptr, WNOHANG)

                if wait_result == pid:
                    # Child completed
                    child_completed = True
                    break
                elif wait_result == -1:
                    # Error in waitpid
                    print("[PARENT] waitpid error for PID:", pid)
                    break

                # Check timeout
                var elapsed = current_time_ms() - start_time
                if elapsed >= timeout_ms:
                    # Timeout - kill child process
                    print("[TIMEOUT] Tool '", exec_info.tool_name, "' exceeded timeout (", timeout_ms, "ms), killing PID:", pid)
                    try:
                        _ = kill(pid, SIGKILL)
                        # Wait for child to be reaped
                        _ = waitpid(pid, status_ptr, 0)
                    except kill_error:
                        print("[PARENT] Failed to kill child process:", String(kill_error))

                    status_ptr.free()

                    # Return timeout error
                    var timeout_error = MCPToolResult(True, String("Tool execution timed out after ", timeout_ms, "ms"))
                    # Clean up temp file if it exists
                    try:
                        os.remove(temp_file)
                    except:
                        pass
                    return timeout_error

                # Sleep briefly before next check (100ms)
                sleep(0.1)

            status_ptr.free()

            # Child completed - read result from file
            if child_completed:
                try:
                    var result_json: String
                    with open(temp_file, "r") as f:
                        result_json = f.read()

                    # Parse result from JSON
                    var result = MCPToolResult.from_json(result_json)

                    # Clean up temporary file
                    try:
                        os.remove(temp_file)
                    except:
                        pass

                    return result
                except read_error:
                    print("[PARENT] Failed to read result file:", String(read_error))
                    # Clean up temp file
                    try:
                        os.remove(temp_file)
                    except:
                        pass
                    # Return error instead of raising
                    return MCPToolResult(True, "Failed to read tool execution result: " + String(read_error))
            else:
                # Child did not complete successfully - this should not happen if waitpid logic is correct
                var error_result = MCPToolResult(True, "Tool execution failed in child process")
                # Clean up temp file if it exists
                try:
                    os.remove(temp_file)
                except:
                    pass
                return error_result

        # This line should never be reached due to fork logic above, but needed for compiler
        return MCPToolResult(True, "Unreachable code path in fork execution")

# JSON utility functions
fn escape_json_string(value: String) -> String:
    """Escape special characters in a string for JSON format."""
    var escaped = String()
    for i in range(len(value)):
        var char = String(value[i])
        if char == '"':
            escaped = escaped + '\\"'
        elif char == '\\':
            escaped = escaped + '\\\\'
        elif char == '\n':
            escaped = escaped + '\\n'
        elif char == '\r':
            escaped = escaped + '\\r'
        elif char == '\t':
            escaped = escaped + '\\t'
        elif ord(char) < 32:
            # Control characters - convert to unicode escape
            var char_code = ord(char)
            escaped = escaped + '\\u'
            var hex_str = String(hex(char_code))
            # Remove '0x' prefix if present and pad to 4 digits
            if hex_str.startswith("0x"):
                hex_str = hex_str[2:]
            # Zero-pad to 4 digits
            while len(hex_str) < 4:
                hex_str = "0" + hex_str
            escaped = escaped + hex_str
        else:
            escaped = escaped + char
    return escaped

# Utility functions for creating common tool parameter types

fn create_string_parameter(name: String, description: String, required: Bool = True,
                          default_value: String = "") -> MCPToolParameter:
    """Create a string parameter."""
    return MCPToolParameter(name, TOOL_TYPE_STRING, description, required, default_value)

fn create_number_parameter(name: String, description: String, required: Bool = True,
                          default_value: String = "") -> MCPToolParameter:
    """Create a number parameter."""
    return MCPToolParameter(name, TOOL_TYPE_NUMBER, description, required, default_value)

fn create_boolean_parameter(name: String, description: String, required: Bool = True,
                           default_value: String = "false") -> MCPToolParameter:
    """Create a boolean parameter."""
    return MCPToolParameter(name, TOOL_TYPE_BOOLEAN, description, required, default_value)

fn create_enum_parameter(name: String, description: String, enum_values: List[String],
                        required: Bool = True, default_value: String = "") -> MCPToolParameter:
    """Create an enum parameter."""
    return MCPToolParameter(name, TOOL_TYPE_STRING, description, required, default_value, enum_values)
