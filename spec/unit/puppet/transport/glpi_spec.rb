# frozen_string_literal: true

require 'spec_helper'
require 'webmock/rspec'
require 'puppet/transport/glpi'

RSpec.describe Puppet::Transport::Glpi do
  subject(:transport) { described_class.new(context, connection_info) }

  let(:context) { instance_double('Puppet::ResourceApi::BaseContext') }
  let(:secret)  { instance_double('Puppet::Pops::Types::PSensitiveType::Sensitive', unwrap: 'client-secret-value') }
  let(:pass)    { instance_double('Puppet::Pops::Types::PSensitiveType::Sensitive', unwrap: 'user-password-value') }

  let(:connection_info) do
    {
      base_url:      'https://glpi.example.com/api.php',
      client_id:     'my-client',
      client_secret: secret,
      username:      'svc',
      password:      pass,
    }
  end

  let(:token_url) { 'https://glpi.example.com/api.php/token' }
  let(:api)       { 'https://glpi.example.com/api.php/v2' }

  def token_body(token = 'tok1', expires_in = 3600)
    { access_token: token, token_type: 'Bearer', expires_in: expires_in }.to_json
  end

  before(:each) do
    allow(context).to receive(:debug)
    allow(context).to receive(:warning)
  end

  it 'fetches a token with the password grant and sends it as Bearer' do
    token = stub_request(:post, token_url)
            .with(body: hash_including('grant_type' => 'password', 'client_id' => 'my-client',
                                       'client_secret' => 'client-secret-value',
                                       'username' => 'svc', 'password' => 'user-password-value',
                                       'scope' => 'api'))
            .to_return(status: 200, body: token_body, headers: { 'Content-Type' => 'application/json' })
    get = stub_request(:get, "#{api}/Assets/Computer/1")
          .with(headers: { 'Authorization' => 'Bearer tok1', 'Accept' => 'application/json' })
          .to_return(status: 200, body: { id: 1 }.to_json)

    expect(transport.get(context, '/Assets/Computer/1')).to eq('id' => 1)
    expect(token).to have_been_requested.once
    expect(get).to have_been_requested.once
  end

  it 'uses the client_credentials grant without username and password' do
    stub = stub_request(:post, token_url)
           .with { |r| r.body.include?('grant_type=client_credentials') && !r.body.include?('password') }
           .to_return(status: 200, body: token_body)
    stub_request(:get, "#{api}/Assets/Computer").to_return(status: 200, body: '[]')

    described_class.new(context, connection_info.merge(grant_type: 'client_credentials'))
                   .get(context, '/Assets/Computer')
    expect(stub).to have_been_requested.once
  end

  it 'falls back to a default TTL when expires_in is missing' do
    token = stub_request(:post, token_url).to_return(status: 200, body: { access_token: 't' }.to_json)
    stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
    2.times { transport.get(context, '/x') }
    expect(token).to have_been_requested.once
  end

  it 'reuses the cached token and refreshes it once expired' do
    token = stub_request(:post, token_url).to_return(status: 200, body: token_body('t', 3600))
    stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
    transport.get(context, '/x')
    transport.get(context, '/x')
    expect(token).to have_been_requested.once
    allow(Process).to receive(:clock_gettime).and_call_original
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC).and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3600)
    transport.get(context, '/x')
    expect(token).to have_been_requested.twice
  end

  describe '#get_all' do
    it 'concatenates 3 pages following Content-Range' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      ranges = { 0 => '0-49/120', 50 => '50-99/120', 100 => '100-119/120' }
      sizes  = { 0 => 50, 50 => 50, 100 => 20 }
      ranges.each do |start, range|
        stub_request(:get, "#{api}/Administration/User")
          .with(query: hash_including('start' => start.to_s, 'limit' => '50'))
          .to_return(status: 206, headers: { 'Content-Range' => range },
                     body: Array.new(sizes[start]) { |i| { id: start + i } }.to_json)
      end

      result = transport.get_all(context, '/Administration/User', limit: 50)
      expect(result.size).to eq(120)
      expect(result.map { |h| h['id'] }).to eq((0...120).to_a)
    end

    def stub_pages(pages, headers: {})
      pages.each_with_index do |(start, count, hdr), _i|
        stub_request(:get, "#{api}/Assets/Computer")
          .with(query: hash_including('start' => start.to_s))
          .to_return(status: 200, headers: hdr || headers,
                     body: Array.new(count) { |i| { id: start + i } }.to_json)
      end
    end

    it 'asks for the items sorted by id, so pages do not shift while they are read' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      page = stub_request(:get, "#{api}/Assets/Computer").with(query: hash_including('sort' => 'id'))
                                                         .to_return(status: 200, body: '[]')
      transport.get_all(context, '/Assets/Computer')
      expect(page).to have_been_requested.once
    end

    it 'keeps a sort the caller passes' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      page = stub_request(:get, "#{api}/Assets/Computer").with(query: hash_including('sort' => 'name:desc'))
                                                         .to_return(status: 200, body: '[]')
      transport.get_all(context, '/Assets/Computer', sort: 'name:desc')
      expect(page).to have_been_requested.once
    end

    it 'reads headerless pages limit, limit, short, empty' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      stub_pages([[0, 10], [10, 10], [20, 3], [23, 0]])
      expect(transport.get_all(context, '/Assets/Computer', limit: 10).size).to eq(23)
    end

    it 'reads everything when the server caps the page size below the limit' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      stub_pages([[0, 50], [50, 50], [100, 20], [120, 0]])
      expect(transport.get_all(context, '/Assets/Computer').size).to eq(120)
    end

    it 'continues past a short page while Content-Range says more follow' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      stub_pages([[0, 30, { 'Content-Range' => '0-29/60' }], [30, 30, { 'Content-Range' => '30-59/60' }]])
      expect(transport.get_all(context, '/Assets/Computer', limit: 100).size).to eq(60)
    end

    it 'raises when the server ignores the start offset' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      stub_request(:get, "#{api}/Assets/Computer").with(query: hash_including({}))
                                                  .to_return(status: 200, body: [{ id: 1 }, { id: 2 }].to_json)
      expect { transport.get_all(context, '/Assets/Computer', limit: 2) }
        .to raise_error(described_class::ApiError, %r{ignored the pagination offset})
    end

    it 'raises on a non-list response' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      stub_request(:get, "#{api}/Assets/Computer").with(query: hash_including({})).to_return(status: 200, body: '{"id":1}')
      expect { transport.get_all(context, '/Assets/Computer') }.to raise_error(described_class::ApiError, %r{non-list})
    end

    it 'rejects an invalid limit' do
      expect { transport.get_all(context, '/Assets/Computer', limit: 0) }.to raise_error(Puppet::ResourceError, %r{limit})
      expect { transport.get_all(context, '/Assets/Computer', limit: '5') }.to raise_error(Puppet::ResourceError, %r{limit})
    end

    it 'refreshes the token once on a 401 in the middle of the iteration' do
      token = stub_request(:post, token_url)
              .to_return({ status: 200, body: token_body('old') }, { status: 200, body: token_body('new') })
      stub_request(:get, "#{api}/Assets/Computer").with(query: hash_including('start' => '0'))
                                                  .to_return(status: 200, body: [{ id: 0 }, { id: 1 }].to_json)
      stub_request(:get, "#{api}/Assets/Computer").with(query: hash_including('start' => '2'),
                                                        headers: { 'Authorization' => 'Bearer old' })
                                                  .to_return(status: 401)
      stub_request(:get, "#{api}/Assets/Computer").with(query: hash_including('start' => '2'),
                                                        headers: { 'Authorization' => 'Bearer new' })
                                                  .to_return(status: 200, body: [{ id: 2 }].to_json)
      stub_request(:get, "#{api}/Assets/Computer").with(query: hash_including('start' => '3'))
                                                  .to_return(status: 200, body: '[]')
      expect(transport.get_all(context, '/Assets/Computer', limit: 2).size).to eq(3)
      expect(token).to have_been_requested.twice
    end

    it 'needs an empty page to stop when there is no Content-Range' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      stub_pages([[0, 1], [1, 0]])
      expect(transport.get_all(context, '/Assets/Computer')).to eq([{ 'id' => 0 }])
    end
  end

  describe 'HTTP 401' do
    it 'retries once with a fresh token' do
      token = stub_request(:post, token_url)
              .to_return({ status: 200, body: token_body('old') }, { status: 200, body: token_body('new') })
      stub_request(:get, "#{api}/x").with(headers: { 'Authorization' => 'Bearer old' }).to_return(status: 401)
      ok = stub_request(:get, "#{api}/x").with(headers: { 'Authorization' => 'Bearer new' })
                                         .to_return(status: 200, body: '{"ok":true}')
      expect(transport.get(context, '/x')).to eq('ok' => true)
      expect(token).to have_been_requested.twice
      expect(ok).to have_been_requested.once
    end

    it 'raises ApiError on the second 401' do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      stub = stub_request(:get, "#{api}/x").to_return(status: 401, body: { title: 'Unauthorized' }.to_json)
      expect { transport.get(context, '/x') }.to raise_error(described_class::ApiError) { |e|
        expect(e.status).to eq(401)
        expect(e.path).to eq('/x')
      }
      expect(stub).to have_been_requested.twice
    end
  end

  it 'never sends X-Forwarded-* or X-Auth-Request-* headers' do
    stub_request(:post, token_url).to_return(status: 200, body: token_body)
    stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
    transport.get(context, '/x')
    bad = %r{\Ax-(forwarded|auth-request)}i
    expect(WebMock).not_to(have_requested(:any, %r{.}).with { |r| r.headers.keys.any? { |h| h =~ bad } })
    expect(WebMock).to have_requested(:get, "#{api}/x").with(headers: { 'User-Agent' => 'puppet-glpi' })
  end

  describe 'write calls' do
    before(:each) { stub_request(:post, token_url).to_return(status: 200, body: token_body) }

    it 'posts and patches JSON bodies' do
      stub_request(:post, "#{api}/Assets/Computer").with(body: { name: 'a' }.to_json, headers: { 'Content-Type' => 'application/json' })
                                                   .to_return(status: 201, body: { id: 5 }.to_json)
      stub_request(:patch, "#{api}/Assets/Computer/5").with(body: { name: 'b' }.to_json)
                                                      .to_return(status: 200, body: { id: 5 }.to_json)
      expect(transport.post(context, '/Assets/Computer', name: 'a')).to eq('id' => 5)
      expect(transport.patch(context, '/Assets/Computer/5', name: 'b')).to eq('id' => 5)
    end

    it 'deletes and returns nil on 204' do
      stub_request(:delete, "#{api}/Assets/Computer/5").to_return(status: 204)
      expect(transport.delete(context, '/Assets/Computer/5')).to be_nil
    end
  end

  describe 'errors' do
    before(:each) { stub_request(:post, token_url).to_return(status: 200, body: token_body('tok-secret-xyz')) }

    it 'has status, method, path and GLPI detail but no secrets or request bodies' do
      stub_request(:post, "#{api}/Assets/Computer")
        .to_return(status: 400, body: { title: 'Bad request', detail: 'Missing field name' }.to_json)
      expect { transport.post(context, '/Assets/Computer', comment: 'body-marker-text') }
        .to raise_error(described_class::ApiError) { |e|
          expect(e.message).to match(%r{400.*POST.*/Assets/Computer.*Bad request.*Missing field name})
          expect(e.message).not_to match(%r{client-secret-value|user-password-value|tok-secret-xyz|body-marker-text})
        }
    end

    it 'does not leak secrets when the token request fails' do
      WebMock.reset!
      stub_request(:post, token_url).to_return(status: 401, body: { title: 'invalid_client' }.to_json)
      expect { transport.get(context, '/x') }.to raise_error(described_class::ApiError) { |e|
        expect(e.message).to match(%r{401})
        expect(e.message).not_to match(%r{client-secret-value|user-password-value})
      }
    end

    it 'wraps connection failures' do
      allow(transport).to receive(:sleep)
      stub = stub_request(:get, "#{api}/x").to_timeout
      expect { transport.get(context, '/x') }.to raise_error(described_class::ApiError, %r{GET /x})
      expect(stub).to have_been_requested.times(3)
    end

    it 'does not retry non-idempotent calls on timeout' do
      stub = stub_request(:post, "#{api}/x").to_timeout
      expect { transport.post(context, '/x', {}) }.to raise_error(described_class::ApiError)
      expect(stub).to have_been_requested.once
    end

    it 'logs no credential, token or body at any level, on success or failure' do
      logged = []
      [:debug, :info, :notice, :warning, :err].each do |level|
        allow(context).to receive(level) { |message| logged << message.to_s }
      end
      stub_request(:get, "#{api}/Assets/Computer/1").to_return(status: 200, body: '{"id":1}')
      stub_request(:patch, "#{api}/Assets/Computer/1").to_return(status: 400, body: '{"title":"Bad"}')
      transport.get(context, '/Assets/Computer/1')
      expect { transport.patch(context, '/Assets/Computer/1', 'comment' => 'body-marker-text') }.to raise_error(described_class::ApiError)
      expect(logged).not_to be_empty
      expect(logged.join("\n")).not_to match(%r{client-secret-value|user-password-value|tok-secret-xyz|body-marker-text})
    end

    it 'warns once per process that TLS verification is off' do
      described_class.ssl_warning_emitted = false
      expect(context).to receive(:warning).with(%r{verification is disabled}).once
      2.times { described_class.new(context, connection_info.merge(ssl_verify: false)) }
    ensure
      described_class.ssl_warning_emitted = nil
    end

    it 'does not expose secrets via inspect or to_s' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
      transport.get(context, '/x')
      expect(transport.inspect).not_to match(%r{client-secret-value|user-password-value|tok-secret-xyz})
      expect(transport.to_s).not_to match(%r{client-secret-value|user-password-value})
    end
  end

  describe 'GraphQL' do
    let(:graphql_url) { "#{api}/GraphQL/" }

    def scoped_token(scope, token)
      stub_request(:post, token_url).with(body: hash_including('scope' => scope))
                                    .to_return(status: 200, body: token_body(token))
    end

    def graphql_page(start, ids, limit: 100)
      query = "{ Appliance_Item(start: #{start}, limit: #{limit}, sort: \"id\") { id } }"
      stub_request(:post, graphql_url).with(body: { query: query }.to_json)
                                      .to_return(status: 200, body: { data: { Appliance_Item: ids.map { |i| { id: i } } } }.to_json)
    end

    it 'uses its own token with scope graphql; REST calls keep scope api' do
      api_token = scoped_token('api', 'tok-api')
      gql_token = scoped_token('graphql', 'tok-gql')
      stub_request(:get, "#{api}/x").with(headers: { 'Authorization' => 'Bearer tok-api' }).to_return(status: 200, body: '{}')
      gql = stub_request(:post, graphql_url).with(headers: { 'Authorization' => 'Bearer tok-gql' })
                                            .to_return(status: 200, body: { data: { A: [] } }.to_json)
      transport.get(context, '/x')
      expect(transport.graphql(context, '{ A { id } }')).to eq('A' => [])
      transport.get(context, '/x')
      expect([api_token, gql_token, gql]).to all(have_been_requested.once)
    end

    it 'raises ApiError with the GraphQL error messages' do
      scoped_token('graphql', 't')
      stub_request(:post, graphql_url).to_return(status: 200, body: { errors: [{ message: 'Cannot query field "Nope"' }] }.to_json)
      expect { transport.graphql(context, '{ Nope { id } }') }
        .to raise_error(described_class::ApiError, %r{GraphQL.*Cannot query field "Nope"})
    end

    it 'graphql_all pages with start/limit sorted by id until an empty page' do
      scoped_token('graphql', 't')
      [graphql_page(0, [1, 2], limit: 2), graphql_page(2, [3], limit: 2), graphql_page(3, [], limit: 2)]
      expect(transport.graphql_all(context, 'Appliance_Item', 'id', limit: 2)).to eq([{ 'id' => 1 }, { 'id' => 2 }, { 'id' => 3 }])
    end

    it 'graphql_all raises when the server ignores start' do
      scoped_token('graphql', 't')
      stub_request(:post, graphql_url).to_return(status: 200, body: { data: { Appliance_Item: [{ id: 1 }] } }.to_json)
      expect { transport.graphql_all(context, 'Appliance_Item', 'id', limit: 1) }
        .to raise_error(described_class::ApiError, %r{same page})
    end

    it 'graphql_all passes a filter into every page; a backslash is escaped for the GraphQL string' do
      scoped_token('graphql', 't')
      first = stub_request(:post, graphql_url)
              .with(body: { query: '{ Certificate_Item(start: 0, limit: 2, sort: "id", filter: "itemtype==Computer") { id } }' }.to_json)
              .to_return(status: 200, body: { data: { Certificate_Item: [{ id: 1 }] } }.to_json)
      last = stub_request(:post, graphql_url)
             .with(body: { query: '{ Certificate_Item(start: 1, limit: 2, sort: "id", filter: "itemtype==Computer") { id } }' }.to_json)
             .to_return(status: 200, body: { data: { Certificate_Item: [] } }.to_json)
      expect(transport.graphql_all(context, 'Certificate_Item', 'id', limit: 2, filter: 'itemtype==Computer')).to eq([{ 'id' => 1 }])
      expect([first, last]).to all(have_been_requested.once)

      escaped = stub_request(:post, graphql_url)
                .with(body: { query: '{ Contract_Item(start: 0, limit: 100, sort: "id", filter: "itemtype==Glpi\\\\CustomAsset\\\\WebsiteAsset") { id } }' }.to_json)
                .to_return(status: 200, body: { data: { Contract_Item: [] } }.to_json)
      transport.graphql_all(context, 'Contract_Item', 'id', filter: 'itemtype==Glpi\\CustomAsset\\WebsiteAsset')
      expect(escaped).to have_been_requested.once
    end

    it 'graphql_all rejects a filter that could leave the string literal' do
      ['itemtype=="x") { id } #', "a==b\nc", 'a == b', ''].each do |filter|
        expect { transport.graphql_all(context, 'Certificate_Item', 'id', filter: filter) }
          .to raise_error(Puppet::ResourceError, %r{GraphQL filter})
      end
    end

    it 'graphql_all rejects a malformed type or selection' do
      expect { transport.graphql_all(context, 'A } x {', 'id') }.to raise_error(Puppet::ResourceError, %r{GraphQL})
      expect { transport.graphql_all(context, 'A', 'id } x {') }.to raise_error(Puppet::ResourceError, %r{GraphQL})
    end
  end

  it 'requires its connection settings' do
    expect { described_class.new(context, connection_info.merge(client_id: nil)) }
      .to raise_error(Puppet::ResourceError, %r{client_id})
    expect { described_class.new(context, connection_info.merge(username: nil)) }
      .to raise_error(Puppet::ResourceError, %r{username})
    expect { described_class.new(context, connection_info.merge(grant_type: 'bogus')) }
      .to raise_error(Puppet::ResourceError, %r{grant_type})
  end

  describe 'persistent connection' do
    before(:each) do
      stub_request(:post, token_url).to_return(status: 200, body: token_body)
      allow(transport).to receive(:sleep)
    end

    def count_connections
      count = 0
      allow(Net::HTTP).to receive(:new).and_wrap_original do |orig, *args|
        count += 1
        orig.call(*args)
      end
      -> { count }
    end

    it 'opens exactly one connection for many requests (token included)' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
      stub_request(:post, "#{api}/x").to_return(status: 201, body: '{}')
      stub_request(:patch, "#{api}/x").to_return(status: 200, body: '{}')
      connections = count_connections
      transport.get(context, '/x')
      transport.post(context, '/x', {})
      transport.patch(context, '/x', {})
      transport.get(context, '/x')
      expect(connections.call).to eq(1)
    end

    it 'reconnects once and resends a GET after a reset on a reused socket' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{"a":1}').then
                                    .to_raise(Errno::ECONNRESET).then.to_return(status: 200, body: '{"a":2}')
      connections = count_connections
      expect(transport.get(context, '/x')).to eq('a' => 1)
      expect(transport.get(context, '/x')).to eq('a' => 2)
      expect(connections.call).to eq(2)
    end

    it 'resends a PATCH and a DELETE once after a reset on a reused socket' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
      patch = stub_request(:patch, "#{api}/x").to_raise(EOFError).then.to_return(status: 200, body: '{}')
      delete = stub_request(:delete, "#{api}/x").to_raise(IOError).then.to_return(status: 204, body: '')
      transport.get(context, '/x')
      expect { transport.patch(context, '/x', { 'a' => 1 }) }.not_to raise_error
      expect { transport.delete(context, '/x') }.not_to raise_error
      expect(patch).to have_been_requested.twice
      expect(delete).to have_been_requested.twice
    end

    it 'treats a 404 on a resent DELETE as done: the first one was processed' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
      delete = stub_request(:delete, "#{api}/x").to_raise(Net::ReadTimeout).then.to_return(status: 404, body: '{}')
      transport.get(context, '/x')
      expect(transport.delete(context, '/x')).to be_nil
      expect(delete).to have_been_requested.twice
    end

    it 'still raises a 404 on a DELETE that was not resent' do
      stub_request(:delete, "#{api}/x").to_return(status: 404, body: '{}')
      expect { transport.delete(context, '/x') }.to raise_error(described_class::ApiError) { |e| expect(e.status).to eq(404) }
    end

    it 'still raises a 404 on a resent PATCH' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
      stub_request(:patch, "#{api}/x").to_raise(EOFError).then.to_return(status: 404, body: '{}')
      transport.get(context, '/x')
      expect { transport.patch(context, '/x', {}) }.to raise_error(described_class::ApiError, %r{404})
    end

    it 'disables Net::HTTP\'s own retry so resends are only ours' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
      seen = nil
      allow(Net::HTTP).to receive(:new).and_wrap_original do |orig, *args|
        seen = orig.call(*args)
      end
      transport.get(context, '/x')
      expect(seen.max_retries).to eq(0)
    end

    it 'does not resend a POST after a reset on a reused socket' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
      post = stub_request(:post, "#{api}/x").to_raise(Errno::ECONNRESET)
      transport.get(context, '/x')
      expect { transport.post(context, '/x', {}) }.to raise_error(described_class::ApiError, %r{POST /x failed})
      expect(post).to have_been_requested.once
    end

    it 'does not resend a POST that times out on a reused socket' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
      post = stub_request(:post, "#{api}/x").to_timeout
      transport.get(context, '/x')
      expect { transport.post(context, '/x', {}) }.to raise_error(described_class::TimeoutError)
      expect(post).to have_been_requested.once
    end

    it 'does not resend a failure on a fresh connection' do
      WebMock.reset!
      token = stub_request(:post, token_url).to_raise(Errno::ECONNRESET)
      expect { transport.get(context, '/x') }.to raise_error(described_class::ApiError)
      expect(token).to have_been_requested.once
    end

    it 'replaces a socket that sat idle past the reuse limit' do
      stub_request(:get, "#{api}/x").to_return(status: 200, body: '{}')
      connections = count_connections
      transport.get(context, '/x')
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC)
                                               .and_return(Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10)
      transport.get(context, '/x')
      expect(connections.call).to eq(2)
    end
  end
end
