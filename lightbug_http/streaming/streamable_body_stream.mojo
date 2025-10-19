from memory import Span
from lightbug_http.io.bytes import Bytes, ByteWriter, bytes
from lightbug_http.connection import TCPConnection
from lightbug_http.mcp.utils import hex


alias default_stream_buffer_size = 4096
"""デフォルトのストリーミングバッファサイズ (4KB)"""


struct StreamableBodyStream:
    """HTTPボディのストリーミング処理を行うストリーム

    チャンク転送エンコーディングとServer-Sent Events (SSE) をサポートします。
    """

    var connection: TCPConnection
    var buffer_size: Int
    var _internal_buffer: Bytes
    var _position: Int
    var _content_length: Int
    var _bytes_read: Int
    var _is_chunked: Bool
    var _is_complete: Bool
    var _headers_sent: Bool

    fn __init__(
        out self,
        owned connection: TCPConnection,
        buffer_size: Int = default_stream_buffer_size,
        content_length: Int = -1,
        is_chunked: Bool = False
    ):
        """StreamableBodyStreamを初期化

        Args:
            connection: TCP接続
            buffer_size: 内部バッファサイズ (デフォルト: 4KB)
            content_length: Content-Lengthが既知の場合は指定、-1は未知
            is_chunked: Transfer-Encoding: chunkedを使用するかどうか
        """
        self.connection = connection^
        self.buffer_size = buffer_size
        self._internal_buffer = Bytes(capacity=buffer_size)
        self._position = 0
        self._content_length = content_length
        self._bytes_read = 0
        self._is_chunked = is_chunked
        self._is_complete = False
        self._headers_sent = False

    fn __moveinit__(out self, owned existing: Self):
        """ムーブコンストラクタ"""
        self.connection = existing.connection^
        self.buffer_size = existing.buffer_size
        self._internal_buffer = existing._internal_buffer^
        self._position = existing._position
        self._content_length = existing._content_length
        self._bytes_read = existing._bytes_read
        self._is_chunked = existing._is_chunked
        self._is_complete = existing._is_complete
        self._headers_sent = existing._headers_sent

    fn read_chunk(mut self) raises -> Bytes:
        """次のチャンクを読み込む

        Returns:
            読み込まれたデータ。ストリーム終了時は空のBytes

        Raises:
            Error: 読み込みエラー
        """
        if self._is_complete:
            return Bytes()

        # Content-Lengthが既知の場合
        if self._content_length >= 0:
            var remaining = self._content_length - self._bytes_read
            if remaining <= 0:
                self._is_complete = True
                return Bytes()

            var to_read = min(remaining, self.buffer_size)
            var buffer = Bytes(capacity=to_read)
            var bytes_read = self.connection.read(buffer)

            if bytes_read == 0:
                self._is_complete = True
                return Bytes()

            self._bytes_read += bytes_read
            if self._bytes_read >= self._content_length:
                self._is_complete = True

            return buffer^

        # Content-Length未知の場合、バッファサイズ分読み込む
        var buffer = Bytes(capacity=self.buffer_size)
        var bytes_read: Int
        try:
            bytes_read = self.connection.read(buffer)
        except e:
            if String(e) == "EOF":
                self._is_complete = True
                return Bytes()
            raise e

        if bytes_read == 0:
            self._is_complete = True
            return Bytes()

        self._bytes_read += bytes_read
        return buffer^

    fn write_chunk(mut self, data: Bytes) raises -> Int:
        """データをチャンク形式で書き込む

        Transfer-Encoding: chunked 形式でデータを送信します。

        Args:
            data: 送信するデータ

        Returns:
            送信されたバイト数

        Raises:
            Error: 書き込みエラー
        """
        if not self._is_chunked:
            # 通常の書き込み
            return self.connection.write(Span(data))

        # チャンク形式での書き込み
        # フォーマット: {chunk_size in hex}\r\n{data}\r\n
        var chunk_data = self._format_chunk(data)
        return self.connection.write(Span(chunk_data))

    fn write_sse_event(mut self, event_type: String, data: String, id: String = "") raises:
        """Server-Sent Events (SSE) 形式でイベントを送信

        Args:
            event_type: イベントタイプ
            data: イベントデータ
            id: オプションのイベントID

        Raises:
            Error: 書き込みエラー
        """
        var event_data = self._format_sse_event(event_type, data, id)
        _ = self.connection.write(Span(bytes(event_data)))

    fn is_complete(self) -> Bool:
        """ストリームが完了したかどうか

        Returns:
            完了している場合True
        """
        return self._is_complete

    fn flush(mut self) raises:
        """バッファを強制的にフラッシュ

        内部バッファに残っているデータを送信します。

        Raises:
            Error: フラッシュエラー
        """
        if len(self._internal_buffer) > 0:
            _ = self.connection.write(Span(self._internal_buffer))
            self._internal_buffer = Bytes(capacity=self.buffer_size)

    fn end_stream(mut self) raises:
        """ストリームを終了

        チャンク形式の場合は終了チャンク(0\r\n\r\n)を送信します。

        Raises:
            Error: 書き込みエラー
        """
        if self._is_chunked and not self._is_complete:
            var end_chunk = bytes("0\r\n\r\n")
            _ = self.connection.write(Span(end_chunk))

        self._is_complete = True

    fn _format_chunk(self, data: Bytes) -> Bytes:
        """データをチャンク形式にフォーマット

        Args:
            data: フォーマットするデータ

        Returns:
            チャンク形式のデータ
        """
        var writer = ByteWriter()

        # チャンクサイズを16進数で書き込み
        var chunk_size = len(data)
        writer.write(hex(chunk_size), "\r\n")

        # データを書き込み
        writer.write_bytes(Span(data))

        # CRLFを追加
        writer.write("\r\n")

        return writer^.consume()

    fn _format_sse_event(self, event_type: String, data: String, id: String) -> String:
        """Server-Sent Events形式にフォーマット

        Args:
            event_type: イベントタイプ
            data: イベントデータ
            id: オプションのイベントID

        Returns:
            SSE形式の文字列
        """
        var result = String()

        # イベントタイプ
        if event_type:
            result = result + "event: " + event_type + "\n"

        # ID (オプション)
        if id:
            result = result + "id: " + id + "\n"

        # データ (複数行対応)
        var lines = data.split("\n")
        for i in range(len(lines)):
            result = result + "data: " + lines[i] + "\n"

        # 空行で終了
        result = result + "\n"

        return result
