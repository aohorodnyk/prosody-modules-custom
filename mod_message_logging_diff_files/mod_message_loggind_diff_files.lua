module:set_global();

local jid_bare = require "util.jid".bare;
local jid_split = require "util.jid".split;

local stat, mkdir = require "lfs".attributes, require "lfs".mkdir;

-- Get a filesystem-safe string
local function fsencode_char(c)
	return ("%%%02x"):format(c:byte());
end
local function fsencode(s)
	return (s:gsub("[^%w._-@]", fsencode_char):gsub("^%.", "_"));
end

local log_base_path = module:get_option("message_logging_dir", prosody.paths.data.."/message_logs");
mkdir(log_base_path);

local function get_host_path(host)
	return log_base_path.."/"..fsencode(host);
end

local function get_log_path(local_user, remote_user)
	local username, host = jid_split(local_user);
	local base = get_host_path(host)..os.date("/%Y-%m-%d").."/"..fsencode(username);
	if not stat(base) then
        os.execute( "mkdir -p "..base );
	end
	return base.."/"..fsencode(remote_user)..".msglog";
end

function open_files_mt(local_user, remote_user)
    local log_path = get_log_path(local_user, remote_user);
    local f, err = io.open(log_path, "a+");
    if not f then
        module:log("error", "Failed to open message log for writing [%s]: %s", log_path, err);
    end
    return f;
end

-- [user@host_user2@host] = filehandle
local open_files = {}

function open_file(local_user, remote_user)
    local key = local_user.."_"..remote_user;
    local f = open_files_mt(local_user, remote_user);
    open_files[key] = f;
    return f;
end

function close_open_files()
	module:log("debug", "Closing all open files");
	for jids, filehandle in pairs(open_files) do
		filehandle:close();
		open_files[jids] = nil;
	end
end
module:hook_global("logging-reloaded", close_open_files);

local function handle_incoming_message(event)
	local origin, stanza = event.origin, event.stanza;
	local message_type = stanza.attr.type;

	if message_type == "error" then return; end

	local from, to = jid_bare(stanza.attr.from), jid_bare(stanza.attr.to);
	local body = stanza:get_child("body");
	if not body then return; end
	body = body:get_text();

	local f = open_file(to, from);
	if not f then return; end
	if message_type == "groupchat" then
		-- Add the nickname
		from = from.." <"..(select(3, jid_split(stanza.attr.from)) or "")..">";
	end
	body = body:gsub("\n", "\n    "); -- Indent newlines
	f:write("RECV: ", from, ": ", body, "\n");
	f:flush();
end

local function handle_outgoing_message(event)
	local origin, stanza = event.origin, event.stanza;
	local message_type = stanza.attr.type;

	if message_type == "error" or message_type == "groupchat" then return; end

	local from, to = jid_bare(stanza.attr.from), jid_bare(stanza.attr.to);
	local body = stanza:get_child("body");
	if not body then return; end
	body = body:get_text();

	local f = open_file(from, to);
	if not f then return; end
	body = body:gsub("\n", "\n    "); -- Indent newlines
	f:write("SEND: ", to, ": ", body, "\n");
	f:flush();
end



function module.add_host(module)
	local host_base_path = get_host_path(module.host);
	if not stat(host_base_path) then
		mkdir(host_base_path);
	end

	module:hook("message/bare", handle_incoming_message, 1);
	module:hook("message/full", handle_incoming_message, 1);

	module:hook("pre-message/bare", handle_outgoing_message, 1);
	module:hook("pre-message/full", handle_outgoing_message, 1);
	module:hook("pre-message/host", handle_outgoing_message, 1);

end

function module.command(arg)
	local command = table.remove(arg, 1);
	if command == "path" then
		print(get_log_path(arg[1]));
	else
		io.stderr:write("Unrecognised command: ", command);
		return 1;
	end
	return 0;
end

function module.save()
	return { open_files = open_files };
end

function module.restore(saved)
	open_files = saved.open_files or {};
end
