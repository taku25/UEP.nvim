local M = {}

-- UEP file watcher is now handled by UNL Server (Rust) via :UNL watch or :UNL start.
-- This module is kept as a stub for backward compatibility.

function M.start()
    -- No-op: Rust server handles watching.
end

function M.stop()
    -- No-op.
end

function M.is_running()
    return false
end

return M