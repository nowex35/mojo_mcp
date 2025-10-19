from memory import Span
from lightbug_http.io.bytes import Bytes, bytes, ByteWriter
from lightbug_http.header import Headers, HeaderKey
from lightbug_http.cookie import ResponseCookieJar
from lightbug_http.connection import TCPConnection
from lightbug_http.streaming.streamable_body_stream import StreamableBodyStream
from lightbug_http.strings import strHttp11, lineBreak
from lightbug_http.external.small_time.small_time import now


struct StreamableHTTPResponse:
    """HTTP Response with streaming body support.

    This implementation allows writing response data in chunks, supporting
    both Transfer-Encoding: chunked and Server-Sent Events (SSE).
    """

    var headers: Headers
    var cookies: ResponseCookieJar
    var status_code: Int
    var status_text: String
    var protocol: String
    var body_stream: StreamableBodyStream
    var _headers_sent: Bool

    fn __init__(
        out self,
        owned connection: TCPConnection,
        status_code: Int = 200,
        status_text: String = "OK",
        headers: Headers = Headers(),
        cookies: ResponseCookieJar = ResponseCookieJar(),
        protocol: String = strHttp11,
        use_chunked_encoding: Bool = True
    ):
        """Initialize a streamable HTTP response.

        Args:
            connection: The TCP connection to write to
            status_code: HTTP status code (default: 200)
            status_text: HTTP status text (default: "OK")
            headers: HTTP response headers
            cookies: Response cookies
            protocol: HTTP protocol version
            use_chunked_encoding: Whether to use chunked transfer encoding
        """
        self.status_code = status_code
        self.status_text = status_text
        self.protocol = protocol
        self.headers = headers
        self.cookies = cookies
        self._headers_sent = False

        # Set default headers
        if HeaderKey.CONTENT_TYPE not in self.headers:
            self.headers[HeaderKey.CONTENT_TYPE] = "application/octet-stream"
        if HeaderKey.CONNECTION not in self.headers:
            self.headers[HeaderKey.CONNECTION] = "keep-alive"
        if HeaderKey.DATE not in self.headers:
            try:
                var current_time = String(now(utc=True))
                self.headers[HeaderKey.DATE] = current_time
            except:
                pass

        # Set Transfer-Encoding: chunked if requested
        if use_chunked_encoding:
            self.headers[HeaderKey.TRANSFER_ENCODING] = "chunked"
            # Note: Content-Length should not be set with chunked encoding

        # Create body stream
        self.body_stream = StreamableBodyStream(
            connection^,
            is_chunked=use_chunked_encoding
        )

    fn __moveinit__(out self, owned existing: Self):
        """Move constructor."""
        self.headers = existing.headers^
        self.cookies = existing.cookies^
        self.status_code = existing.status_code
        self.status_text = existing.status_text
        self.protocol = existing.protocol
        self.body_stream = existing.body_stream^
        self._headers_sent = existing._headers_sent


    fn send_headers(mut self) raises:
        """Send the HTTP response headers.

        This must be called before writing any body data.

        Raises:
            Error: If headers have already been sent
        """
        if self._headers_sent:
            raise Error("StreamableHTTPResponse.send_headers: Headers already sent")

        var writer = ByteWriter()

        # Status line: HTTP/1.1 200 OK\r\n
        writer.write(self.protocol, " ", String(self.status_code), " ", self.status_text, lineBreak)

        # Write headers
        for header_pair in self.headers._inner.items():
            writer.write(header_pair.key, ": ", header_pair.value, lineBreak)

        # Write cookies
        for cookie_pair in self.cookies._inner.items():
            writer.write("Set-Cookie: ", cookie_pair.value.build_header_value(), lineBreak)

        # End of headers
        writer.write(lineBreak)

        # Send headers to connection
        var header_bytes = writer^.consume()
        _ = self.body_stream.connection.write(Span(header_bytes))
        self._headers_sent = True

    fn write_chunk(mut self, data: Bytes) raises:
        """Write a chunk of response body data.

        Headers will be sent automatically if not already sent.

        Args:
            data: The data to write

        Raises:
            Error: If writing fails
        """
        if not self._headers_sent:
            self.send_headers()

        _ = self.body_stream.write_chunk(data)

    fn write_sse_event(mut self, event_type: String, data: String, id: String = "") raises:
        """Write a Server-Sent Events (SSE) message.

        Headers will be sent automatically if not already sent.
        Note: You should set Content-Type to "text/event-stream" before calling this.

        Args:
            event_type: The event type
            data: The event data
            id: Optional event ID

        Raises:
            Error: If writing fails
        """
        if not self._headers_sent:
            # Ensure SSE content type is set
            var current_type = self.headers.get(HeaderKey.CONTENT_TYPE)
            if not current_type or current_type.value() != "text/event-stream":
                self.headers[HeaderKey.CONTENT_TYPE] = "text/event-stream"
                self.headers["Cache-Control"] = "no-cache"
                self.headers[HeaderKey.CONNECTION] = "keep-alive"
            self.send_headers()

        self.body_stream.write_sse_event(event_type, data, id)

    fn start_sse_stream(mut self) raises:
        """Initialize headers for Server-Sent Events streaming.

        This sets appropriate headers for SSE and sends them.

        Raises:
            Error: If headers have already been sent
        """
        if self._headers_sent:
            raise Error("StreamableHTTPResponse.start_sse_stream: Headers already sent")

        # Set SSE-specific headers
        self.headers[HeaderKey.CONTENT_TYPE] = "text/event-stream"
        self.headers["Cache-Control"] = "no-cache"
        self.headers[HeaderKey.CONNECTION] = "keep-alive"
        # Note: Transfer-Encoding should not be used with SSE

        self.send_headers()

    fn end_stream(mut self) raises:
        """End the response stream.

        For chunked encoding, this sends the final 0-size chunk.

        Raises:
            Error: If stream cannot be ended
        """
        if not self._headers_sent:
            self.send_headers()

        self.body_stream.end_stream()

    fn flush(mut self) raises:
        """Flush any buffered data to the connection.

        Raises:
            Error: If flushing fails
        """
        self.body_stream.flush()

    fn set_content_type(mut self, content_type: String):
        """Set the Content-Type header.

        Args:
            content_type: The content type to set
        """
        self.headers[HeaderKey.CONTENT_TYPE] = content_type

    fn set_status(mut self, status_code: Int, status_text: String):
        """Set the HTTP status code and text.

        Args:
            status_code: The HTTP status code
            status_text: The HTTP status text
        """
        self.status_code = status_code
        self.status_text = status_text

    fn add_header(mut self, key: String, value: String):
        """Add a custom header.

        Args:
            key: Header key
            value: Header value
        """
        self.headers[key] = value
