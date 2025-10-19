from lightbug_http.streaming.streamable_exchange import StreamableHTTPExchange

trait StreamableHTTPService:
    """Service trait for handling streaming HTTP exchanges.

    Services implementing this trait process StreamableHTTPExchange,
    which provides unified access to request data and response writing
    over the same connection, enabling efficient streaming of large
    request/response bodies and real-time communication features like
    Server-Sent Events.
    """

    fn call(mut self, mut exchange: StreamableHTTPExchange) raises:
        """Process a streaming HTTP exchange.

        The exchange provides access to:
        - Request data: method, uri, headers, cookies
        - Request body reading: read_body_chunk()
        - Response writing: set_status(), add_header(), write_chunk(), etc.

        Args:
            exchange: The HTTP exchange containing request data and response writer

        Raises:
            Any errors that occur during request processing.
        """
        ...
