# MCP Server Tests

This directory contains tests for the MCP server implemented in `working_mcp_server.mojo`.

## Prerequisites

1. Python 3.7 or higher
2. Pixi (for running Mojo)
3. The MCP server must be running before executing tests

## Setup

Create a virtual environment and install the test dependencies:

```bash
# Create virtual environment
python3 -m venv test/venv

# Install dependencies
test/venv/bin/pip install -r test/requirements.txt
```

Or if you prefer using `pip` directly in an activated virtual environment:

```bash
# Create and activate virtual environment
python3 -m venv test/venv
source test/venv/bin/activate  # On Linux/Mac
# test\venv\Scripts\activate  # On Windows

# Install dependencies
pip install -r test/requirements.txt
```

## Running the Tests

### 1. Start the MCP Server

First, start the MCP server in a separate terminal:

```bash
pixi run mojo working_mcp_server.mojo
```

The server will start on `http://127.0.0.1:8082` and display:
```
🔥🐝 Lightbug is listening on http://127.0.0.1:8082
Ready to accept connections...
```

### 2. Run the Tests

In another terminal, run the tests using the virtual environment:

```bash
# Run all tests with verbose output
test/venv/bin/pytest test/test_mcp_server.py -v

# Run a specific test class
test/venv/bin/pytest test/test_mcp_server.py::TestEchoTool -v

# Run a specific test
test/venv/bin/pytest test/test_mcp_server.py::TestMathAddTool::test_add_positive_numbers -v

# Run tests with detailed output
test/venv/bin/pytest test/test_mcp_server.py -vv

# Run tests and show print statements
test/venv/bin/pytest test/test_mcp_server.py -v -s
```

Or if you activated the virtual environment:

```bash
# Activate virtual environment first
source test/venv/bin/activate  # On Linux/Mac
# test\venv\Scripts\activate  # On Windows

# Then run pytest normally
pytest test/test_mcp_server.py -v
```

Alternatively, you can run the test file directly:

```bash
test/venv/bin/python test/test_mcp_server.py
```

## Test Coverage

The test suite includes:

### Connectivity Tests (`TestMCPServerConnectivity`)
- Server availability check
- MCP session initialization
- Tool listing functionality

### Echo Tool Tests (`TestEchoTool`)
- Echo with custom message
- Echo with default message (no parameters)

### Math Add Tool Tests (`TestMathAddTool`)
- Addition of positive numbers
- Addition of negative numbers
- Addition with zero
- Handling of missing parameters

### Slow Operation Tool Tests (`TestSlowOperationTool`)
- Short delay operation (1 second)
- Medium delay operation (2 seconds)

### Error Handling Tests (`TestErrorHandling`)
- Invalid tool name
- Malformed JSON-RPC requests

## Test Structure

The tests use:
- `pytest` as the testing framework
- `requests` library for HTTP communication
- Custom `MCPClient` class that implements JSON-RPC 2.0 protocol

## Troubleshooting

### Server Not Running Error

If you see an error about the server not running:
```
SKIPPED [1] test/test_mcp_server.py: MCP server is not running on 127.0.0.1:8082
```

Make sure the MCP server is started before running tests:
```bash
pixi run mojo working_mcp_server.mojo
```

### Connection Timeout

If tests timeout, ensure:
1. The server is running on the correct port (8082)
2. No firewall is blocking local connections
3. The server has fully started before running tests

### Test Failures

If specific tool tests fail, check:
1. The server logs for errors
2. That the tool implementation matches the expected behavior
3. The JSON-RPC request/response format is correct

### Python Module Not Found

If you see errors about missing modules (`pytest` or `requests` not found):

```
ModuleNotFoundError: No module named 'pytest'
```

Make sure you:
1. Created the virtual environment: `python3 -m venv test/venv`
2. Installed dependencies: `test/venv/bin/pip install -r test/requirements.txt`
3. Are using the correct pytest: `test/venv/bin/pytest` (not just `pytest`)

### Externally Managed Environment Error

If you see this error when trying to install with `pip`:

```
error: externally-managed-environment
```

This means you need to use a virtual environment. Follow the Setup instructions above to create and use a virtual environment.

## Adding New Tests

To add tests for new tools:

1. Create a new test class following the naming pattern `Test<ToolName>Tool`
2. Add test methods with descriptive names starting with `test_`
3. Use the `mcp_client` fixture to interact with the server
4. Assert expected behavior and response format

Example:
```python
class TestNewTool:
    """Test the new_tool functionality."""

    def test_new_tool_basic(self, mcp_client):
        """Test basic new_tool functionality."""
        response = mcp_client.call_tool("new_tool", {"param": "value"})

        assert "result" in response, "Tool call should succeed"
        # Add more assertions
```
