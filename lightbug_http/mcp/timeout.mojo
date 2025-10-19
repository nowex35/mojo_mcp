from collections import Dict
from .jsonrpc import JSONRPCRequest, JSONRPCNotification, JSONRPCError
from .utils import current_time_ms, JSONBuilder

# Timeout constants (in milliseconds)
alias DEFAULT_REQUEST_TIMEOUT: Int = 30000  # 30 seconds
alias MAXIMUM_REQUEST_TIMEOUT: Int = 300000  # 5 minutes
alias PROGRESS_RESET_TIMEOUT: Int = 60000   # 1 minute additional time on progress

@value
struct TimeoutConfig(Movable):
    """Configuration for request timeouts."""
    var default_timeout_ms: Int
    var maximum_timeout_ms: Int
    var progress_reset_timeout_ms: Int
    var enable_progress_reset: Bool

    fn __init__(out self,
                default_timeout_ms: Int = DEFAULT_REQUEST_TIMEOUT,
                maximum_timeout_ms: Int = MAXIMUM_REQUEST_TIMEOUT,
                progress_reset_timeout_ms: Int = PROGRESS_RESET_TIMEOUT,
                enable_progress_reset: Bool = True):
        self.default_timeout_ms = default_timeout_ms
        self.maximum_timeout_ms = maximum_timeout_ms
        self.progress_reset_timeout_ms = progress_reset_timeout_ms
        self.enable_progress_reset = enable_progress_reset

@value
struct PendingRequest(Movable):
    """A request waiting for response with timeout tracking."""
    var request_id: String
    var method: String
    var start_time_ms: Int
    var timeout_ms: Int
    var max_timeout_ms: Int
    var last_progress_time_ms: Int
    var is_cancelled: Bool

    fn __init__(out self, request_id: String, method: String, timeout_ms: Int, max_timeout_ms: Int):
        self.request_id = request_id
        self.method = method
        self.start_time_ms = Int(current_time_ms())
        self.timeout_ms = timeout_ms
        self.max_timeout_ms = max_timeout_ms
        self.last_progress_time_ms = self.start_time_ms
        self.is_cancelled = False

    fn is_expired(self) -> Bool:
        """Check if the request has expired based on timeout rules."""
        if self.is_cancelled:
            return True

        var current_time_ms = Int(current_time_ms())
        var elapsed_since_start = current_time_ms - self.start_time_ms
        var elapsed_since_progress = current_time_ms - self.last_progress_time_ms

        # Check maximum timeout (always enforced)
        if elapsed_since_start >= self.max_timeout_ms:
            return True

        # Check regular timeout (can be reset by progress)
        if elapsed_since_progress >= self.timeout_ms:
            return True

        return False

    fn update_progress(mut self):
        """Update the progress timestamp, potentially resetting the timeout clock."""
        self.last_progress_time_ms = Int(current_time_ms())

    fn cancel(mut self):
        """Mark this request as cancelled."""
        self.is_cancelled = True

    fn get_remaining_timeout_ms(self) -> Int:
        """Get the remaining timeout in milliseconds."""
        if self.is_cancelled:
            return 0

        var current_time_ms = Int(current_time_ms())
        var elapsed_since_progress = current_time_ms - self.last_progress_time_ms
        var remaining = self.timeout_ms - elapsed_since_progress

        # Also check max timeout
        var elapsed_since_start = current_time_ms - self.start_time_ms
        var max_remaining = self.max_timeout_ms - elapsed_since_start

        # Return the smaller of the two
        if max_remaining < remaining:
            return max_remaining
        return remaining

