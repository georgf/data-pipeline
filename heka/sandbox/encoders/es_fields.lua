-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

--[[
Elasticsearch encoder to index only specific fields.

Config:

- index (string, optional, default "heka-%{%Y.%m.%d}")
    String to use as the `_index` key's value in the generated JSON. Supports
    field interpolation as described below.
- type_name (string, optional, default "message")
    String to use as the `_type` key's value in the generated JSON. Supports
    field interpolation as described below.
- id (string, optional)
    String to use as the `_id` key's value in the generated JSON. Supports
    field interpolation as described below.
- es_index_from_timestamp (boolean, optional)
    If true, then any time interpolation (often used to generate the
    ElasticSeach index) will use the timestamp from the processed message
    rather than the system time.
- fields (string, required)
    JSON array of fields to index.

Field interpolation:

    Data from the current message can be interpolated into any of the string
    arguments listed above. A `%{}` enclosed field name will be replaced by
    the field value from the current message. Supported default field names
    are "Type", "Hostname", "Pid", "UUID", "Logger", "EnvVersion", and
    "Severity". Any other values will be checked against the defined dynamic
    message fields. If no field matches, then a `C strftime
    <http://man7.org/linux/man-pages/man3/strftime.3.html>`_ (on non-Windows
    platforms) or `C89 strftime <http://msdn.microsoft.com/en-
    us/library/fe06s4ak.aspx>`_ (on Windows) time substitution will be
    attempted.

*Example Heka Configuration*

.. code-block:: ini

    [es_fields]
    type = "SandboxEncoder"
    filename = "lua_encoders/es_fields.lua"
        [es_fields.config]
        es_index_from_timestamp = true
        index = "%{Logger}-%{%Y.%m.%d}"
        type_name = "%{Type}-%{Hostname}"
        fields = '["Payload", "Fields[docType]"]'

    [ElasticSearchOutput]
    message_matcher = "Type == 'mytype'"
    encoder = "es_fields"

*Example Output*

.. code-block:: json

    {"index":{"_index":"mylogger-2014.06.05","_type":"mytype-host.domain.com"}}
    {"Payload":"data","docType":"main"}

--]]

require "cjson"
require "string"
require "os"
require "math"
local elasticsearch = require "elasticsearch"

local ts_from_message = read_config("es_index_from_timestamp")
local index = read_config("index") or "heka-%{%Y.%m.%d}"
local type_name = read_config("type_name") or "message"
local id = read_config("id")
local fields = cjson.decode(read_config("fields") or error("fields must be specified"))

local interp_fields = {
    Type = "Type",
    Hostname = "Hostname",
    Pid = "Pid",
    UUID = "Uuid",
    Logger = "Logger",
    EnvVersion = "EnvVersion",
    Severity = "Severity",
    Timestamp = "Timestamp",
    Logger = "Logger"
}

local info_fields = {
    "sessionId"
  , "subsessionId"
  , "previousSessionId"
  , "previousSubsessionId"
  , "subsessionCounter"
  , "profileSubsessionCounter"
  , "sessionStartDate"
  , "subsessionStartDate"
  , "subsessionLength"
  , "sessionLength"
}

local environment_fields = {
    "telemetryEnabled"
}

local static_fields = {}
local dynamic_fields = {}

local function key(str)
    return str:match("Fields%[(.+)%]") or error("invalid field name: " .. str)
end

for i, field in ipairs(fields) do
    local fname = interp_fields[field]
    if fname then
        static_fields[#static_fields+1] = field
    else
        dynamic_fields[#dynamic_fields+1] = key(field)
    end
end

function process_message()
    local ns
    if ts_from_message then
        ns = read_message("Timestamp")
    end

    local idx_json = elasticsearch.bulkapi_index_json(index, type_name, id, ns)

    local tbl = {}
    for i, field in ipairs(static_fields) do
        if field == "Timestamp" then
            tbl[field] = os.date("!%Y-%m-%dT%XZ", ns and ns / 1e9)
        else
            tbl[field] = read_message(field)
        end
    end

    for i, field in ipairs(dynamic_fields) do
        local f = string.format("Fields[%s]", field)
        local z = 0
        local v = read_message(f, nil, z)
        while v do
            if z == 0 then
                tbl[field] = v
            elseif z == 1 then
                tbl[field] = {tbl[field], v}
            elseif z > 1 then
                tbl[field][#tbl[field]+1] = v
            end
            z = z + 1
            v = read_message(f, nil, z)
        end
    end
    local ok, info = pcall(cjson.decode, read_message("Fields[payload.info]"))
    if ok then
        for i, k in ipairs(info_fields) do
            if info[k] then
                tbl[k] = info[k]
            end
        end
    end

    local ok, info = pcall(cjson.decode, read_message("Fields[environment.settings]"))
    if ok then
        for i, k in ipairs(environment_fields) do
            if info[k] then
                tbl[k] = info[k]
            end
        end
    end

    local ok, payload = pcall(cjson.decode, read_message("Payload"))
    if ok and type(payload.application) == "table" and payload.application.architecture then
        tbl.architecture = payload.application.architecture
    end

    if tbl.creationTimestamp then
        if ns then tbl.Latency = math.floor((ns - tbl.creationTimestamp) / 1e9) end
        tbl.creationTimestamp = os.date("!%Y-%m-%dT%XZ", tbl.creationTimestamp / 1e9)
    end

    add_to_payload(idx_json, "\n", cjson.encode(tbl), "\n")
    inject_payload()
    return 0
end
