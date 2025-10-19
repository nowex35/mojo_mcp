from memory import UnsafePointer
from lightbug_http.connection import TCPConnection
from lightbug_http.io.bytes import Bytes
from memory import Span

struct SharedConnection:
    """Wrapper for TCPConnection that allows safe copying and sharing."""
    var _connection: UnsafePointer[TCPConnection]
    var _owned: Bool

    fn __init__(out self, owned conn: TCPConnection):
        """Create a shared connection from an owned TCPConnection."""
        self._connection = UnsafePointer[TCPConnection].alloc(1)
        self._connection.init_pointee_move(conn^)
        self._owned = True

    fn __copyinit__(out self, other: SharedConnection):
        """Copy constructor - shares the same connection."""
        self._connection = other._connection
        self._owned = False  # Only the original owns the connection

    fn __moveinit__(out self, owned other: SharedConnection):
        """Move constructor - transfers ownership."""
        self._connection = other._connection
        self._owned = other._owned
        other._owned = False

    fn __del__(owned self):
        """Destructor - clean up the connection."""
        try:
            if self._owned:
                self._connection[].teardown()
            # Always free the pointer, even if not owned
            self._connection.free()
        except:
            # Ignore errors during cleanup
            pass

    fn read(self, mut buffer: Bytes) raises -> Int:
        """Read from the connection."""
        return self._connection[].read(buffer)

    fn write(self, data: Span[Byte]) raises -> Int:
        """Write to the connection."""
        return self._connection[].write(data)

    fn teardown(self) raises:
        """Close the connection if owned."""
        if self._owned:
            self._connection[].teardown()
            self._connection.free()

    fn get_remote_address(self) -> String:
        """Get remote address information."""
        var conn_ptr = self._connection
        return conn_ptr[].socket._remote_address.ip + ":" + String(conn_ptr[].socket._remote_address.port)

    fn release_ownership(mut self):
        """Release ownership of the connection without closing it.

        This is useful when forking processes where the child process
        should take full ownership of the connection.
        """
        self._owned = False