@value
struct TimeoutManager(Movable):
    """Manages request timeouts and cancellations for MCP requests."""
    var config: TimeoutConfig
    var pending_requests: Dict[String, PendingRequest]
    var cancelled_requests: Dict[String, Bool]  # Track cancelled request IDs

    fn __init__(out self, config: TimeoutConfig = TimeoutConfig()):
        self.config = config
        self.pending_requests = Dict[String, PendingRequest]()
        self.cancelled_requests = Dict[String, Bool]()

    fn add_request(mut self, request: JSONRPCRequest, custom_timeout_ms: Int = -1) raises:
        """Add a request to timeout tracking."""
        if request.id in self.pending_requests:
            # Request ID already exists - this should not happen in normal operation
            return

        # Determine timeout to use
        var timeout_ms = self.config.default_timeout_ms
        if custom_timeout_ms > 0:
            timeout_ms = custom_timeout_ms

        # Enforce maximum timeout
        var max_timeout_ms = self.config.maximum_timeout_ms
        if timeout_ms > max_timeout_ms:
            timeout_ms = max_timeout_ms

        # Create and store pending request
        var pending = PendingRequest(request.id, request.method, timeout_ms, max_timeout_ms)
        self.pending_requests[request.id] = pending

    fn complete_request(mut self, request_id: String) raises:
        """Mark a request as completed (remove from timeout tracking)."""
        if request_id in self.pending_requests:
            _ = self.pending_requests.pop(request_id)

        # Remove from cancelled list if present
        if request_id in self.cancelled_requests:
            _ = self.cancelled_requests.pop(request_id)

    fn cancel_request(mut self, request_id: String) raises -> Bool:
        """Cancel a specific request. Returns True if the request was found and cancelled."""
        if request_id in self.pending_requests:
            var request = self.pending_requests[request_id]
            request.cancel()
            self.pending_requests[request_id] = request
            self.cancelled_requests[request_id] = True
            return True
        return False

    fn is_request_cancelled(self, request_id: String) -> Bool:
        """Check if a request has been cancelled."""
        return request_id in self.cancelled_requests

    fn update_progress(mut self, request_id: String) raises -> Bool:
        """Update progress for a request, potentially resetting its timeout. Returns True if request exists."""
        if not self.config.enable_progress_reset:
            return False

        if request_id in self.pending_requests:
            var request = self.pending_requests[request_id]
            if not request.is_cancelled:
                request.update_progress()
                self.pending_requests[request_id] = request
                return True
        return False

    fn check_expired_requests(mut self) raises -> List[String]:
        """Check for expired requests and return their IDs."""
        var expired_ids = List[String]()

        # Collect expired request IDs
        for request_id in self.pending_requests:
            var request = self.pending_requests[request_id]
            if request.is_expired():
                expired_ids.append(request_id)

        # Mark expired requests as cancelled
        for i in range(len(expired_ids)):
            var request_id = expired_ids[i]
            _ = self.cancel_request(request_id)

        return expired_ids

    fn get_pending_request_count(self) raises -> Int:
        """Get the number of pending (non-cancelled) requests."""
        var count = 0
        for request_id in self.pending_requests:
            var request = self.pending_requests[request_id]
            if not request.is_cancelled:
                count += 1
        return count

    fn get_cancelled_request_count(self) -> Int:
        """Get the number of cancelled requests."""
        return len(self.cancelled_requests)

    fn cleanup_completed_requests(mut self) raises -> None:
        """Remove old completed/cancelled requests from memory."""
        var current_time_ms = Int(current_time_ms())
        var cleanup_threshold_ms = 300000  # 5 minutes

        # Collect request IDs to remove
        var to_remove = List[String]()

        for request_id in self.pending_requests:
            var request = self.pending_requests[request_id]
            if request.is_cancelled:
                var age = current_time_ms - request.start_time_ms
                if age > cleanup_threshold_ms:
                    to_remove.append(request_id)

        # Remove old requests
        for i in range(len(to_remove)):
            var request_id = to_remove[i]
            try:
                _ = self.pending_requests.pop(request_id)
                if request_id in self.cancelled_requests:
                    _ = self.cancelled_requests.pop(request_id)
            except:
                pass

# Timeout-related JSON-RPC structures
@value
struct CancellationNotification(Movable):
    """A cancellation notification to be sent when a request times out."""
    var request_id: String
    var reason: String

    fn __init__(out self, request_id: String, reason: String = "timeout"):
        self.request_id = request_id
        self.reason = reason

    fn to_json_rpc_notification(self) -> JSONRPCNotification:
        """Convert to a JSON-RPC notification."""
        var builder = JSONBuilder()
        builder.add_string("id", self.request_id)
        builder.add_string("reason", self.reason)
        var params = builder.build()
        return JSONRPCNotification("notifications/cancelled", params)

@value
struct ProgressNotification(Movable):
    """A progress notification indicating work is being done on a request."""
    var request_id: String
    var progress_token: String
    var message: String

    fn __init__(out self, request_id: String, progress_token: String = "", message: String = ""):
        self.request_id = request_id
        self.progress_token = progress_token
        self.message = message

    fn to_json_rpc_notification(self) -> JSONRPCNotification:
        """Convert to a JSON-RPC notification."""
        var message_builder = JSONBuilder()
        message_builder.add_string("message", self.message)

        var builder = JSONBuilder()
        builder.add_string("progressToken", self.progress_token)
        builder.add_raw("value", message_builder.build())
        var params = builder.build()
        return JSONRPCNotification("notifications/progress", params)

# Utility functions
fn create_timeout_error(request_id: String, method: String, elapsed_ms: Int) -> JSONRPCError:
    """Create a timeout error for a request."""
    var message = String("Request timeout after ", String(elapsed_ms), "ms for method: ", method)
    return JSONRPCError(-32603, message)

fn create_cancellation_error(request_id: String, method: String) -> JSONRPCError:
    """Create a cancellation error for a request."""
    var message = String("Request cancelled for method: ", method)
    return JSONRPCError(-32800, message)  # Custom error code for cancellation