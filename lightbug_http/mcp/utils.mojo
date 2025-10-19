from random import random_si64
from python import Python, PythonObject
from lightbug_http._libc import wait4, WNOHANG
from lightbug_http._logger import logger

fn generate_uuid() -> String:
    """
    Generate a UUID v4 string compliant with RFC 4122.
    Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    where y is one of 8, 9, A, or B.

    Returns a 36-character UUID string.
    """
    var hex_chars = "0123456789abcdef"
    var uuid_chars: List[String] = []

    for i in range(36):
        # 1. ハイフンの位置を処理
        if i == 8 or i == 13 or i == 18 or i == 23:
            uuid_chars.append("-")
            continue

        # 2. UUID v4のバージョン (4) を設定
        if i == 14:
            uuid_chars.append("4")
            continue

        # 3. UUID v4のバリアント (8, 9, a, or b) を設定
        if i == 19:
            # 8, 9, 10, 11 (0b1000, 0b1001, 0b1010, 0b1011) からランダムに選択
            var digit = 8 + random_si64(0, 3)
            uuid_chars.append(hex_chars[digit])
            continue

        # 4. その他の文字はランダムに生成
        var digit = random_si64(0, 15)
        uuid_chars.append(hex_chars[digit])

    # パフォーマンス向上のため、最後に一度だけ文字列を結合
    return String("").join(uuid_chars)

fn current_time_ms() -> Int:
    """Get current time in milliseconds using Python."""
    try:
        var time = Python.import_module("time")
        # nsを取得してミリ秒に変換
        var current_time = time.time()
        return Int(current_time * 1000)
    except:
        # Fallback to a simple counter if Python fails
        return 1000000

fn hex(value: Int) -> String:
    """Convert an integer to hexadecimal string.

    Args:
        value: The integer value to convert.

    Returns:
        Hexadecimal string representation.
    """
    if value == 0:
        return "0"

    var result = String("")
    var num = value
    var hex_chars = "0123456789abcdef"

    while num > 0:
        var digit = num % 16
        result = hex_chars[digit] + result
        num = num // 16

    return result

fn delete_zombies() -> None:
    while True:
        try:
            # Wait for any child process (-1) with WNOHANG (non-blocking)
            # Returns:
            #   > 0: PID of reaped child process
            #   = 0: No terminated child processes available
            #   < 0: Error (handled by wait4 function)
            var pid = wait4(-1, WNOHANG)

            if pid == 0:
                # No more terminated child processes
                break
            elif pid > 0:
                logger.debug("Reaped zombie child process with PID:", String(pid))
            else:
                # Unexpected negative value (should not happen with our wait4 implementation)
                break
        except e:
            # ECHILD error (no child processes) is normal and expected
            if "ECHILD" in String(e) or "No child processes" in String(e):
                break
            else:
                logger.error("delete_zombies error:", String(e))
                break

fn add_json_key_value(json: String, key: String, value: String) -> String:
    """Add a key-value pair to a JSON object string."""
    # Check if this is the first key (json ends with {)
    if json.endswith("{"):
        return String(json, '"', key, '":"', value, '"')
    else:
        return String(json, ',"', key, '":"', value, '"')


# ========== JSON Processing Utilities ==========

fn escape_json_string(s: String) -> String:
    """Escape a string for JSON.

    Args:
        s: String to escape.

    Returns:
        Escaped string safe for JSON.
    """
    var result = s
    result = result.replace("\\", "\\\\")
    result = result.replace('"', '\\"')
    result = result.replace("\n", "\\n")
    result = result.replace("\r", "\\r")
    result = result.replace("\t", "\\t")
    return result


