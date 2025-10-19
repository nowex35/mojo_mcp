from collections import Dict
from python import Python
from .utils import  current_time_ms

# Session states
alias SessionState = Int
alias SESSION_ACTIVE: SessionState = 0
alias SESSION_EXPIRED: SessionState = 1
alias SESSION_TERMINATED: SessionState = 2


@value
struct MCPSession(Movable):
    """Represents an MCP session with timeout management."""
    var session_id: String
    var connection_id: String
    var state: SessionState
    var created_at: Int  # Unix timestamp in milliseconds
    var last_activity: Int  # Unix timestamp in milliseconds
    var timeout_duration: Int  # Session timeout in milliseconds (default: 30 minutes)
    var client_info: String  # JSON string with client information
    var event_id_counter: Int  # Counter for SSE event IDs

    fn __init__(out self, session_id: String, connection_id: String, client_info: String = "{}"):
        self.session_id = session_id
        self.connection_id = connection_id
        self.state = SESSION_ACTIVE
        self.created_at = current_time_ms()
        self.last_activity = current_time_ms()
        self.timeout_duration = 30 * 60 * 1000  # 30 minutes in milliseconds
        self.client_info = client_info
        self.event_id_counter = 0

    fn is_expired(self) -> Bool:
        """Check if the session has expired."""
        var current_time = current_time_ms()
        return (current_time - self.last_activity) > self.timeout_duration

    fn update_activity(mut self):
        """Update the last activity timestamp."""
        self.last_activity = current_time_ms()

    fn terminate(mut self):
        """Terminate the session."""
        self.state = SESSION_TERMINATED

    fn next_event_id(mut self) -> String:
        """Generate the next SSE event ID for this session.

        Returns:
            Event ID in format: {session_id}-{counter}
        """
        self.event_id_counter += 1
        return self.session_id + "-" + String(self.event_id_counter)

@value
struct SessionManager(Movable):
    """Manages MCP sessions with automatic cleanup."""
    var sessions: Dict[String, MCPSession] # 現在のセッション情報を保存する辞書
    var connection_to_session: Dict[String, String]  # connection_idからsession_idへのマッピング
    var cleanup_enabled: Bool # 自動クリーンアップの有効/無効
    var last_cleanup: Int # 最後のクリーンアップ時間
    var cleanup_interval: Int  # クリーンアップ間隔（ミリ秒）（デフォルト: 5分）

    fn __init__(out self):
        self.sessions = Dict[String, MCPSession]()
        self.connection_to_session = Dict[String, String]()
        self.cleanup_enabled = True
        self.last_cleanup = current_time_ms()
        self.cleanup_interval = 5 * 60 * 1000  # 5 minutes in milliseconds

    fn create_session(mut self, connection_id: String, client_info: String = "{}") -> String:
        """Create a new session and return the session ID."""
        var session_id = generate_uuid()
        var session = MCPSession(session_id, connection_id, client_info)

        self.sessions[session_id] = session
        self.connection_to_session[connection_id] = session_id

        return session_id

    fn get_session(self, session_id: String) raises -> MCPSession:
        """Get a session by ID."""
        if session_id not in self.sessions:
            raise Error("Session not found: " + session_id)
        return self.sessions[session_id]

    fn update_session_activity(mut self, session_id: String) raises:
        """Update the last activity timestamp for a session."""
        if session_id not in self.sessions:
            raise Error("Session not found: " + session_id)

        var session = self.sessions[session_id]
        session.update_activity()
        self.sessions[session_id] = session

    fn terminate_session(mut self, session_id: String) raises:
        """Terminate a session."""
        if session_id not in self.sessions:
            return  # Session already doesn't exist

        var session = self.sessions[session_id]
        session.terminate()

        # Remove from both mappings
        _ = self.connection_to_session.pop(session.connection_id, "")
        _ = self.sessions.pop(session_id)

        print("Session terminated: " + session_id)

    fn terminate_session_by_connection(mut self, connection_id: String) raises:
        """Terminate a session by connection ID."""
        if connection_id in self.connection_to_session:
            try:
                var session_id = self.connection_to_session[connection_id]
                self.terminate_session(session_id)
            except:
                pass  # Session might have been already removed

    fn cleanup_expired_sessions(mut self) -> Int:
        """Clean up expired sessions and return the number of sessions cleaned."""
        var current_time = current_time_ms()
        if not self.cleanup_enabled or (current_time - self.last_cleanup) < self.cleanup_interval:
            return 0

        # Collect expired session IDs
        var expired_sessions = List[String]()
        for session_id in self.sessions:
            try:
                var session = self.sessions[session_id]
                if session.is_expired() or session.state == SESSION_TERMINATED:
                    expired_sessions.append(session_id)
            except:
                # If we can't access the session, consider it for cleanup
                expired_sessions.append(session_id)

        # Remove expired sessions
        var cleaned_count = 0
        for i in range(len(expired_sessions)):
            try:
                self.terminate_session(expired_sessions[i])
                cleaned_count += 1
            except:
                pass  # Session might have been already removed

        self.last_cleanup = current_time

        if cleaned_count > 0:
            print("Cleaned up " + String(cleaned_count) + " expired sessions")

        return cleaned_count

    fn get_active_session_count(self) -> Int:
        """Get the number of active sessions."""
        var count = 0
        for session_id in self.sessions:
            try:
                var session = self.sessions[session_id]
                if session.state == SESSION_ACTIVE and not session.is_expired():
                    count += 1
            except:
                continue
        return count

    fn force_cleanup(mut self) -> Int:
        """Force immediate cleanup regardless of interval."""
        self.last_cleanup = 0  # Reset to force cleanup
        return self.cleanup_expired_sessions()

    fn generate_event_id(mut self, session_id: String) raises -> String:
        """Generate next SSE event ID for a session.

        Args:
            session_id: The session ID

        Returns:
            Event ID in format: {session_id}-{counter}

        Raises:
            Error if session not found
        """
        if session_id not in self.sessions:
            raise Error("Session not found: " + session_id)

        var session = self.sessions[session_id]
        var event_id = session.next_event_id()
        self.sessions[session_id] = session  # Update session with new counter
        return event_id