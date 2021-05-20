local telescope = require('telescope')
local utils = require('telescope.utils')
local finders = require('telescope.finders')
local pickers = require('telescope.pickers')
local sorters = require('telescope.sorters')
local actions = require('telescope.actions')
local action_state = require('telescope.actions.state')
local previewers = require('telescope.previewers')

-- TODO: It is better to pass an opts table and allow any additional options for the command
local function get_sessions(format)
    return utils.get_os_command_output({ 'tmux', 'list-sessions', '-F', format })
end

-- TODO: Passing entire opts may not be a good idea since -f can change what windows appear in the table
local function get_windows(opts)
    local sessions = utils.get_os_command_output({ 'tmux', 'list-windows', unpack(opts) })
    return sessions
end

local ns_previewer = vim.api.nvim_create_namespace('telescope-tmux.previewers')

local pane_contents = function(opts)
    local panes = utils.get_os_command_output({'tmux', 'list-panes', '-a', '-F', '#{pane_id}'})
    local current_pane = utils.get_os_command_output({'tmux', 'display-message', '-p', '\\#{pane_id}'})[1]
    local num_history_lines = opts.max_history_lines or 10000
    local results = {}
    for _, pane in ipairs(panes) do
        local contents = utils.get_os_command_output({'tmux', 'capture-pane', '-pJ', '-t', pane, '-S', -num_history_lines})
        for i, line in ipairs(contents) do
            table.insert(results, {pane=pane, line=line, line_num=i})
        end
    end

    pickers.new(opts, {
        prompt_title = 'Tmux Pane Contents',
        finder = finders.new_table {
            results = results,
            entry_maker = function(result)
                return {
                    value = {
                        pane = result.pane,
                        line_num = result.line_num,
                    },
                    display = result.pane .. ": " .. result.line,
                    ordinal = result.line,
                    valid = result.pane ~= current_pane
                }
            end
        },
        sorter = sorters.get_generic_fuzzy_sorter(),
        -- would prefer to use this when https://github.com/neovim/neovim/issues/14557 is fixed.
        --previewer = previewers.new_buffer_previewer({
            --define_preview = function(self, entry, status)
                --local pane = entry.value.pane
                --local line_num = entry.value.line_num
                --local pane_content = utils.get_os_command_output({'tmux', 'capture-pane', '-p', '-t', pane, '-S', -num_history_lines, '-eJ'})
                --local chan_id = vim.api.nvim_open_term(self.state.bufnr, {})
                --vim.fn.chansend(chan_id, pane_content)
            --end
        --}),
        previewer = previewers.new_buffer_previewer({
            define_preview = function(self, entry, status)
                local pane = entry.value.pane
                local line_num = entry.value.line_num
                vim.api.nvim_buf_call(self.state.bufnr, function()
                    local win_id = self.state.winid
                    -- TODO: cache the buffer so we don't recreate buffers when pane_id is the same
                    -- set wrap for the terminal output
                    vim.api.nvim_win_set_option(win_id, "wrap", true)
                    local job_id = vim.fn.termopen(string.format("tmux capture-pane -t \\%s -S %s -eJp", pane, -num_history_lines))
                    -- have to wait for the terminal job to complete before adding highlight
                    vim.fn.jobwait({job_id})
                    pcall(vim.api.nvim_win_set_cursor, win_id, {line_num, 0})
                    vim.cmd("norm! zz")
                    -- TODO: Have noticed some times where highlight is not getting applied, maybe some issue with line numbers
                    vim.api.nvim_buf_add_highlight(self.state.bufnr, ns_previewer, "TelescopePreviewLine", line_num, 0, -1)
                end)
            end,
        }),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                local pane = selection.value.pane
                local line_num = selection.value.line_num
                actions.close(prompt_bufnr)
                vim.api.nvim_command("silent !tmux copy-mode -t \\" .. pane)
                vim.api.nvim_command(string.format('silent !tmux send-keys -t \\%s -X history-top', pane))
                vim.api.nvim_command(string.format('silent !tmux send-keys -t \\%s -X -N %s cursor-down', pane, line_num-1))
                vim.api.nvim_command(string.format('silent !tmux send-keys -t \\%s -X select-line', pane))
                -- pane IDs start with % so have to escape it
                vim.api.nvim_command('silent !tmux switchc -t \\' .. pane)
            end)

            return true
        end
    }):find()
end

