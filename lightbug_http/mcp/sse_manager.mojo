from collections import Dict
from .utils import current_time_ms


@value
struct SSEConnection(Movable):
    """Represents an active SSE connection."""
    var session_id: String
    var created_at: Int
    var last_heartbeat: Int
    var heartbeat_interval_ms: Int  # Default: 30 seconds

    fn __init__(out self, session_id: String, heartbeat_interval_ms: Int = 30000):
        self.session_id = session_id
        self.created_at = current_time_ms()
        self.last_heartbeat = current_time_ms()
        self.heartbeat_interval_ms = heartbeat_interval_ms

    fn should_send_heartbeat(self) -> Bool:
        """Check if a heartbeat should be sent.

        Returns:
            True if time since last heartbeat > interval
        """
        var current = current_time_ms()
        return (current - self.last_heartbeat) >= self.heartbeat_interval_ms

    fn mark_heartbeat_sent(mut self):
        """Mark that a heartbeat was sent."""
        self.last_heartbeat = current_time_ms()


@value
struct SSEConnectionManager(Movable):
    """Manages active SSE connections and heartbeats."""
    var connections: Dict[String, SSEConnection]  # session_id -> connection
    var default_heartbeat_interval_ms: Int

    fn __init__(out self, heartbeat_interval_ms: Int = 30000):
        """Initialize SSE connection manager.

        Args:
            heartbeat_interval_ms: Interval between heartbeats (default: 30s)
        """
        self.connections = Dict[String, SSEConnection]()
        self.default_heartbeat_interval_ms = heartbeat_interval_ms

    fn register_connection(mut self, session_id: String) raises:
        """Register a new SSE connection.

        Args:
            session_id: The session ID

        Raises:
            Error if connection already exists
        """
        if session_id in self.connections:
            raise Error("SSE connection already registered: " + session_id)

        var conn = SSEConnection(session_id, self.default_heartbeat_interval_ms)
        self.connections[session_id] = conn

    fn unregister_connection(mut self, session_id: String) raises:
        """Unregister an SSE connection.

        Args:
            session_id: The session ID
        """
        if session_id in self.connections:
            _ = self.connections.pop(session_id)

    fn get_connections_needing_heartbeat(self) -> List[String]:
        """Get list of session IDs that need a heartbeat.

        Returns:
            List of session IDs needing heartbeat
        """
        var needing_heartbeat = List[String]()

        for session_id in self.connections:
            try:
                var conn = self.connections[session_id]
                if conn.should_send_heartbeat():
                    needing_heartbeat.append(session_id)
            except:
                continue

        return needing_heartbeat

    fn mark_heartbeat_sent(mut self, session_id: String) raises:
        """Mark that a heartbeat was sent for a connection.

        Args:
            session_id: The session ID

        Raises:
            Error if connection not found
        """
        if session_id not in self.connections:
            raise Error("SSE connection not found: " + session_id)

        var conn = self.connections[session_id]
        conn.mark_heartbeat_sent()
        self.connections[session_id] = conn

    fn has_connection(self, session_id: String) -> Bool:
        """Check if a connection exists.

        Args:
            session_id: The session ID

        Returns:
            True if connection exists
        """
        return session_id in self.connections

    fn get_connection_count(self) -> Int:
        """Get the number of active connections.

        Returns:
            Number of active connections
        """
        return len(self.connections)


# Utility functions

fn create_sse_heartbeat() -> String:
    """Create an SSE heartbeat comment.

    Returns:
        SSE comment line for heartbeat
    """
    return ": heartbeat\n\n"
