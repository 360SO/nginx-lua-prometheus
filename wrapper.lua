-- Copyright (C) by Jiang Yang (jiangyang-pd@360.cn)

local _M = { _VERSION = "0.0.1" }

_M.CONF = {
    initted = false,
    app = "default",
    idc = "",
    counter_path = {},
    histogram_path = {},
    log_method = {},
    buckets = {10,11,12,14,16,18,20,23,26,29,33,37,42,47,53,60,67,75,84,95,107,120,135,152,171,192,216,243,273,307,345,388,437,492,554,623,701,789,888,1000}
}

local function inTable(needle, table_name)
    if type(needle) ~= "string" or type(table_name) ~= "table" then
        return false
    end
    for _, v in ipairs(table_name) do
        if v == needle then
            return true
        end
    end
    return false
end

function _M:init(user_config)
    for k, v in pairs(user_config) do
        if k == "app" then
            if type(v) ~= "string" then
                return nil, '"app" must be a string'
            end
            self.CONF.app = v
        elseif k == "idc" then
            if type(v) ~= "string" then
                return nil, '"idc" must be a string'
            end
            self.CONF.idc = v
        elseif k == "counter_path" then
            if type(v) ~= "table" then
                return nil, '"counter_path" must be a table'
            end
            self.CONF.counter_path = v
        elseif k == "histogram_path" then
            if type(v) ~= "table" then
                return nil, '"histogram_path" must be a table'
            end
            self.CONF.histogram_path = v
        elseif k == "log_method" then
            if type(v) ~= "table" then
                return nil, '"log_method" must be a table'
            end
            self.CONF.log_method = v
        elseif k == "buckets" then
            if type(v) ~= "table" then
                return nil, '"buckets" must be a table'
            end
            self.CONF.buckets = v
        end
    end

    if true then
        self.CONF.initted = true
    end

    local config = ngx.shared.prometheus_metrics
    config:flush_all()

    prometheus = require("prometheus.prometheus").init("prometheus_metrics")

    -- QPS
    metric_requests = prometheus:counter(
        "module_responses", 
        "[" .. self.CONF.idc .. "] number of /path", 
        {"app", "api", "module", "method", "code"}
    )

    -- 流量
    metric_traffic = prometheus:counter(
        "module_sent_bytes",
        "[" .. self.CONF.idc .. "] traffic of /path",
        {"app", "api", "module", "method", "code"}
    )

    -- 延迟
    metric_latency = prometheus:histogram(
        "response_duration_milliseconds",
        "[" .. self.CONF.idc .. "] http request latency", 
        {"app", "api", "module", "method"},
        self.CONF.buckets
    )

    -- 状态
    metric_connections = prometheus:gauge(
        "module_connections",
        "[" .. self.CONF.idc .. "] number of http connections", 
        {"app", "state"}
    )

    return self.CONF.initted
end

function _M:log()
    if not self.CONF.initted then
        return nil, "init first.."
    end

    local path = ""
    local method = ngx.var.request_method or ""
    local request_uri = ngx.var.request_uri or ""
    local status = ngx.var.status or ""

    local pathInCounter = false
    local pathInHistogram = false

    if not request_uri or not method then
        return nil, "empty request_uri|method"
    end

    local st, sp = string.find(request_uri, "?")
    if st == nil then
        path = request_uri
    else
        path = string.sub(request_uri, 1, st-1)
    end

    path = string.lower(path)
    pathInCounter = inTable(path, self.CONF.counter_path)
    pathInHistogram = inTable(path, self.CONF.histogram_path)

    if (pathInCounter or pathInHistogram) and inTable(method, self.CONF.log_method) then
        if pathInCounter then
            metric_requests:inc(1, {self.CONF.app, path, "self", method, status})
            metric_traffic:inc(tonumber(ngx.var.bytes_sent), {self.CONF.app, path, "self", method, status})
        end

        if pathInHistogram then
            local tm = (ngx.now() - ngx.req.start_time()) * 1000
            metric_latency:observe(tm, {self.CONF.app, path, "self", method})
        end
    end

    return true
end

function _M:metrics()
    local ip = ngx.var.remote_addr or ""
    local st, sp = string.find(ip, ".", 1, true)
    local sub_ip = ip
    if st == nil then
        sub_ip = ip
    else
        sub_ip = string.sub(ip, 1, st-1)
    end

    if sub_ip ~= '10' and sub_ip ~= '172' then
        ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    if not self.CONF.initted then
        ngx.say("init first..")
        ngx.exit(ngx.HTTP_OK)
    end

    if ngx.var.connections_reading and ngx.var.connections_waiting and ngx.var.connections_writing then
        metric_connections:set(ngx.var.connections_reading, {self.CONF.app, "reading"})
        metric_connections:set(ngx.var.connections_waiting, {self.CONF.app, "waiting"})
        metric_connections:set(ngx.var.connections_writing, {self.CONF.app, "writing"})
    end
    
    prometheus:collect()
end

return _M
