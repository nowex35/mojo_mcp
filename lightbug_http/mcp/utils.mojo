from random import random_si64
from python import Python
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