@value
struct JSONBuilder:
    """Type-safe JSON object builder.

    Example:
        var builder = JSONBuilder()
        builder.add_string("name", "value")
        builder.add_int("count", 42)
        builder.add_bool("active", True)
        var json = builder.build()
    """
    var _fields: List[String]

    fn __init__(out self):
        self._fields = List[String]()

    fn add_string(mut self, key: String, value: String):
        """Add a string field.

        Args:
            key: Field name.
            value: String value.
        """
        var escaped = escape_json_string(value)
        self._fields.append('"' + key + '":"' + escaped + '"')

    fn add_int(mut self, key: String, value: Int):
        """Add an integer field.

        Args:
            key: Field name.
            value: Integer value.
        """
        self._fields.append('"' + key + '":' + String(value))

    fn add_bool(mut self, key: String, value: Bool):
        """Add a boolean field.

        Args:
            key: Field name.
            value: Boolean value.
        """
        var bool_str = "true" if value else "false"
        self._fields.append('"' + key + '":' + bool_str)

    fn add_raw(mut self, key: String, json_value: String):
        """Add a raw JSON value (object, array, etc.).

        Args:
            key: Field name.
            json_value: Raw JSON string.
        """
        self._fields.append('"' + key + '":' + json_value)

    fn add_optional_string(mut self, key: String, value: String):
        """Add a string field only if not empty.

        Args:
            key: Field name.
            value: String value.
        """
        if len(value) > 0:
            self.add_string(key, value)

    fn add_optional_raw(mut self, key: String, json_value: String):
        """Add a raw JSON value only if not empty.

        Args:
            key: Field name.
            json_value: Raw JSON string.
        """
        if len(json_value) > 0:
            self.add_raw(key, json_value)

    fn build(self) -> String:
        """Build the final JSON string.

        Returns:
            JSON object string.
        """
        if len(self._fields) == 0:
            return "{}"
        return "{" + String(",").join(self._fields) + "}"


@value
struct JSONArrayBuilder:
    """Type-safe JSON array builder.

    Example:
        var builder = JSONArrayBuilder()
        builder.add_string("item1")
        builder.add_int(42)
        builder.add_raw('{"nested":"object"}')
        var json = builder.build()
    """
    var _items: List[String]

    fn __init__(out self):
        self._items = List[String]()

    fn add_string(mut self, value: String):
        """Add a string item.

        Args:
            value: String value.
        """
        var escaped = escape_json_string(value)
        self._items.append('"' + escaped + '"')

    fn add_int(mut self, value: Int):
        """Add an integer item.

        Args:
            value: Integer value.
        """
        self._items.append(String(value))

    fn add_bool(mut self, value: Bool):
        """Add a boolean item.

        Args:
            value: Boolean value.
        """
        var bool_str = "true" if value else "false"
        self._items.append(bool_str)

    fn add_raw(mut self, json_value: String):
        """Add a raw JSON value.

        Args:
            json_value: Raw JSON string.
        """
        self._items.append(json_value)

    fn build(self) -> String:
        """Build the final JSON array string.

        Returns:
            JSON array string.
        """
        if len(self._items) == 0:
            return "[]"
        return "[" + String(",").join(self._items) + "]"


