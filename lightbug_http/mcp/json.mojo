fn add_json_key_value(json: String, key: String, value: String) -> String:
    """Add a key-value pair to a JSON object string."""
    # Check if this is the first key (json ends with {)
    if json.endswith("{"):
        return String(json, '"', key, '":"', value, '"')
    else:
        return String(json, ',"', key, '":"', value, '"')