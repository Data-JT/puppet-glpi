# frozen_string_literal: true

require 'json'
require 'uri'

# A small in-memory GLPI behind WebMock for the providers that keep links
# (certificate -> items, domain -> contracts): REST collections, link
# sub-resources and a GraphQL endpoint answering the paged `<Type>_Item`
# queries with an optional `itemtype==X` filter. The real transport talks to
# it, so the bodies asserted on are the ones that go over the wire.
#
# GLPI's behaviour as observed: null in a write is ignored (the value is
# kept), "" clears a date, a Domain expiration reads back with a time.
class FakeLinkGlpi
  attr_reader :requests, :collections, :links, :graphql_queries

  # links: { 'Certificate_Item' => [rows], 'Contract_Item' => [rows] }
  # link_routes: { [collection, sub] => [graphql type, owner key] }
  LINK_ROUTES = {
    ['/Assets/Computer', 'Certificate'] => ['Certificate_Item', 'certificate', 'Computer'],
    ['/Management/Domain', 'Contract'] => ['Contract_Item', 'contract', 'Domain'],
  }.freeze

  def initialize(collections, links)
    @collections = collections
    @links = links
    @requests = []
    @graphql_queries = []
    @next_id = 500
  end

  def call(request)
    uri = URI(request.uri.to_s)
    path = uri.path.sub(%r{\A/api\.php/v2}, '')
    query = URI.decode_www_form(uri.query.to_s).to_h
    body = request.body.to_s.empty? ? nil : JSON.parse(request.body)
    return graphql(body['query']) if path == '/GraphQL/'

    @requests << [request.method.to_s.upcase, path, body]
    send("handle_#{request.method}", path, query, body)
  end

  def bodies
    writes.map(&:last).compact
  end

  def writes(method = nil)
    requests.reject { |m, _, _| m == 'GET' }.select { |m, _, _| method.nil? || m == method }
  end

  private

  def json(status, value, headers = {})
    { status: status, body: value.to_json, headers: { 'Content-Type' => 'application/json' }.merge(headers) }
  end

  def graphql(query)
    @graphql_queries << query
    match = %r{\A\{ (\w+)\(start: (\d+), limit: (\d+), sort: "id"(?:, filter: "((?:[^"\\]|\\.)*)")?\) \{}.match(query)
    raise "unexpected GraphQL query #{query}" unless match

    type, start, limit, filter = match.captures
    rows = Array(@links[type]).sort_by { |row| row['id'] }
    if filter
      field, value = filter.gsub('\\\\', '\\').split('==', 2)
      rows = rows.select { |row| row[field].to_s == value }
    end
    json(200, { data: { type => rows.drop(start.to_i).first(limit.to_i) } })
  end

  def link_route(path)
    match = %r{\A(/[^/]+/[^/]+)/(\d+)/([A-Za-z]+)(?:/(\d+))?\z}.match(path)
    return nil unless match && LINK_ROUTES.key?([match[1], match[3]])

    [LINK_ROUTES[[match[1], match[3]]], match[2].to_i, match[4]&.to_i]
  end

  def split(path)
    match = %r{\A(.+)/(\d+)\z}.match(path)
    match ? [match[1], match[2].to_i] : [path, nil]
  end

  def handle_get(path, query, _body)
    collection, id = split(path)
    list = @collections[collection]
    return json(404, { 'title' => 'not found' }) if list.nil?

    if id
      object = list.find { |o| o['id'] == id }
      return object ? json(200, object) : json(404, { 'title' => 'not found' })
    end
    page = query['start'].to_i.positive? ? [] : list
    json(200, page, 'Content-Range' => "0-#{[list.size - 1, 0].max}/#{list.size}")
  end

  def handle_post(path, _query, body)
    route = link_route(path)
    return post_link(route, body) if route

    list = @collections[path] or return json(404, {})
    id = (@next_id += 1)
    object = { 'id' => id, 'name' => nil, 'comment' => nil, 'is_deleted' => false, 'date_expiration' => nil,
               'entity' => { 'id' => 0, 'name' => 'Root entity' } }
    list << apply(path, object, body)
    json(201, { 'id' => id, 'href' => "#{path}/#{id}" })
  end

  def post_link((spec, items_id, _), body)
    type, key, itemtype = spec
    target = body[key]
    raise "link body without #{key}: #{body}" unless target.is_a?(Hash) && target['id'].is_a?(Integer)

    id = (@next_id += 1)
    @links[type] << { 'id' => id, 'itemtype' => itemtype, 'items_id' => items_id, key => { 'id' => target['id'] } }
    json(201, { 'id' => id })
  end

  def handle_patch(path, _query, body)
    collection, id = split(path)
    object = @collections.fetch(collection).find { |o| o['id'] == id } or return json(404, {})
    apply(collection, object, body)
    json(200, object)
  end

  def handle_delete(path, _query, _body)
    route = link_route(path)
    if route
      (type,), _, link_id = route
      before = @links[type].size
      @links[type].reject! { |row| row['id'] == link_id }
      return json((before == @links[type].size) ? 404 : 204, nil)
    end
    collection, id = split(path)
    object = @collections.fetch(collection).find { |o| o['id'] == id } or return json(404, {})
    object['is_deleted'] = true
    json(204, nil)
  end

  def apply(collection, object, body)
    body.each do |key, value|
      next if value.nil?

      object[key] = case key
                    when 'comment'
                      value.gsub('&', '&#38;') # GLPI stores some text entity-encoded
                    when 'entity'
                      { 'id' => value['id'], 'name' => "##{value['id']}" }
                    when 'date_expiration'
                      if value == ''
                        nil
                      else
                        (collection == '/Management/Domain') ? "#{value} 00:00:00" : value
                      end
                    else
                      value
                    end
    end
    object
  end
end