local windows = function(opts)
    local window_ids = get_windows({"-a", '-F', '#{window_id}'})
    -- TODO: These should be able to be passed by the user
    local windows_with_user_opts = get_windows({"-a", '-F', '#S: #W'})

    local custom_to_default_map = {}
    for i, v in ipairs(windows_with_user_opts) do
        custom_to_default_map[v] = window_ids[i]
    end

    -- FIXME: This command can display a session name even if you are in a seperate terminal session that isn't using tmux
    local current_window = utils.get_os_command_output({'tmux', 'display-message', '-p', '#{window_id}'})[1]
    local dummy_session_name = "telescope-tmux-previewer"

    local current_client = utils.get_os_command_output({'tmux', 'display-message', '-p', '#{client_tty}'})[1]

    pickers.new(opts, {
        prompt_title = 'Tmux Windows',
        finder = finders.new_table {
            results = windows_with_user_opts,
        },
        sorter = sorters.get_generic_fuzzy_sorter(),
        previewer = previewers.new_buffer_previewer({
            setup = function(self)
                vim.api.nvim_command(string.format("silent !tmux new-session -s %s -d", dummy_session_name))
                return {}
            end,
            define_preview = function(self, entry, status)
                local window_id = custom_to_default_map[entry[1]]
                -- Can't attach to current session otherwise neovim will freak out
                if current_window == window_id then
                    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, {"Currently attached to this window."})
                else
                    vim.api.nvim_buf_call(self.state.bufnr, function()
                        vim.cmd(string.format("silent !tmux link-window -s %s -t %s:0 -kd", window_id, dummy_session_name))
                        -- Need -r here to prevent resizing the window to fix in the preview buffer
                        vim.fn.termopen(string.format("tmux attach -t %s -r", dummy_session_name))
                    end)
                end
            end,
            teardown = function(self)
                vim.api.nvim_command(string.format("silent !tmux kill-session -t %s", dummy_session_name))
            end
        }),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                local selected_window_id = custom_to_default_map[selection.value]
                -- If we don't unlink the window before switching the client, the session will detach if the
                -- selected window is in the current session. I don't know why.
                vim.cmd('silent !tmux unlink-window -t ' .. selected_window_id)
                vim.cmd(string.format('silent !tmux switchc -t %s -c %s', selected_window_id, current_client))
                actions.close(prompt_bufnr)
            end)
            actions.close:enhance({
                post = function ()
                    if opts.quit_on_select then
                        vim.cmd('q!')
                    end
                end
            })
            return true
        end
    }):find()
end


local sessions = function(opts)
    -- TODO: Use session IDs instead of names
    local session_names = get_sessions('#S')
    local user_formatted_session_names = get_sessions(opts.format or '#S')
    local formatted_to_real_session_map = {}
    for i, v in ipairs(user_formatted_session_names) do
        formatted_to_real_session_map[v] = session_names[i]
    end

    -- FIXME: This command can display a session name even if you are in a seperate terminal session that isn't using tmux
    local current_session = utils.get_os_command_output({'tmux', 'display-message', '-p', '#S'})[1]
    local current_client = utils.get_os_command_output({'tmux', 'display-message', '-p', '#{client_tty}'})[1]

    pickers.new(opts, {
        prompt_title = 'Tmux Sessions',
        finder = finders.new_table {
            results = user_formatted_session_names
        },
        sorter = sorters.get_generic_fuzzy_sorter(),
        previewer = previewers.new_buffer_previewer({
            define_preview = function(self, entry, status)
                local session_name = formatted_to_real_session_map[entry[1]]
                -- Can't attach to current session otherwise neovim will freak out
                if current_session == session_name then
                    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, {"Currently attached to this session."})
                else
                    vim.api.nvim_buf_call(self.state.bufnr, function()
                        vim.fn.termopen(string.format("tmux attach -t %s -r", session_name))
                    end)
                end
            end
        }),
        attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
                local selection = action_state.get_selected_entry()
                vim.cmd(string.format('silent !tmux switchc -t %s -c %s', selection.value, current_client))
                actions.close(prompt_bufnr)
            end)

            actions.close:enhance({
                post = function ()
                    if opts.quit_on_select then
                        vim.cmd('q!')
                    end
                end
            })

            return true
        end,
    }):find()
end

return telescope.register_extension {
    exports = {
        sessions = sessions,
        windows = windows,
        pane_contents = pane_contents
    }
}
