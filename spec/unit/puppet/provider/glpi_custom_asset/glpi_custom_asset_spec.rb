# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'webmock/rspec'
require_relative '../../../../../lib/puppet/provider/glpi_custom_asset/glpi_custom_asset'

# A small in-memory GLPI behind WebMock: the real transport talks to it, so
# the request bodies asserted here are the ones that go over the wire.
class FakeCustomAssetGlpi
  attr_reader :requests, :collections

  def initialize(collections, definitions)
    @collections = collections
    @definitions = definitions
    @requests = []
    @next_id = 500
  end

  def call(request)
    uri = URI(request.uri.to_s)
    path = uri.path.sub(%r{\A/api\.php/v2}, '')
    query = URI.decode_www_form(uri.query.to_s).to_h
    body = request.body.to_s.empty? ? nil : JSON.parse(request.body)
    @requests << [request.method.to_s.upcase, path, body]
    send("handle_#{request.method}", path, query, body)
  end

  def bodies
    requests.map(&:last).compact
  end

  def writes(method = nil)
    requests.reject { |m, _, _| m == 'GET' }.select { |m, _, _| method.nil? || m == method }
  end

  private

  def json(status, value, headers = {})
    { status: status, body: value.to_json, headers: { 'Content-Type' => 'application/json' }.merge(headers) }
  end

  def split(path)
    match = %r{\A(.+)/(\d+)\z}.match(path)
    match ? [match[1], match[2].to_i] : [path, nil]
  end

  def handle_get(path, query, _body)
    return json(200, @definitions) if path == '/Assets/Custom/'

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
    list = @collections[path] or return json(404, {})
    id = (@next_id += 1)
    object = { 'id' => id, 'name' => nil, 'comment' => nil, 'is_deleted' => false, 'type' => nil,
               'entity' => { 'id' => 0, 'name' => 'Root entity' } }
    object['custom_fields'] = {} if path.start_with?('/Assets/Custom/') && !path.end_with?('Type')
    list << apply(object, body)
    json(201, { 'id' => id, 'href' => "#{path}/#{id}" })
  end

  def handle_patch(path, _query, body)
    collection, id = split(path)
    object = @collections.fetch(collection).find { |o| o['id'] == id } or return json(404, {})
    apply(object, body)
    json(200, object)
  end

  def handle_delete(path, _query, _body)
    collection, id = split(path)
    object = @collections.fetch(collection).find { |o| o['id'] == id } or return json(404, {})
    object['is_deleted'] = true
    json(204, nil)
  end

  # GLPI's behaviour as observed: null is ignored, dropdown custom fields
  # read back as id strings, a partial custom_fields merges.
  def apply(object, body)
    body.each do |key, value|
      next if value.nil?

      case key
      when 'custom_fields'
        value.each { |field, v| object['custom_fields'][field] = v.nil? ? object['custom_fields'][field] : v.to_s }
      when 'comment'
        object[key] = value.gsub('&', '&#38;') # GLPI stores some text entity-encoded
      when 'type', 'entity'
        object[key] = value['id'].zero? ? nil : { 'id' => value['id'], 'name' => "##{value['id']}" }
      else
        object[key] = value
      end
    end
    object
  end
end

