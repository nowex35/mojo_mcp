from collections import Dict, Optional
from lightbug_http.connection import TCPConnection
from lightbug_http.mcp.utils import current_time_ms


@value
struct StreamInfo:
    """Information about an active stream."""
    var stream_id: String
    var session_id: String
    var created_at: Float64
    var last_activity: Float64

    fn __init__(out self, stream_id: String, session_id: String) raises:
        var current_time = Float64(current_time_ms()) / 1000.0  # Convert milliseconds to seconds
        self.stream_id = stream_id
        self.session_id = session_id
        self.created_at = current_time
        self.last_activity = current_time

    fn update_activity(mut self) raises:
        """Update the last activity timestamp."""
        self.last_activity = Float64(current_time_ms()) / 1000.0  # Convert milliseconds to seconds

    fn is_idle(self, timeout_seconds: Float64) raises -> Bool:
        """Check if the stream has been idle for longer than the timeout."""
        var current = Float64(current_time_ms()) / 1000.0  # Convert milliseconds to seconds
        return (current - self.last_activity) > timeout_seconds


struct StreamManager:
    """Manages active streaming HTTP connections and sessions.

    This manager tracks:
    - Active StreamableHTTPResponse instances by stream ID
    - Session ID to stream ID mappings
    - Stream metadata and activity timestamps
    - Automatic cleanup of idle streams
    """

    var _stream_info: Dict[String, StreamInfo]
    var _session_to_stream: Dict[String, String]
    var _next_stream_id: UInt64
    var _next_session_id: UInt64
    var _default_timeout: Float64

    fn __init__(out self, default_timeout_seconds: Float64 = 300.0):
        """Initialize the stream manager.

        Args:
            default_timeout_seconds: Default idle timeout for streams (default: 5 minutes).
        """
        self._stream_info = Dict[String, StreamInfo]()
        self._session_to_stream = Dict[String, String]()
        self._next_stream_id = 1
        self._next_session_id = 1
        self._default_timeout = default_timeout_seconds

    fn __moveinit__(out self, owned existing: Self):
        self._stream_info = existing._stream_info^
        self._session_to_stream = existing._session_to_stream^
        self._next_stream_id = existing._next_stream_id
        self._next_session_id = existing._next_session_id
        self._default_timeout = existing._default_timeout

    fn generate_stream_id(mut self) -> String:
        """Generate a unique stream ID."""
        var id = String("stream_") + String(self._next_stream_id)
        self._next_stream_id += 1
        return id

    fn generate_session_id(mut self) -> String:
        """Generate a unique session ID."""
        var id = String("session_") + String(self._next_session_id)
        self._next_session_id += 1
        return id

    fn register_stream(
        mut self,
        stream_id: String,
        session_id: String
    ) raises:
        """Register a new stream with the manager.

        Args:
            stream_id: Unique identifier for the stream.
            session_id: Session ID associated with this stream.
        """
        var info = StreamInfo(stream_id, session_id)
        self._stream_info[stream_id] = info
        self._session_to_stream[session_id] = stream_id

    fn get_stream_id_by_session(self, session_id: String) -> Optional[String]:
        """Get the stream ID associated with a session.

        Args:
            session_id: The session ID to lookup.

        Returns:
            The stream ID if found, None otherwise.
        """
        return self._session_to_stream.get(session_id)

    fn update_stream_activity(mut self, stream_id: String) raises -> Bool:
        """Update the last activity timestamp for a stream.

        Args:
            stream_id: The stream to update.

        Returns:
            True if the stream was found and updated, False otherwise.
        """
        var info_opt = self._stream_info.get(stream_id)
        if info_opt:
            var info = info_opt.value()
            info.update_activity()
            self._stream_info[stream_id] = info
            return True
        return False

    fn cleanup_stream(mut self, stream_id: String) raises -> Bool:
        """Clean up a stream and remove it from tracking.

        Args:
            stream_id: The stream to clean up.

        Returns:
            True if the stream was found and cleaned up, False otherwise.
        """
        var info_opt = self._stream_info.get(stream_id)
        if not info_opt:
            return False

        var info = info_opt.value()
        var session_id = info.session_id

        # Remove from both mappings
        _ = self._stream_info.pop(stream_id)
        _ = self._session_to_stream.pop(session_id)

        return True

    fn cleanup_idle_streams(mut self, timeout_seconds: Optional[Float64] = None) raises -> Int:
        """Clean up all idle streams that have exceeded the timeout.

        Args:
            timeout_seconds: Custom timeout, or use default if not provided.

        Returns:
            The number of streams that were cleaned up.
        """
        var timeout = timeout_seconds.value() if timeout_seconds else self._default_timeout
        var cleaned = 0

        # Collect stream IDs to clean up
        var to_cleanup = List[String]()
        for entry in self._stream_info.items():
            if entry.value.is_idle(timeout):
                to_cleanup.append(entry.value.stream_id)

        # Clean up the identified streams
        for stream_id in to_cleanup:
            if self.cleanup_stream(stream_id):
                cleaned += 1

        return cleaned

    fn active_stream_count(self) -> Int:
        """Get the number of currently active streams."""
        return len(self._stream_info)

    fn has_stream(self, stream_id: String) -> Bool:
        """Check if a stream is currently active."""
        return self._stream_info.get(stream_id) is not None

    fn has_session(self, session_id: String) -> Bool:
        """Check if a session has an active stream."""
        return self._session_to_stream.get(session_id) is not None
