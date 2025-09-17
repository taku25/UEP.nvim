-- lua/UEP/hub.lua (修正版)

local unl_events = require("UNL.event.events")
local unl_event_types = require("UNL.event.types")

local M = {}

M.setup = function()
  local uep_log = require("UEP.logger").get()

  local function handle_file_change(event_type, payload)
    if not (payload and payload.status == "success" and payload.module) then return end

    local module_name = payload.module.name
    uep_log.info("Detected file change in module '%s'. Triggering lightweight cache update.", module_name)
    
    -- (payloadの組み立てロジックは変更なし)
    local source_file, header_file, old_source_file, old_header_file = nil, nil, nil, nil
    if event_type == "new" or event_type == "delete" then
      source_file = payload.source_path; header_file = payload.header_path
    elseif event_type == "rename" then
      source_file = payload.new_class_name.cpp; header_file = payload.new_class_name.h
      old_source_file = payload.old_class_name.cpp; old_header_file = payload.old_class_name.h
    elseif event_type == "move" then
      source_file = payload.operations[1].new; header_file = payload.operations[2].new
      old_source_file = payload.operations[1].old; old_header_file = payload.operations[2].old
    end

    -- ▼▼▼ 修正点: requireするパスを新しいものに変更 ▼▼▼
    require("UEP.cmd.core.refresh_files").update_single_module_cache(module_name, function(ok)
      if ok then
        uep_log.info("Lightweight cache update for module '%s' succeeded.", module_name)
        unl_events.publish(unl_event_types.ON_AFTER_UEP_LIGHTWEIGHT_REFRESH, {
          status = "success", event_type = event_type, source_file = source_file,
          header_file = header_file, old_source_file = old_source_file, old_header_file = old_header_file,
          updated_module = module_name,
        })
      end
    end)
    -- ▲▲▲ ここまで ▲▲▲
  end

  local function handle_directory_change(payload)
    if not (payload and payload.status == "success" and payload.module) then return end
    -- ▼▼▼ 修正点: requireするパスを新しいものに変更 ▼▼▼
    require("UEP.cmd.core.files").update_single_module_cache(payload.module.name, function(ok)
      if ok then
        unl_events.publish(unl_event_types.ON_AFTER_UEP_LIGHTWEIGHT_REFRESH, {
          event_type = payload.type,
          updated_module = payload.module.name,
        })
      end
    end)
    -- ▲▲▲ ここまで ▲▲▲
  end

  unl_events.subscribe(unl_event_types.ON_AFTER_NEW_CLASS_FILE, function(p) handle_file_change("new", p) end)
  unl_events.subscribe(unl_event_types.ON_AFTER_DELETE_CLASS_FILE, function(p) handle_file_change("delete", p) end)
  unl_events.subscribe(unl_event_types.ON_AFTER_RENAME_CLASS_FILE, function(p) handle_file_change("rename", p) end)
  unl_events.subscribe(unl_event_types.ON_AFTER_MOVE_CLASS_FILE, function(p) handle_file_change("move", p) end)
  unl_events.subscribe(unl_event_types.ON_AFTER_MODIFY_DIRECTORY, handle_directory_change)
end

return M
