from lightbug_http._libc import wait4, WNOHANG, pid_t
from lightbug_http._logger import logger


fn delete_zombies() -> None:
    while True:
        try:
            # Wait for any child process (-1) with WNOHANG (non-blocking)
            # Returns:
            #   > 0: PID of reaped child process
            #   = 0: No terminated child processes available
            #   < 0: Error (handled by wait4 function)
            var pid = wait4(-1, WNOHANG)

            if pid == 0:
                # No more terminated child processes
                break
            elif pid > 0:
                logger.debug("Reaped zombie child process with PID:", String(pid))
            else:
                # Unexpected negative value (should not happen with our wait4 implementation)
                break
        except e:
            # ECHILD error (no child processes) is normal and expected
            if "ECHILD" in String(e) or "No child processes" in String(e):
                break
            else:
                logger.error("delete_zombies error:", String(e))
                break
