from memory import Span
from lightbug_http.io.bytes import Bytes, BytesConstant, ByteView, bytes
from lightbug_http._logger import logger
from lightbug_http.connection import NoTLSListener, default_buffer_size, ListenConfig
from lightbug_http.streaming.streamable_exchange import StreamableHTTPExchange
from lightbug_http.streaming.streamable_service import StreamableHTTPService
from lightbug_http.streaming.shared_connection import SharedConnection
from lightbug_http.error import ErrorHandler
from lightbug_http.mcp.utils import delete_zombies
from lightbug_http._libc import fork, exit, pid_t

alias default_max_request_body_size = 4 * 1024 * 1024  # 4MB
alias default_max_request_uri_length = 8192


struct StreamingServer(Movable):
    """A streaming-capable HTTP server for Mojo.

    This server supports both traditional HTTP request/response handling
    and streaming patterns including:
    - Chunked transfer encoding
    - Server-Sent Events (SSE)
    - Large file uploads/downloads
    - Real-time bidirectional communication
    """

    var error_handler: ErrorHandler
    var name: String
    var _address: String
    var max_concurrent_connections: UInt
    var max_requests_per_connection: UInt
    var _max_request_body_size: UInt
    var _max_request_uri_length: UInt
    var tcp_keep_alive: Bool

    fn __init__(
        out self,
        name: String = "lightbug_http_streaming",
        address: String = "127.0.0.1",
        max_concurrent_connections: UInt = 1000,
        max_requests_per_connection: UInt = 0,
        max_request_body_size: UInt = default_max_request_body_size,
        max_request_uri_length: UInt = default_max_request_uri_length,
        tcp_keep_alive: Bool = True,  # Streaming benefits from keep-alive
    ) raises:
        var error_handler = ErrorHandler()
        self.error_handler = error_handler
        self.name = name
        self._address = address
        self.max_requests_per_connection = max_requests_per_connection
        self._max_request_body_size = max_request_body_size
        self._max_request_uri_length = max_request_uri_length
        self.tcp_keep_alive = tcp_keep_alive
        self.max_concurrent_connections = max_concurrent_connections if max_concurrent_connections > 0 else 1000

    fn __moveinit__(out self, owned other: StreamingServer):
        self.error_handler = other.error_handler^
        self.name = other.name^
        self._address = other._address^
        self.max_concurrent_connections = other.max_concurrent_connections
        self.max_requests_per_connection = other.max_requests_per_connection
        self._max_request_body_size = other._max_request_body_size
        self._max_request_uri_length = other._max_request_uri_length
        self.tcp_keep_alive = other.tcp_keep_alive

    fn address(self) -> ref [self._address] String:
        return self._address

    fn set_address(mut self, own_address: String):
        self._address = own_address

    fn listen_and_serve[T: StreamableHTTPService](
        mut self,
        address: String,
        mut handler: T
    ) raises:
        """Listen for incoming connections and serve streaming HTTP requests.

        Parameters:
            T: The type of StreamableHTTPService that handles incoming requests.

        Args:
            address: The address (host:port) to listen on.
            handler: An object that handles incoming streaming HTTP requests.
        """
        var config = ListenConfig()
        var listener = config.listen(address)
        self.set_address(address)
        self.serve(listener^, handler)

    fn serve[T: StreamableHTTPService](
        mut self,
        owned ln: NoTLSListener,
        mut handler: T
    ) raises:
        """Serve streaming HTTP requests.

        Parameters:
            T: The type of StreamableHTTPService that handles incoming requests.

        Args:
            ln: TCP server that listens for incoming connections.
            handler: An object that handles incoming streaming HTTP requests.
        """
        while True:
            # ゾンビプロセスの削除
            delete_zombies()

            # リスナーで待つ
            var conn = ln.accept()
            # 所有権があることからforkで子プロセスに直接渡す(共有する)とエラーとなるので、ポインタ経由で共有する
            var shared_conn = SharedConnection(conn^)

            # Forkを使って新しいプロセスで接続を処理
            var pid: pid_t
            try:
                pid = fork()
            except e:
                logger.error("Fork failed:", String(e))
                print("[StreamingServer] Fork failed:", String(e))
                try:
                    shared_conn.teardown()
                except:
                    pass
                continue

            # 子プロセスではfork関数自体が返り値として子プロセスのpidではなく、pid=0を返す
            if pid == 0:
                try:
                    # 子プロセスはリスナーを閉じ、クライアント接続を処理に専念する
                    try:
                        ln.close()
                    except:
                        # 閉じるのに失敗した場合
                        pass

                    # リクエストに対する処理
                    self.serve_connection(shared_conn, handler)

                    # Exit successfully
                    exit(0)
                except e:
                    logger.error("Child process error:", String(e))
                    print("[StreamingServer] Child process error:", String(e))
                    # Exit with error status
                    exit(1)
            # 親プロセスではfork関数が返り値としてpid=子プロセスIDを返す
            # なお子プロセスよりも先に親プロセスが死んだ場合、里親のような形で代わりにPID=1のinitプロセスが引き取る
            elif pid > 0:
                # 親プロセスは接続の所有権を子プロセスに譲渡する
                # fork()後、親と子は独立したメモリを持つが、ファイルディスクリプタは共有される
                # 親側で所有権を放棄することで、子プロセスだけがteardown()でクローズできる
                shared_conn.release_ownership()

    fn serve_connection[T: StreamableHTTPService](
        mut self,
        shared_conn: SharedConnection,
        mut handler: T
    ) raises -> None:
        """Serve a single streaming connection with keep-alive support.

        Parameters:
            T: The type of StreamableHTTPService that handles incoming requests.

        Args:
            shared_conn: A shared connection object representing a client connection.
            handler: An object that handles incoming streaming HTTP requests.
        """
        var remote_addr = shared_conn.get_remote_address()
        print("[CONN] New connection from:", remote_addr)
        logger.debug(
            "Streaming connection accepted! Remote:",
            remote_addr
        )

        var max_request_uri_length = self._max_request_uri_length
        if max_request_uri_length <= 0:
            max_request_uri_length = default_max_request_uri_length

        var req_number = 0

        # Keep-alive loop: process multiple requests on the same connection
        while True:
            req_number += 1
            print("[CONN] Request #" + String(req_number) + " on this connection")

            # Check if connection is still valid before attempting to read
            if shared_conn.is_closed():
                print("[CONN] Connection is closed, exiting keep-alive loop")
                return

            # Read headers
            var header_buffer = Bytes()
            while True:
                try:
                    # header用の一時バッファ
                    var temp_buffer = Bytes(capacity=default_buffer_size)
                    var bytes_read = shared_conn.read(temp_buffer)
                    logger.debug("Bytes read:", bytes_read)

                    if bytes_read == 0:
                        print("[CONN] Client closed connection (0 bytes read)")
                        shared_conn.teardown()
                        return

                    header_buffer.extend(temp_buffer^)

                    # DOUBLE_CRLFが来るまで読み続ける
                    if BytesConstant.DOUBLE_CRLF in ByteView(header_buffer):
                        logger.debug("Found end of headers")
                        print("[CONN] Headers received, buffer size:", len(header_buffer))
                        break

                except e:
                    var error_msg = String(e)
                    print("[CONN] Error reading headers:", error_msg)

                    # Handle different types of connection errors gracefully
                    if "EOF" in error_msg or "invalid descriptor" in error_msg or "not associated with a socket" in error_msg or "closed" in error_msg.lower():
                        print("[CONN] Client closed connection")
                        try:
                            shared_conn.teardown()
                        except:
                            pass
                        return
                    else:
                        logger.error("Failed to read headers:", error_msg)
                        try:
                            shared_conn.teardown()
                        except:
                            pass
                        return

            # リクエスト及びレスポンスを扱うExchangeを作成.名前を変更したい
            var exchange: StreamableHTTPExchange
            try:
                exchange = StreamableHTTPExchange.from_connection(
                    shared_conn,
                    self.address(),
                    Int(max_request_uri_length),
                    Span(header_buffer)
                )
            except e:
                logger.error("Failed to parse request:", String(e))
                shared_conn.teardown()
                return

            var req_method = exchange.method
            var req_path = exchange.uri.path

            print("[CONN] Request:", req_method, req_path)

            # Call the streaming service handler
            var handler_error: Optional[String] = None
            try:
                handler.call(exchange)
                print("[CONN] Handler completed successfully")
            except e:
                handler_error = String(e)
                print("[CONN] Handler error:", String(e))

            logger.debug(req_method, req_path, exchange.response_status_code, "(streaming)")

            # Handle errors and connection close
            if handler_error:
                logger.error("Handler error:", handler_error.value())
                print("[CONN] Closing connection due to handler error")
                shared_conn.teardown()
                return  # Exit the keep-alive loop

            # Check if we should close the connection
            var should_close = False
            try:
                should_close = exchange.connection_close()
            except:
                pass

            if should_close:
                print("[CONN] Closing connection (Connection: close header)")
                shared_conn.teardown()
                return  # Exit the keep-alive loop
            else:
                print("[CONN] Keeping connection alive, waiting for next request...")