from memory import Span
from lightbug_http.io.bytes import Bytes, bytes, ByteReader, ByteWriter
from lightbug_http.header import Headers, HeaderKey
from lightbug_http.cookie import RequestCookieJar
from lightbug_http.uri import URI
from lightbug_http.connection import TCPConnection
from lightbug_http.io.sync import Duration
from lightbug_http.streaming.streamable_body_stream import StreamableBodyStream
from lightbug_http.strings import strHttp11


struct StreamableHTTPRequest:
    """HTTP Request with streaming body support.

    Instead of loading the entire request body into memory, this implementation
    allows reading the body in chunks via StreamableBodyStream.
    """

    var headers: Headers
    var cookies: RequestCookieJar
    var uri: URI
    var method: String
    var protocol: String
    var body_stream: StreamableBodyStream
    var server_is_tls: Bool
    var timeout: Duration

    @staticmethod
    fn from_connection(
        owned connection: TCPConnection,
        addr: String,
        max_uri_length: Int,
        initial_buffer: Span[Byte]
    ) raises -> StreamableHTTPRequest:
        """Parse HTTP request headers from connection and create a streamable request.

        Args:
            connection: The TCP connection to read from
            addr: Server address
            max_uri_length: Maximum allowed URI length
            initial_buffer: Initial buffer containing at least the headers

        Returns:
            A StreamableHTTPRequest with headers parsed and body stream ready

        Raises:
            Error: If headers cannot be parsed or URI is too long
        """
        var reader = ByteReader(initial_buffer)
        var headers = Headers()
        var method: String
        var protocol: String
        var uri: String

        try:
            var rest = headers.parse_raw(reader)
            method, uri, protocol = rest[0], rest[1], rest[2]
        except e:
            raise Error("StreamableHTTPRequest.from_connection: Failed to parse request headers: " + String(e))

        if len(uri.as_bytes()) > max_uri_length:
            raise Error("StreamableHTTPRequest.from_connection: Request URI too long")

        var cookies = RequestCookieJar()
        try:
            cookies.parse_cookies(headers)
        except e:
            raise Error("StreamableHTTPRequest.from_connection: Failed to parse cookies: " + String(e))

        # Determine if chunked encoding is used
        var is_chunked = False
        var transfer_encoding = headers.get(HeaderKey.TRANSFER_ENCODING)
        if transfer_encoding:
            is_chunked = transfer_encoding.value() == "chunked"

        # Get content length if available
        var content_length = headers.content_length()

        # Create body stream
        var body_stream = StreamableBodyStream(
            connection^,
            content_length=content_length,
            is_chunked=is_chunked
        )

        var parsed_uri = URI.parse(addr + uri)
        return StreamableHTTPRequest(
            parsed_uri,
            body_stream^,
            headers,
            cookies,
            method,
            protocol,
            False,
            Duration()
        )

    fn __init__(
        out self,
        uri: URI,
        owned body_stream: StreamableBodyStream,
        headers: Headers = Headers(),
        cookies: RequestCookieJar = RequestCookieJar(),
        method: String = "GET",
        protocol: String = strHttp11,
        server_is_tls: Bool = False,
        timeout: Duration = Duration()
    ):
        """Initialize a streamable HTTP request.

        Args:
            uri: Request URI
            body_stream: Streaming body handler
            headers: HTTP headers
            cookies: Request cookies
            method: HTTP method (GET, POST, etc.)
            protocol: HTTP protocol version
            server_is_tls: Whether the server uses TLS
            timeout: Request timeout duration
        """
        self.headers = headers
        self.cookies = cookies
        self.method = method
        self.protocol = protocol
        self.uri = uri
        self.body_stream = body_stream^
        self.server_is_tls = server_is_tls
        self.timeout = timeout

        if HeaderKey.CONNECTION not in self.headers:
            self.headers[HeaderKey.CONNECTION] = "keep-alive"
        if HeaderKey.HOST not in self.headers:
            if uri.port:
                var host = String.write(uri.host, ":", String(uri.port.value()))
                self.headers[HeaderKey.HOST] = host
            else:
                self.headers[HeaderKey.HOST] = uri.host

    fn __moveinit__(out self, owned existing: Self):
        """Move constructor."""
        self.headers = existing.headers^
        self.cookies = existing.cookies^
        self.uri = existing.uri^
        self.method = existing.method
        self.protocol = existing.protocol
        self.body_stream = existing.body_stream^
        self.server_is_tls = existing.server_is_tls
        self.timeout = existing.timeout

    fn read_body_chunk(mut self) raises -> Bytes:
        """Read the next chunk of the request body.

        Returns:
            The next chunk of data, or empty Bytes if stream is complete

        Raises:
            Error: If reading fails
        """
        return self.body_stream.read_chunk()

    fn is_body_complete(self) -> Bool:
        """Check if the entire body has been read.

        Returns:
            True if the body stream is complete
        """
        return self.body_stream.is_complete()

    fn connection_close(self) -> Bool:
        """Check if the connection should be closed after this request.

        Returns:
            True if Connection: close header is present
        """
        var result = self.headers.get(HeaderKey.CONNECTION)
        if not result:
            return False
        return result.value() == "close"
