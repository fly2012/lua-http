local monotime = require "cqueues".monotime
local ca = require "cqueues.auxlib"
local cs = require "cqueues.socket"
local cqueues_dns_record = require "cqueues.dns.record"
local http_tls = require "http.tls"
local http_util = require "http.util"
local connection_common = require "http.connection_common"
local onerror = connection_common.onerror
local new_h1_connection = require "http.h1_connection".new
local new_h2_connection = require "http.h2_connection".new
local openssl_ssl = require "openssl.ssl"
local openssl_ctx = require "openssl.ssl.context"
local openssl_verify_param = require "openssl.x509.verify_param"

-- Create a shared 'default' TLS context
local default_ctx = http_tls.new_client_context()

local function negotiate(s, options, timeout)
	s:onerror(onerror)
	local tls = options.tls
	local version = options.version
	if tls then
		local ctx = options.ctx or default_ctx
		local ssl = openssl_ssl.new(ctx)
		local host = options.host
		local host_is_ip = host and http_util.is_ip(host)
		local sendname = options.sendname
		if sendname == nil and not host_is_ip and host then
			sendname = host
		end
		if sendname then -- false indicates no sendname wanted
			ssl:setHostName(sendname)
		end
		if http_tls.has_alpn then
			if version == nil then
				ssl:setAlpnProtos({"h2", "http/1.1"})
			elseif version == 1.1 then
				ssl:setAlpnProtos({"http/1.1"})
			elseif version == 2 then
				ssl:setAlpnProtos({"h2"})
			end
		end
		if version == 2 then
			ssl:setOptions(openssl_ctx.OP_NO_TLSv1 + openssl_ctx.OP_NO_TLSv1_1)
		end
		if host and http_tls.has_hostname_validation then
			local params = openssl_verify_param.new()
			if host_is_ip then
				params:setIP(host)
			else
				params:setHost(host)
			end
			-- Allow user defined params to override
			local old = ssl:getParam()
			old:inherit(params)
			ssl:setParam(old)
		end
		local ok, err, errno = s:starttls(ssl, timeout)
		if not ok then
			return nil, err, errno
		end
	end
	if version == nil then
		local ssl = s:checktls()
		if ssl then
			if http_tls.has_alpn and ssl:getAlpnSelected() == "h2" then
				version = 2
			else
				version = 1.1
			end
		else
			-- TODO: attempt upgrading http1 to http2
			version = 1.1
		end
	end
	if version < 2 then
		return new_h1_connection(s, "client", version)
	elseif version == 2 then
		return new_h2_connection(s, "client", options.h2_settings)
	else
		error("Unknown HTTP version: " .. tostring(version))
	end
end

-- `type` parameter is what sort of records you want to find could be "A" or
-- "AAAA" or `nil` if you want to filter yourself e.g. to implement
-- https://www.ietf.org/archive/id/draft-vavrusa-dnsop-aaaa-for-free-00.txt
local function each_matching_record(pkt, name, type)
	-- First need to do CNAME chasing
	local params = {
		section = "answer";
		class = cqueues_dns_record.IN;
		type = cqueues_dns_record.CNAME;
		name = name .. ".";
	}
	for _=1, 8 do -- avoid cname loops
		-- Ignores any CNAME record past the first (which should never occur anyway)
		local func, state, first = pkt:grep(params)
		local record = func(state, first)
		if record == nil then
			-- Not found
			break
		end
		params.name = record:host()
	end
	params.type = type
	return pkt:grep(params)
end

local function dns_lookup(records, dns_resolver, host, query_type, filter_type, timeout)
	local packet = dns_resolver:query(host, query_type, nil, timeout)
	if not packet then
		return
	end
	for rec in each_matching_record(packet, host, filter_type) do
		local t = rec:type()
		if t == cqueues_dns_record.AAAA or t == cqueues_dns_record.A then
			table.insert(records, rec)
		end
	end
end

local function connect(options, timeout)
	local family = options.family
	local path = options.path
	local host = options.host
	if not path and not http_util.is_ip(host) then
		local dns_resolver = options.dns_resolver
		if dns_resolver then
			local deadline = timeout and monotime()+timeout
			local records = {}
			if family == nil or family == cs.AF_UNSPEC then
				dns_lookup(records, dns_resolver, host, cqueues_dns_record.AAAA, nil, timeout)
				dns_lookup(records, dns_resolver, host, cqueues_dns_record.A, nil, deadline and deadline-monotime())
			elseif family == cs.AF_INET then
				dns_lookup(records, dns_resolver, host, cqueues_dns_record.A, cqueues_dns_record.A, timeout)
			elseif family == cs.AF_INET6 then
				dns_lookup(records, dns_resolver, host, cqueues_dns_record.AAAA, cqueues_dns_record.AAAA, timeout)
			end
			local rec = records[1]
			if not rec then
				return nil, "The name does not resolve for the supplied parameters"
			end
			host = rec:addr()
			timeout = deadline and deadline-monotime()
		end
	end

	local bind = options.bind
	if bind ~= nil then
		assert(type(bind) == "string")
		local bind_address, bind_port = bind:match("^(.-):(%d+)$")
		if bind_address then
			bind_port = tonumber(bind_port, 10)
		else
			bind_address = bind
		end
		local ipv6 = bind_address:match("^%[([:%x]+)%]$")
		if ipv6 then
			bind_address = ipv6
		end
		bind = {
			address = bind_address;
			port = bind_port;
		}
	end

	local s, err, errno = ca.fileresult(cs.connect {
		family = family;
		host = host;
		port = options.port;
		path = path;
		bind = bind;
		sendname = false;
		v6only = options.v6only;
		nodelay = true;
	})
	if s == nil then
		return nil, err, errno
	end
	return negotiate(s, options, timeout)
end

return {
	negotiate = negotiate;
	connect = connect;
}