RSpec.describe Puppet::Provider::GlpiCustomAsset::GlpiCustomAsset do
  subject(:provider) { described_class.new }

  let(:marker) { '[managed by puppet]' }
  let(:config_dir) { Dir.mktmpdir('glpi-custom-asset-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password',
      'marker' => marker, 'purge_max_fraction' => 0.5
    }
  end
  let(:type) do
    instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_custom_asset', namevars: [:definition, :name], ensurable?: true)
  end
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }

  let(:customer_a) { { 'id' => 3, 'name' => 'Customer A' } }
  let(:websites) do
    [
      { 'id' => 1, 'name' => 'www.example.com', 'comment' => "#{marker}\nMain site", 'is_deleted' => false,
        'type' => { 'id' => 1, 'name' => 'Shop' }, 'entity' => customer_a,
        'custom_fields' => { 'url' => 'https://www.example.com/', 'exposure' => 'public', 'runs_on' => '10', 'aliases' => 'example.com' } },
      { 'id' => 2, 'name' => 'hand.example.com', 'comment' => 'kept by a human', 'is_deleted' => false,
        'type' => nil, 'entity' => customer_a, 'custom_fields' => { 'url' => 'https://hand.example.com/', 'runs_on' => '0' } },
      { 'id' => 3, 'name' => 'old.example.com', 'comment' => marker, 'is_deleted' => true,
        'type' => nil, 'entity' => customer_a, 'custom_fields' => { 'url' => 'https://old.example.com/', 'runs_on' => '0' } },
    ]
  end
  let(:domains) do
    [
      { 'id' => 1, 'name' => 'www.example.com', 'comment' => marker, 'is_deleted' => false, 'type' => nil,
        'entity' => { 'id' => 0, 'name' => 'Root entity' }, 'custom_fields' => { 'registrar' => 'Registrar A' } },
    ]
  end
  let(:collections) do
    {
      '/Assets/Custom/Website' => websites,
      '/Assets/Custom/Domain' => domains,
      '/Assets/Custom/WebsiteType' => [{ 'id' => 1, 'name' => 'Shop' }],
      '/Assets/Custom/DomainType' => [],
      '/Assets/Computer' => [
        { 'id' => 10, 'name' => 'web1.example.com', 'is_deleted' => false },
        { 'id' => 11, 'name' => 'db1', 'is_deleted' => false },
        { 'id' => 12, 'name' => 'gone.example.com', 'is_deleted' => true },
      ],
      '/Assets/Appliance' => [{ 'id' => 5, 'name' => 'Web shop', 'is_deleted' => false }],
      '/Administration/Entity' => [
        { 'id' => 0, 'name' => 'Root entity', 'tag' => '', 'parent' => nil },
        { 'id' => 3, 'name' => 'Customer A', 'tag' => '10001', 'parent' => { 'id' => 0, 'name' => 'Root entity' } },
      ],
    }
  end
  let(:definitions) do
    [
      { 'itemtype' => 'Website', 'name' => 'Website', 'href' => '/Assets/Custom/Website' },
      { 'itemtype' => 'Domain', 'name' => 'Domain', 'href' => '/Assets/Custom/Domain' },
    ]
  end
  let(:glpi) { FakeCustomAssetGlpi.new(collections, definitions) }

  before(:each) do
    File.write(config_file, config.to_yaml)
    allow(described_class).to receive(:config_path).and_return(config_file)
    stub_request(:post, 'https://glpi.example.com/api.php/token')
      .to_return(status: 200, body: { access_token: 'tok', token_type: 'Bearer', expires_in: 3600 }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
    fake = glpi
    stub_request(:any, %r{\Ahttps://glpi\.example\.com/api\.php/v2/}).to_return { |request| fake.call(request) }
    allow(type).to receive(:feature?).and_return(false)
    allow(type).to receive(:feature?).with('simple_get_filter').and_return(true)
    [:debug, :info, :notice, :warning, :err].each { |level| allow(context).to receive(level) }
    [:creating, :updating, :deleting].each { |action| allow(context).to receive(action).and_yield }
  end

  after(:each) { FileUtils.remove_entry(config_dir) }

  def title(definition, name)
    { definition: definition, name: name }
  end

  def should_for(definition, name, overrides = {})
    { definition: definition, name: name, ensure: 'present', field_refs: {} }.merge(overrides)
  end

  def declare(definition, name, fields, refs = {})
    provider.declare_fields(title(definition, name), fields, refs)
  end

  def is_for(definition, name)
    provider.get(context, [title(definition, name)]).first
  end

  def deep_values(value)
    case value
    when Hash then value.values.flat_map { |v| deep_values(v) }
    when Array then value.flat_map { |v| deep_values(v) }
    else [value]
    end
  end

  it 'can be loaded twice without constant warnings' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_custom_asset/glpi_custom_asset.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  it 'same name in two definitions are two resources' do
    declare('Website', 'www.example.com', { 'url' => 'x' })
    declare('Domain', 'www.example.com', { 'registrar' => 'x' })
    website = is_for('Website', 'www.example.com')
    domain = is_for('Domain', 'www.example.com')
    expect(website).to include(title: 'Website/www.example.com', definition: 'Website', name: 'www.example.com',
                               fields: { 'url' => 'https://www.example.com/' })
    expect(domain).to include(definition: 'Domain', name: 'www.example.com', fields: { 'registrar' => 'Registrar A' })

    provider.update(context, title('Domain', 'www.example.com'),
                    should_for('Domain', 'www.example.com', fields: { 'registrar' => 'Registrar B' }))
    expect(glpi.writes).to eq([['PATCH', '/Assets/Custom/Domain/1', { 'custom_fields' => { 'registrar' => 'Registrar B' } }]])
    expect(websites[0]['custom_fields']).not_to include('registrar')
  end

  it 'undeclared fields are neither compared nor sent' do
    declare('Website', 'www.example.com', { 'url' => 'https://www.example.com/' })
    is = is_for('Website', 'www.example.com')
    expect(is[:fields]).to eq('url' => 'https://www.example.com/')
    should = should_for('Website', 'www.example.com', fields: { 'url' => 'https://www.example.com/' })
    expect(provider.insync?(context, title('Website', 'www.example.com'), :fields, is, should)).to be true

    provider.update(context, title('Website', 'www.example.com'),
                    should_for('Website', 'www.example.com', fields: { 'url' => 'https://shop.example.com/' }))
    expect(glpi.writes).to eq([['PATCH', '/Assets/Custom/Website/1', { 'custom_fields' => { 'url' => 'https://shop.example.com/' } }]])
    expect(websites[0]['custom_fields']).to include('exposure' => 'public', 'aliases' => 'example.com')
  end

  it 'boolean and date fields compare by value, not by their JSON spelling' do
    websites[0]['custom_fields'].update('active' => true, 'paused' => false, 'since' => '2027-02-28 00:00:00')
    fields = { 'active' => '1', 'paused' => '', 'since' => '2027-02-28' }
    declare('Website', 'www.example.com', fields)
    is = is_for('Website', 'www.example.com')
    expect(is[:fields]).to eq('active' => '1', 'paused' => '0', 'since' => '2027-02-28')
    expect(provider.insync?(context, title('Website', 'www.example.com'), :fields, is, should_for('Website', 'www.example.com', fields: fields))).to be true
    expect(provider.insync?(context, title('Website', 'www.example.com'), :fields, is,
                            should_for('Website', 'www.example.com', fields: fields.merge('active' => 'true', 'paused' => 'false')))).to be true
    changed = fields.merge('active' => '0', 'since' => '2027-03-01')
    expect(provider.insync?(context, title('Website', 'www.example.com'), :fields, is, should_for('Website', 'www.example.com', fields: changed)))
      .to eq([false, 'change active, since'])
  end

  it 'field_refs Computer: name resolves to id on write, id string "3" reads back as the name' do
    refs = { 'runs_on' => 'Computer' }
    declare('Website', 'www.example.com', { 'runs_on' => 'x' }, refs)
    expect(is_for('Website', 'www.example.com')[:fields]).to eq('runs_on' => 'web1.example.com')

    should = should_for('Website', 'www.example.com', fields: { 'runs_on' => 'db1.example.com' }, field_refs: refs)
    is = is_for('Website', 'www.example.com')
    expect(provider.insync?(context, title('Website', 'www.example.com'), :fields, is, should)).to eq([false, 'change runs_on'])
    provider.update(context, title('Website', 'www.example.com'), should)
    expect(glpi.writes).to eq([['PATCH', '/Assets/Custom/Website/1', { 'custom_fields' => { 'runs_on' => 11 } }]])
    expect(websites[0]['custom_fields']['runs_on']).to eq('11')

    # Read back as the name of the computer (stored id string), in sync with the declared FQDN.
    expect(is_for('Website', 'www.example.com')[:fields]).to eq('runs_on' => 'db1')
    expect(provider.insync?(context, title('Website', 'www.example.com'), :fields, is_for('Website', 'www.example.com'), should)).to be true
  end

  it 'field_refs Appliance resolves by name; an empty ref value clears the field' do
    refs = { 'runs_on' => 'Appliance' }
    provider.update(context, title('Website', 'www.example.com'),
                    should_for('Website', 'www.example.com', fields: { 'runs_on' => 'web SHOP' }, field_refs: refs))
    provider.update(context, title('Website', 'www.example.com'),
                    should_for('Website', 'www.example.com', fields: { 'runs_on' => '' }, field_refs: refs))
    expect(glpi.writes.map(&:last)).to eq([{ 'custom_fields' => { 'runs_on' => 5 } }, { 'custom_fields' => { 'runs_on' => '' } }])
  end

  describe 'unresolved field ref' do
    let(:refs) { { 'runs_on' => 'Computer' } }

    def unresolved_should(fields = {})
      should_for('Website', 'www.example.com', fields: { 'runs_on' => 'nowhere.example.com' }.merge(fields), field_refs: refs)
    end

    it 'warn mode leaves the stored id and warns' do
      declare('Website', 'www.example.com', { 'runs_on' => 'x' }, refs)
      is = is_for('Website', 'www.example.com')
      expect(context).to receive(:warning).with(%r{field runs_on: no Computer matches 'nowhere.example.com'; the stored value is kept}).once
      expect(provider.insync?(context, title('Website', 'www.example.com'), :fields, is, unresolved_should)).to be true

      provider.update(context, title('Website', 'www.example.com'), unresolved_should('url' => 'https://shop.example.com/'))
      expect(glpi.writes).to eq([['PATCH', '/Assets/Custom/Website/1', { 'custom_fields' => { 'url' => 'https://shop.example.com/' } }]])
      expect(websites[0]['custom_fields']['runs_on']).to eq('10')
    end

    context 'with unresolved => fail' do
      let(:config) { super().merge('unresolved' => 'fail') }

      it 'raises from insync? when nothing else is to be written' do
        is = is_for('Website', 'www.example.com')
        expect { provider.insync?(context, title('Website', 'www.example.com'), :fields, is, unresolved_should) }
          .to raise_error(Puppet::ResourceError, %r{no Computer matches 'nowhere.example.com'})
      end

      it 'writes the rest, then raises; a new asset is created without the field' do
        expect { provider.create(context, title('Website', 'new.example.com'), should_for('Website', 'new.example.com', fields: { 'runs_on' => 'nowhere', 'url' => 'u' }, field_refs: refs)) }
          .to raise_error(Puppet::ResourceError, %r{no Computer matches 'nowhere'})
        post = glpi.writes('POST').first
        expect(post[2]['custom_fields']).to eq('url' => 'u')
      end
    end

    it 'neither mode ever sends 0' do
      provider.update(context, title('Website', 'www.example.com'), unresolved_should('url' => 'u'))
      File.write(config_file, config.merge('unresolved' => 'fail').to_yaml)
      expect { provider.update(context, title('Website', 'www.example.com'), unresolved_should('url' => 'v')) }.to raise_error(Puppet::ResourceError)
      expect(glpi.bodies.map { |b| b['custom_fields'] }).to eq([{ 'url' => 'u' }, { 'url' => 'v' }])
      expect(deep_values(glpi.bodies)).not_to include(0)
    end
  end

  it '"" clears a field, and no request body ever contains null' do
    provider.update(context, title('Website', 'www.example.com'),
                    should_for('Website', 'www.example.com', fields: { 'aliases' => '' }, comment: 'Main site'))
    provider.create(context, title('Website', 'new.example.com'), should_for('Website', 'new.example.com', fields: { 'url' => '' }))
    provider.delete(context, title('Website', 'new.example.com'))
    expect(glpi.writes.first).to eq(['PATCH', '/Assets/Custom/Website/1', { 'custom_fields' => { 'aliases' => '' } }])
    expect(websites[0]['custom_fields']['aliases']).to eq('')
    expect(glpi.requests.map(&:first)).to include('POST', 'DELETE')
    expect(deep_values(glpi.bodies)).not_to include(nil)
  end

  it 'entity undef is not sent and not compared' do
    provider.create(context, title('Website', 'new.example.com'), should_for('Website', 'new.example.com', comment: 'c'))
    provider.update(context, title('Website', 'www.example.com'), should_for('Website', 'www.example.com', comment: 'other'))
    expect(glpi.bodies).to all(satisfy { |body| !body.key?('entity') })
    expect(provider.insync?(context, title('Website', 'www.example.com'), :entity, is_for('Website', 'www.example.com'),
                            should_for('Website', 'www.example.com'))).to be_nil
  end

  describe 'unresolvable entity' do
    let(:name) { title('Website', 'www.example.com') }

    def entity_should(overrides)
      should_for('Website', 'www.example.com', overrides)
    end

    it 'warn mode warns once, reports in sync and writes no entity' do
      is = is_for('Website', 'www.example.com')
      expect(context).to receive(:warning).with(%r{no GLPI entity 'Nowhere'}).once
      expect(provider.insync?(context, name, :entity, is, entity_should(entity: 'Nowhere'))).to be true
      expect(provider.insync?(context, name, :entity, is, entity_should(entity: 'Nowhere'))).to be true
      provider.update(context, name, entity_should(entity: 'Nowhere', comment: 'other'))
      expect(glpi.bodies).to all(satisfy { |body| !body.key?('entity') })
      expect(websites[0]['entity']).to eq(customer_a)
    end

    it 'warn mode treats an unknown entity tag the same way' do
      is = is_for('Website', 'www.example.com')
      expect(context).to receive(:warning).with(%r{no GLPI entity has the tag '99999'}).once
      expect(provider.insync?(context, name, :entity_tag, is, entity_should(entity_tag: '99999'))).to be true
    end

    it 'warns again in the next run, and the memory does not grow across runs' do
      is = is_for('Website', 'www.example.com')
      provider.plan_deletions(:run1, [])
      expect(context).to receive(:warning).with(%r{no GLPI entity 'Nowhere'}).twice
      provider.insync?(context, name, :entity, is, entity_should(entity: 'Nowhere'))
      provider.plan_deletions(:run2, [])
      expect(provider.instance_variable_get(:@warned_entities)).to be_empty
      provider.insync?(context, name, :entity, is, entity_should(entity: 'Nowhere'))
      expect(provider.instance_variable_get(:@warned_entities).size).to eq(1)
    end

    context 'with unresolved => fail' do
      let(:config) { super().merge('unresolved' => 'fail') }

      it 'raises from insync?' do
        is = is_for('Website', 'www.example.com')
        expect { provider.insync?(context, name, :entity, is, entity_should(entity: 'Nowhere')) }
          .to raise_error(Puppet::ResourceError, %r{no GLPI entity 'Nowhere'})
        expect { provider.insync?(context, name, :entity_tag, is, entity_should(entity_tag: '99999')) }
          .to raise_error(Puppet::ResourceError, %r{no GLPI entity has the tag '99999'})
      end
    end
  end

  it 'entity and entity_tag resolve to the entity id; written only when it differs' do
    is = is_for('Website', 'www.example.com')
    expect(is).to include(entity: 'Root entity > Customer A', entity_tag: '10001')
    expect(provider.insync?(context, title('Website', 'www.example.com'), :entity_tag, is,
                            should_for('Website', 'www.example.com', entity_tag: '10001'))).to be true
    expect(provider.insync?(context, title('Website', 'www.example.com'), :entity, is,
                            should_for('Website', 'www.example.com', entity: 'Root entity'))).to be false
    provider.update(context, title('Website', 'www.example.com'), should_for('Website', 'www.example.com', entity: 'Root entity'))
    provider.create(context, title('Website', 'new.example.com'), should_for('Website', 'new.example.com', entity_tag: '10001'))
    expect(glpi.bodies.map { |b| b['entity'] }).to eq([{ 'id' => 0 }, { 'id' => 3 }])
  end

  it 'comment carries the marker first and reads back without it' do
    provider.create(context, title('Website', 'new.example.com'), should_for('Website', 'new.example.com', comment: 'Shop & blog'))
    expect(glpi.writes('POST').first[2]).to include('name' => 'new.example.com', 'comment' => "#{marker}\nShop & blog")
    declare('Website', 'new.example.com', nil)
    expect(is_for('Website', 'new.example.com')[:comment]).to eq('Shop & blog')
    expect(is_for('Website', 'www.example.com')[:comment]).to eq('Main site')
  end

  it 'adopts an unmarked asset: marker first, its comment kept, only differences sent' do
    expect(is_for('Website', 'hand.example.com')).to be_nil
    provider.create(context, title('Website', 'hand.example.com'),
                    should_for('Website', 'hand.example.com', fields: { 'url' => 'https://hand.example.com/' }))
    expect(glpi.writes).to eq([['PATCH', '/Assets/Custom/Website/2', { 'comment' => "#{marker}\nkept by a human" }]])
  end

  it 'asset_type is found or created in the definition type dropdown; empty means none' do
    provider.create(context, title('Website', 'new.example.com'), should_for('Website', 'new.example.com', asset_type: 'Blog'))
    expect(glpi.writes('POST').map { |_, path, body| [path, body['name']] })
      .to eq([['/Assets/Custom/WebsiteType', 'Blog'], ['/Assets/Custom/Website', 'new.example.com']])
    expect(glpi.writes('POST').last[2]['type']).to eq('id' => 501)
    provider.update(context, title('Website', 'www.example.com'), should_for('Website', 'www.example.com', asset_type: ''))
    expect(glpi.writes('PATCH').last[2]).to eq('type' => { 'id' => 0 })
  end

  describe 'purge' do
    it 'lists only marked objects, per definition' do
      listed = provider.get(context, []).map { |r| [r[:definition], r[:name]] }
      expect(listed).to contain_exactly(['Website', 'www.example.com'], ['Domain', 'www.example.com'])
      expect(glpi.requests.map { |m, p, _| [m, p] }).to include(['GET', '/Assets/Custom/'])
    end

    it 'reads the catalog definitions when GLPI lists none' do
      definitions.replace([{ 'unexpected' => true }])
      provider.plan_deletions(:run, [title('Domain', 'gone')])
      expect(provider.get(context, []).map { |r| r[:definition] }).to eq(['Domain'])
    end

    it 'guards per definition' do
      websites.concat((4..7).map { |i| websites[0].merge('id' => i, 'name' => "w#{i}") })
      provider.plan_deletions(:run, [title('Website', 'w4'), title('Website', 'w5'), title('Website', 'w6'), title('Domain', 'www.example.com')])
      change = ->(t) { { t => { is: t.merge(ensure: 'present'), should: t.merge(ensure: 'absent') } } }
      provider.set(context, change.call(title('Domain', 'www.example.com')))
      expect { provider.set(context, change.call(title('Website', 'w4'))) }
        .to raise_error(Puppet::ResourceError, %r{glpi_custom_asset \(Website\): refusing to delete 3 of 5})
      expect(glpi.writes).to eq([['DELETE', '/Assets/Custom/Domain/1', nil]])
    end
  end

  describe 'definitions' do
    it 'never adopts or writes an unmarked same-name object of another definition' do
      domains << { 'id' => 7, 'name' => 'new.example.com', 'comment' => 'by hand', 'is_deleted' => false, 'type' => nil,
                   'entity' => { 'id' => 0, 'name' => 'Root entity' }, 'custom_fields' => {} }
      provider.plan_deletions(:run, [], [title('Domain', 'new.example.com'), title('Website', 'new.example.com')])
      expect(provider.get(context, [title('Website', 'new.example.com')])).to eq([])
      provider.create(context, title('Website', 'new.example.com'), should_for('Website', 'new.example.com', comment: 'c'))
      expect(glpi.writes.map { |m, path, _| [m, path] }).to eq([['POST', '/Assets/Custom/Website']])
      expect(domains.last['comment']).to eq('by hand')
    end

    it 'uses the spelling GLPI lists for a definition declared in another case' do
      declare('website', 'www.example.com', { 'url' => 'x' })
      expect(is_for('website', 'www.example.com')).to include(definition: 'website', fields: { 'url' => 'https://www.example.com/' })
      provider.update(context, title('website', 'www.example.com'), should_for('website', 'www.example.com', fields: { 'url' => 'u' }))
      provider.create(context, title('website', 'new.example.com'), should_for('website', 'new.example.com', asset_type: 'Blog'))
      expect(glpi.writes.map { |m, path, _| [m, path] })
        .to eq([['PATCH', '/Assets/Custom/Website/1'], ['POST', '/Assets/Custom/WebsiteType'], ['POST', '/Assets/Custom/Website']])
      expect(glpi.requests.map { |_, path, _| path }.grep(%r{/website}i)).to all(include('/Website'))
    end

    it 'fails only the resources of a definition GLPI does not list' do
      declare('Nosuch', 'x', nil)
      declare('Website', 'www.example.com', { 'url' => 'x' })
      expect { provider.get(context, [title('Nosuch', 'x')]) }
        .to raise_error(Puppet::ResourceError, %r{no custom asset definition 'Nosuch' \(/Assets/Custom/ lists: Domain, Website\)})
      expect { provider.create(context, title('Nosuch', 'x'), should_for('Nosuch', 'x')) }.to raise_error(Puppet::ResourceError, %r{'Nosuch'})
      expect(is_for('Website', 'www.example.com')).to include(name: 'www.example.com')
      expect(glpi.requests.map { |_, path, _| path }).not_to include(a_string_including('Nosuch'))
    end

    it 'reads every listed definition only for a listing without names, not on later reads' do
      provider.get(context, [])
      provider.invalidate_objects
      provider.get(context, [title('Website', 'www.example.com')])
      reads = glpi.requests.select { |m, _, _| m == 'GET' }.map { |_, path, _| path }.grep(%r{\A/Assets/Custom/\w+\z})
      expect(reads).to eq(['/Assets/Custom/Website', '/Assets/Custom/Domain', '/Assets/Custom/Website'])
    end
  end

  context 'with restore_trashed' do
    let(:config) { super().merge('restore_trashed' => true) }

    it 'restores the same id' do
      provider.create(context, title('Website', 'old.example.com'),
                      should_for('Website', 'old.example.com', fields: { 'url' => 'https://old.example.com/' }))
      expect(glpi.writes).to eq([['PATCH', '/Assets/Custom/Website/3', { 'is_deleted' => false }]])
      expect(is_for('Website', 'old.example.com')).to include(name: 'old.example.com', ensure: 'present')
    end

    it 'does not warn about a trashed twin in another definition' do
      domains << { 'id' => 8, 'name' => 'old.example.com', 'comment' => 'by hand', 'is_deleted' => true, 'type' => nil,
                   'entity' => { 'id' => 0, 'name' => 'Root entity' }, 'custom_fields' => {} }
      provider.plan_deletions(:run, [], [title('Domain', 'x'), title('Website', 'old.example.com')])
      expect(context).not_to receive(:warning)
      provider.create(context, title('Website', 'old.example.com'), should_for('Website', 'old.example.com'))
      expect(glpi.writes.map { |m, path, _| [m, path] }).to eq([['PATCH', '/Assets/Custom/Website/3']])
    end
  end

  describe 'delete_properties' do
    before(:each) { provider.plan_deletions(:run, []) }

    it 'clears the comment and the type, keeping the marker and the custom fields' do
      declare('Website', 'www.example.com', nil)
      is_for('Website', 'www.example.com')
      provider.update(context, title('Website', 'www.example.com'), should_for('Website', 'www.example.com', delete_properties: ['asset_type', 'comment']))
      expect(glpi.writes).to eq([['PATCH', '/Assets/Custom/Website/1', { 'comment' => marker, 'type' => { 'id' => 0 } }]])
    end

    it 'is in sync through the composite title once both read back empty' do
      name = title('Website', 'www.example.com')
      listed = should_for('Website', 'www.example.com', delete_properties: ['comment'])
      is = is_for('Website', 'www.example.com')
      expect(provider.insync?(context, name, :delete_properties, is, listed)).to be(false)
      expect(provider.insync?(context, name, :delete_properties, is.merge(comment: ''), listed)).to be(true)
    end
  end

  describe 'insync? of the plain attributes' do
    let(:name) { title('Website', 'www.example.com') }
    let(:is) { is_for('Website', 'www.example.com') }

    it 'compares the comment as text and the type as a key' do
      expect(provider.insync?(context, name, :comment, is, should_for('Website', 'www.example.com', comment: 'Main site'))).to be(true)
      expect(provider.insync?(context, name, :comment, is, should_for('Website', 'www.example.com', comment: 'main site'))).to be(false)
      expect(provider.insync?(context, name, :asset_type, is, should_for('Website', 'www.example.com', asset_type: 'SHOP'))).to be(true)
    end
  end

  it 'takes the guard scope from a plain key, and none from a key without a definition' do
    expect(provider.guard_scope('Website/www.example.com')).to eq('Website')
    expect(provider.guard_scope('no-definition')).to eq('')
  end
end
