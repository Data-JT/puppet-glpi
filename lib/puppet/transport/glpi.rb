# frozen_string_literal: true

require 'net/http'
require 'json'
require 'openssl'
require 'uri'

# @api private
module Puppet::Transport; end

# HTTP/OAuth client for the GLPI 11 high-level REST API (API v2).
#
# Like the other internal clients of this kind it is intentionally NOT a
# registered Resource API transport (no schema, no verify/facts/close); the
# providers build it from the connection settings Puppet manages on the agent.
#
# URL convention: +base_url+ is the API root, e.g. +https://glpi.example.com/api.php+.
# * The OAuth token endpoint is +<base_url>/token+ (unversioned, as published
#   in GLPI's OpenAPI document).
# * Callers pass resource paths such as +/Assets/Computer+; the transport
#   prepends the version prefix, so requests go to +<base_url>/v2/Assets/Computer+.
#
# Recognized connection_info keys:
#   :base_url       (required) API root, see above
#   :client_id      (required) OAuth client id
#   :client_secret  (required) OAuth client secret (String or Sensitive)
#   :username       (required for grant_type 'password')
#   :password       (required for grant_type 'password'; String or Sensitive)
#   :grant_type     'password' (default) or 'client_credentials'
#   :ssl_verify     verify the TLS certificate, default true
#   :ssl_ca_file    CA bundle used when ssl_verify is true
#   :timeout        open/read timeout in seconds, default 60
#
# Tokens are cached in memory per instance and per OAuth scope, and refreshed
# when they expire and once on an HTTP 401. REST calls use the scope +api+;
# {#graphql} uses its own token with the scope +graphql+, requested only when
# GraphQL is used, so a client without that scope still works for everything
# else. One connection is kept open and reused for all requests. Idempotent
# GET requests are retried (at most twice) on 5xx responses and network
# timeouts.
class Puppet::Transport::Glpi
  API_VERSION_PREFIX = '/v2'
  TOKEN_PATH         = '/token'
  DEFAULT_TIMEOUT    = 60
  DEFAULT_PAGE_SIZE  = 100
  MAX_GET_RETRIES    = 2
  MAX_PAGES          = 10_000
  DEFAULT_TOKEN_TTL  = 300
  # Seconds before the advertised expiry at which a token counts as stale.
  TOKEN_LEEWAY       = 30
  GRANT_TYPES        = ['password', 'client_credentials'].freeze
  REST_SCOPE         = 'api'
  GRAPHQL_SCOPE      = 'graphql'
  GRAPHQL_PATH       = '/GraphQL/'
  # A GraphQL type name, and a selection set of field names and braces.
  GRAPHQL_NAME       = %r{\A[A-Za-z_][A-Za-z0-9_]*\z}
  GRAPHQL_SELECTION  = %r{\A[A-Za-z0-9_{}\s]+\z}
  # A filter of one comparison (e.g. itemtype==Computer): field path,
  # operator, a value of name characters and backslashes (namespaced
  # itemtypes). No quote or whitespace can reach the query.
  GRAPHQL_FILTER     = %r{\A[A-Za-z_][A-Za-z0-9_.]*(?:==|!=)[A-Za-z0-9_.\\-]+\z}
  USER_AGENT         = 'puppet-glpi'
  # A kept-alive socket idle for longer is replaced before use: servers close
  # idle connections after a few seconds, and a POST must not meet that race.
  IDLE_REUSE_LIMIT   = 4
  CONNECTION_FAILURES = [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, Errno::ECONNRESET,
                         Errno::EPIPE, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT,
                         SocketError, IOError, OpenSSL::SSL::SSLError].freeze

  # Raised for any failed API call. The message carries the HTTP status,
  # method, path and GLPI's own error title/detail; never request bodies or
  # credentials.
  class ApiError < Puppet::ResourceError
    attr_reader :status, :path

    def initialize(message, status: nil, path: nil)
      super(message)
      @status = status
      @path   = path
    end
  end

  # A request that timed out; retried for GET, otherwise surfaced as ApiError.
  class TimeoutError < ApiError; end

  class << self
    attr_accessor :ssl_warning_emitted
  end

  def initialize(context, connection_info)
    @base_url      = connection_info[:base_url].to_s.chomp('/')
    @client_id     = connection_info[:client_id]
    @client_secret = unwrap(connection_info[:client_secret])
    @username      = connection_info[:username]
    @password      = unwrap(connection_info[:password])
    @grant_type    = (connection_info[:grant_type] || 'password').to_s
    @ssl_verify    = connection_info[:ssl_verify] != false
    @ssl_ca_file   = connection_info[:ssl_ca_file]
    @timeout       = connection_info[:timeout] || DEFAULT_TIMEOUT
    @tokens        = {}
    @http_lock     = Mutex.new
    @http          = nil

    validate_connection_info!

    unless @ssl_verify || self.class.ssl_warning_emitted
      context.warning('SSL certificate verification is disabled for the GLPI API')
      self.class.ssl_warning_emitted = true
    end
    context.debug('Initialized GLPI transport')
  end

  # Keeps credentials out of logs and exception dumps.
  def inspect
    "#<#{self.class.name} #{@base_url}>"
  end
  alias to_s inspect

  # Closes the kept-alive connection; the next request opens a new one.
  def close
    @http_lock.synchronize { close_connection }
  end

  def get(context, path, query = nil)
    request(context, Net::HTTP::Get, path, query: query)
  end

  # Reads every item of a collection, following +start+/+limit+ pagination.
  # GLPI may answer a page with a +Content-Range: <first>-<last>/<total>+
  # header. With a total, reading stops once +start+ reaches it. Without one,
  # only an empty page ends the iteration: a short page is no signal, since
  # the server may cap the page size below the requested +limit+. A server
  # that ignores +start+ (the same page again) raises instead of looping.
  # Items are requested sorted by id (unless the caller passes +sort+): an
  # unsorted collection has no stable order across pages, so an item could
  # be read twice or not at all.
  def get_all(context, path, query = {})
    query = { sort: 'id' }.merge((query || {}).transform_keys(&:to_sym))
    limit = query.key?(:limit) ? query[:limit] : DEFAULT_PAGE_SIZE
    unless limit.is_a?(Integer) && limit.positive?
      raise Puppet::ResourceError, "GLPI get_all limit must be a positive Integer, got #{limit.inspect}"
    end
    start = (query[:start] || 0).to_i
    items = []
    previous = nil

    MAX_PAGES.times do
      response = request(context, Net::HTTP::Get, path, query: query.merge(start: start, limit: limit), raw: true)
      page = parse_json(response, path)
      unless page.is_a?(Array)
        raise ApiError.new("GLPI API returned a non-list response on GET #{path} (expected a collection)",
                           status: response.code.to_i, path: path)
      end
      return items if page.empty?
      if page == previous
        raise ApiError.new("GLPI API ignored the pagination offset on GET #{path} (same page returned twice)",
                           status: response.code.to_i, path: path)
      end
      items.concat(page)
      previous = page
      start += page.size
      total = content_range_total(response['Content-Range'])
      return items if total && start >= total
    end
    raise ApiError.new("GLPI pagination on GET #{path} exceeded #{MAX_PAGES} pages", path: path)
  end

  def post(context, path, body)
    request(context, Net::HTTP::Post, path, body: body)
  end

  def patch(context, path, body)
    request(context, Net::HTTP::Patch, path, body: body)
  end

  # A DELETE resent on a fresh connection (see #perform) after the first
  # one was written may meet the object already gone: that 404 counts as
  # done. A 404 on a DELETE sent once still raises.
  def delete(context, path, query = nil)
    request(context, Net::HTTP::Delete, path, query: query)
    nil
  rescue ApiError => error
    raise unless error.status == 404 && @last_request_resent

    context.debug("GLPI API DELETE #{path}: 404 after a resend; the first request deleted it")
    nil
  end

  # Runs a GraphQL query (POST /GraphQL/, scope +graphql+) and returns its
  # +data+. A response carrying +errors+ raises ApiError with their messages.
  def graphql(context, query)
    result = request(context, Net::HTTP::Post, GRAPHQL_PATH, body: { query: query }, scope: GRAPHQL_SCOPE)
    errors = result.is_a?(Hash) ? Array(result['errors']) : []
    unless errors.empty?
      messages = errors.map { |error| error.is_a?(Hash) ? error['message'].to_s : error.to_s }.join('; ')
      raise ApiError.new("GLPI GraphQL error on #{type_hint(query)}: #{messages}", status: 200, path: GRAPHQL_PATH)
    end
    data = result.is_a?(Hash) ? result['data'] : nil
    raise ApiError.new('GLPI GraphQL response carries no data', status: 200, path: GRAPHQL_PATH) unless data.is_a?(Hash)

    data
  end

  # Every object of the GraphQL type +type_name+ with the fields in
  # +selection+ (e.g. +'id name parent { id }'+), sorted by id and read in
  # pages of +limit+ until an empty page. +filter+ (optional, one
  # comparison such as +'itemtype==Computer'+) is passed with every page;
  # a backslash in it is escaped for the GraphQL string literal. GLPI
  # ignores GraphQL variables, so the arguments are written into the
  # query; type, selection and filter are validated, never user input.
  def graphql_all(context, type_name, selection, limit: DEFAULT_PAGE_SIZE, filter: nil)
    validate_graphql!(type_name, selection, limit)
    arguments = graphql_filter_argument(filter)
    items = []
    previous = nil
    start = 0
    MAX_PAGES.times do
      page = graphql(context, "{ #{type_name}(start: #{start}, limit: #{limit}, sort: \"id\"#{arguments}) { #{selection.strip} } }")[type_name]
      raise ApiError.new("GLPI GraphQL returned no list for #{type_name}", status: 200, path: GRAPHQL_PATH) unless page.is_a?(Array)
      return items if page.empty?
      if page == previous
        raise ApiError.new("GLPI GraphQL ignored the pagination offset for #{type_name} (same page returned twice)",
                           status: 200, path: GRAPHQL_PATH)
      end
      items.concat(page)
      previous = page
      start += page.size
    end
    raise ApiError.new("GLPI GraphQL pagination for #{type_name} exceeded #{MAX_PAGES} pages", path: GRAPHQL_PATH)
  end

  private

  def unwrap(value)
    value.respond_to?(:unwrap) ? value.unwrap : value
  end

  def graphql_filter_argument(filter)
    return '' if filter.nil?
    raise Puppet::ResourceError, "invalid GraphQL filter #{filter.inspect}" unless filter.is_a?(String) && filter.match?(GRAPHQL_FILTER)

    ", filter: \"#{filter.gsub('\\') { '\\\\' }}\""
  end

  def validate_graphql!(type_name, selection, limit)
    unless type_name.is_a?(String) && type_name.match?(GRAPHQL_NAME)
      raise Puppet::ResourceError, "invalid GraphQL type name #{type_name.inspect}"
    end
    depth = 0
    balanced = selection.is_a?(String) && selection.match?(GRAPHQL_SELECTION) && selection.each_char.all? do |char|
      depth += 1 if char == '{'
      depth -= 1 if char == '}'
      depth >= 0
    end
    raise Puppet::ResourceError, "invalid GraphQL selection #{selection.inspect}" unless balanced && depth.zero?
    return if limit.is_a?(Integer) && limit.positive?

    raise Puppet::ResourceError, "GLPI graphql_all limit must be a positive Integer, got #{limit.inspect}"
  end

  # The first field name of a query, for error messages (never the query).
  def type_hint(query)
    query.to_s[%r{[A-Za-z_][A-Za-z0-9_]*}] || 'query'
  end

  def validate_connection_info!
    unless GRANT_TYPES.include?(@grant_type)
      raise Puppet::ResourceError, "GLPI transport grant_type must be one of #{GRANT_TYPES.join(', ')}"
    end
    required = { base_url: @base_url, client_id: @client_id, client_secret: @client_secret }
    required.update(username: @username, password: @password) if @grant_type == 'password'
    required.each do |key, value|
      next unless value.nil? || value.to_s.empty?
      raise Puppet::ResourceError, "GLPI transport connection info is missing required key '#{key}' (or it is empty)"
    end
    @client_secret = @client_secret.to_s
    @password      = @password.to_s if @password
  end

  # --- authentication -------------------------------------------------------

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def access_token(context, scope = REST_SCOPE)
    token, expires_at = @tokens[scope]
    return token if token && expires_at && now < expires_at
    @tokens.delete(scope)
    fetch_token(context, scope)
  end

  def fetch_token(context, scope = REST_SCOPE)
    form = { 'grant_type' => @grant_type, 'client_id' => @client_id,
             'client_secret' => @client_secret, 'scope' => scope }
    form.update('username' => @username, 'password' => @password) if @grant_type == 'password'

    uri = URI("#{@base_url}#{TOKEN_PATH}")
    req = Net::HTTP::Post.new(uri)
    apply_headers(req)
    req['Content-Type'] = 'application/x-www-form-urlencoded'
    req.body = URI.encode_www_form(form)

    context.debug('Requesting GLPI OAuth token')
    response = perform(req, uri, 'POST', TOKEN_PATH, safe_to_resend: true)
    raise_api_error(response, 'POST', TOKEN_PATH) unless response.code.to_i.between?(200, 299)

    data = parse_json(response, TOKEN_PATH)
    token = data.is_a?(Hash) ? data['access_token'] : nil
    if token.nil? || token.to_s.empty?
      raise ApiError.new("GLPI token endpoint #{TOKEN_PATH} returned no access_token", status: response.code.to_i, path: TOKEN_PATH)
    end
    ttl = data['expires_in'].to_i
    ttl = DEFAULT_TOKEN_TTL if ttl <= 0
    @tokens[scope] = [token.to_s, now + [ttl - TOKEN_LEEWAY, 0].max]
    token.to_s
  end

  # --- requests -------------------------------------------------------------

  def request(context, method_class, path, body: nil, query: nil, raw: false, scope: REST_SCOPE)
    clean_path = validate_path(path)
    method     = method_class::METHOD
    refreshed  = false

    loop do
      response = request_with_retries(context, method_class, clean_path, body, query, scope)
      code     = response.code.to_i

      if code == 401 && !refreshed
        refreshed = true
        @tokens.delete(scope)
        next
      end
      raise_api_error(response, method, clean_path) unless code.between?(200, 299)

      return response if raw
      return nil if response.body.nil? || response.body.empty?
      return parse_json(response, clean_path)
    end
  end

  def request_with_retries(context, method_class, path, body, query, scope = REST_SCOPE)
    uri        = build_uri(path, query)
    idempotent = method_class::METHOD == 'GET'
    attempts = 0
    loop do
      attempts += 1
      req = method_class.new(uri)
      apply_headers(req)
      req['Authorization'] = "Bearer #{access_token(context, scope)}"
      if body
        req['Content-Type'] = 'application/json'
        req.body = body.to_json
      end
      context.debug("GLPI API #{method_class::METHOD} #{path}")
      begin
        response = perform(req, uri, method_class::METHOD, path)
      rescue TimeoutError
        raise unless idempotent && attempts <= MAX_GET_RETRIES
        sleep(attempts)
        next
      end
      if idempotent && response.code.to_i >= 500 && attempts <= MAX_GET_RETRIES
        sleep(attempts)
        next
      end
      return response
    end
  end

  # One started Net::HTTP is kept and reused (keep-alive). A connection-level
  # failure on a REUSED socket closes it and resends once on a fresh
  # connection, but only when +safe_to_resend+ (never for a POST, which might
  # have been written and processed). A fresh connection that fails raises.
  def perform(req, uri, method, path, safe_to_resend: method != 'POST')
    @http_lock.synchronize do
      resent = false
      @last_request_resent = false
      begin
        reused = nil
        http, reused = connection_for(uri)
        response = http.request(req)
        @last_used = now
        response
      rescue *CONNECTION_FAILURES => error
        close_connection
        # A GET timeout is retried (with backoff) by request_with_retries.
        timed_out = error.is_a?(Net::ReadTimeout) || error.is_a?(Net::OpenTimeout)
        if reused && safe_to_resend && !resent && !(timed_out && method == 'GET')
          resent = true
          @last_request_resent = true
          retry
        end
        raise translate_failure(error, method, path)
      end
    end
  end

  def connection_for(uri)
    origin = [uri.scheme, uri.host, uri.port]
    if @http&.started? && @origin == origin && @last_used && now - @last_used < IDLE_REUSE_LIMIT
      return [@http, true]
    end
    close_connection
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = uri.scheme == 'https'
    http.open_timeout = @timeout
    http.read_timeout = @timeout
    # Net::HTTP's own silent retry must not stack on the resend in #perform.
    http.max_retries  = 0
    if http.use_ssl?
      if @ssl_verify
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.ca_file     = @ssl_ca_file if @ssl_ca_file
      else
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
    end
    @http   = http
    @origin = origin
    http.start
    [http, false]
  end

  def close_connection
    http = @http
    @http = nil
    @last_used = nil
    http.finish if http&.started?
  rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    nil
  end

  def translate_failure(error, method, path)
    if error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout)
      TimeoutError.new("GLPI API #{method} #{path} timed out", path: path)
    else
      ApiError.new("GLPI API #{method} #{path} failed: #{error.class}", path: path)
    end
  end

  def apply_headers(req)
    req['Accept']     = 'application/json'
    req['User-Agent'] = USER_AGENT
  end

  def validate_path(path)
    unless path.is_a?(String) && path.start_with?('/')
      raise Puppet::ResourceError, "GLPI API path must be a string starting with '/', got #{path.inspect}"
    end
    segments = path.split('/', -1)
    if segments.any? { |segment| ['.', '..'].include?(segment) }
      raise Puppet::ResourceError, "GLPI API path #{path.inspect} contains an invalid dot path segment"
    end
    segments.map { |segment| URI::DEFAULT_PARSER.escape(segment, %r{[^A-Za-z0-9_.~%-]}) }.join('/')
  end

  def build_uri(path, query)
    uri = URI("#{@base_url}#{API_VERSION_PREFIX}#{path}")
    uri.query = URI.encode_www_form(query) if query && !query.empty?
    uri
  end

  # --- responses ------------------------------------------------------------

  def parse_json(response, path)
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    raise ApiError.new("GLPI API returned invalid JSON on #{path}", status: response.code.to_i, path: path)
  end

  def content_range_total(header)
    match = header.to_s.match(%r{\A\s*(?:\w+\s+)?\d+-\d+/(\d+)\s*\z})
    match && match[1].to_i
  end

  def raise_api_error(response, method, path)
    status  = response.code.to_i
    message = "GLPI API error #{status} on #{method} #{path}"
    detail  = error_detail(response)
    message += ": #{detail}" unless detail.empty?
    raise ApiError.new(message, status: status, path: path)
  end

  # GLPI error documents carry +title+ and +detail+; anything else is ignored
  # rather than echoed.
  def error_detail(response)
    data = JSON.parse(response.body.to_s)
    return '' unless data.is_a?(Hash)
    [data['title'], data['detail']].compact.map(&:to_s).reject(&:empty?).join(' - ')
  rescue JSON::ParserError
    ''
  end
end