@value
struct JSONParser:
    """Python-based JSON parser wrapper with type-safe accessors.

    Example:
        var parser = JSONParser()
        var data = parser.parse('{"name":"value"}')
        var name = parser.get_string(data, "name", "default")
    """
    var _json_module: PythonObject

    fn __init__(out self) raises:
        """Initialize the JSON parser."""
        self._json_module = Python.import_module("json")

    fn parse(self, json_str: String) raises -> PythonObject:
        """Parse a JSON string.

        Args:
            json_str: JSON string to parse.

        Returns:
            Parsed Python object.

        Raises:
            Error if parsing fails.
        """
        return self._json_module.loads(json_str)

    fn get_string(self, obj: PythonObject, key: String, default: String = "") -> String:
        """Safely get a string value.

        Args:
            obj: Python object to query.
            key: Key name.
            default: Default value if key not found.

        Returns:
            String value or default.
        """
        try:
            if key in obj:
                return String(obj[key])
            return default
        except:
            return default

    fn get_int(self, obj: PythonObject, key: String, default: Int = 0) -> Int:
        """Safely get an integer value.

        Args:
            obj: Python object to query.
            key: Key name.
            default: Default value if key not found.

        Returns:
            Integer value or default.
        """
        try:
            if key in obj:
                return Int(obj[key])
            return default
        except:
            return default

    fn get_bool(self, obj: PythonObject, key: String, default: Bool = False) -> Bool:
        """Safely get a boolean value.

        Args:
            obj: Python object to query.
            key: Key name.
            default: Default value if key not found.

        Returns:
            Boolean value or default.
        """
        try:
            if key in obj:
                var value = obj[key]
                # Python True/False
                if value is True:
                    return True
                elif value is False:
                    return False
                # String "true"/"false"
                var str_val = String(value).lower()
                return str_val == "true"
            return default
        except:
            return default

    fn has_key(self, obj: PythonObject, key: String) -> Bool:
        """Check if a key exists.

        Args:
            obj: Python object to query.
            key: Key name.

        Returns:
            True if key exists, False otherwise.
        """
        try:
            return key in obj
        except:
            return False

    fn get_object(self, obj: PythonObject, key: String) raises -> PythonObject:
        """Get a nested object.

        Args:
            obj: Python object to query.
            key: Key name.

        Returns:
            Nested Python object.

        Raises:
            Error if key not found.
        """
        if key not in obj:
            raise Error("Key not found: " + key)
        return obj[key]

    fn to_json_string(self, obj: PythonObject) -> String:
        """Convert a Python object to JSON string.

        Args:
            obj: Python object to serialize.

        Returns:
            JSON string representation.
        """
        try:
            return String(self._json_module.dumps(obj))
        except:
            return "{}"


# ========== Simple JSON Parsing Helpers ==========

fn parse_json_string(json_str: String, key: String, default: String = "") -> String:
    """Parse a string value from JSON.

    Args:
        json_str: JSON string to parse.
        key: Key name to extract.
        default: Default value if key not found or parsing fails.

    Returns:
        The string value or default.
    """
    try:
        var parser = JSONParser()
        var obj = parser.parse(json_str)
        return parser.get_string(obj, key, default)
    except:
        return default


fn parse_json_int(json_str: String, key: String, default: Int = 0) -> Int:
    """Parse an integer value from JSON.

    Args:
        json_str: JSON string to parse.
        key: Key name to extract.
        default: Default value if key not found or parsing fails.

    Returns:
        The integer value or default.
    """
    try:
        var parser = JSONParser()
        var obj = parser.parse(json_str)
        return parser.get_int(obj, key, default)
    except:
        return default


fn parse_json_object_string(json_str: String, parent_key: String, child_key: String, default: String = "") -> String:
    """Parse a nested string value from JSON.

    Args:
        json_str: JSON string to parse.
        parent_key: Parent object key name.
        child_key: Child key name within parent object.
        default: Default value if not found or parsing fails.

    Returns:
        The nested string value or default.

    """
    try:
        var parser = JSONParser()
        var obj = parser.parse(json_str)
        var parent = parser.get_object(obj, parent_key)
        return parser.get_string(parent, child_key, default)
    except:
        return default


fn parse_json_to_dict(json_str: String) raises -> Dict[String, String]:
    """Parse JSON object into a simple key-value dictionary.

    Args:
        json_str: JSON string to parse (must be an object).

    Returns:
        Dictionary with string keys and values.

    Raises:
        Error if parsing fails.

    """
    var result = Dict[String, String]()

    try:
        var parser = JSONParser()
        var obj = parser.parse(json_str)

        # Python dict iteration
        var items = obj.items()
        for item in items:
            var key = String(item[0])
            var value = String(item[1])
            result[key] = value
    except e:
        raise Error("Failed to parse JSON to dict: " + String(e))

    return result


fn parse_json_object(json_str: String, key: String) raises -> String:
    """Extract a nested JSON object as a string.

    Args:
        json_str: JSON string to parse.
        key: Key name of the nested object.

    Returns:
        The nested object as a JSON string.

    Raises:
        Error if parsing fails or key not found.
    """
    try:
        var parser = JSONParser()
        var obj = parser.parse(json_str)
        var nested = parser.get_object(obj, key)
        return parser.to_json_string(nested)
    except e:
        raise Error("Failed to extract JSON object '" + key + "': " + String(e))