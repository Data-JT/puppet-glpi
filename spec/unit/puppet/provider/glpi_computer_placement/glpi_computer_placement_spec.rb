# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../../../../lib/puppet/provider/glpi_computer_placement/glpi_computer_placement'
require_relative '../../../../../lib/puppet/type/glpi_computer_placement'

# rubocop:disable RSpec/MessageSpies
RSpec.describe Puppet::Provider::GlpiComputerPlacement::GlpiComputerPlacement do
  subject(:provider) { described_class.new }

  let(:config_dir) { Dir.mktmpdir('glpi-placement-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password'
    }
  end
  let(:transport) { instance_double('Puppet::Transport::Glpi') }
  let(:type) { instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_computer_placement', namevars: [:name], ensurable?: false) }
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }

  # Entities that are another entity's parent are listed without tag and
  # completename (as API v2 does); the provider reads them by id when needed.
  let(:entities) do
    [
      { 'id' => 0, 'name' => 'Root entity', 'parent' => nil },
      { 'id' => 2, 'name' => 'Customers', 'parent' => { 'id' => 0, 'name' => 'Root entity' } },
      { 'id' => 3, 'name' => 'Customer A', 'completename' => 'Root entity > Customers > Customer A', 'tag' => '10001',
        'parent' => { 'id' => 2, 'name' => 'Customers' } },
      { 'id' => 4, 'name' => 'Customer &#38; B', 'completename' => 'Root entity > Customers > Customer &#38; B', 'tag' => '10002',
        'parent' => { 'id' => 2, 'name' => 'Customers' } },
      { 'id' => 5, 'name' => 'Twin', 'completename' => 'Root entity > Twin', 'tag' => '', 'parent' => { 'id' => 0, 'name' => 'Root entity' } },
      { 'id' => 6, 'name' => 'Twin', 'completename' => 'Root entity > Customers > Twin', 'tag' => '10001x',
        'parent' => { 'id' => 2, 'name' => 'Customers' } },
    ]
  end
  let(:entity_items) do
    {
      '/Administration/Entity/0' => { 'id' => 0, 'name' => 'Root entity', 'tag' => '', 'parent' => nil },
      '/Administration/Entity/2' => { 'id' => 2, 'name' => 'Customers', 'tag' => '10009', 'parent' => { 'id' => 0, 'name' => 'Root entity' } },
    }
  end
  let(:locations) do
    [
      { 'id' => 1, 'name' => 'Main office', 'parent' => nil },
      { 'id' => 2, 'name' => 'Branch', 'completename' => 'Main office > Branch', 'parent' => { 'id' => 1, 'name' => 'Main office' } },
      { 'id' => 3, 'name' => 'Lab', 'completename' => 'Lab', 'parent' => nil },
    ]
  end
  let(:computers) do
    [
      { 'id' => 10, 'name' => 'web1.example.com', 'is_deleted' => false,
        'entity' => { 'id' => 0, 'name' => 'Root entity', 'completename' => 'Root entity' }, 'location' => { 'id' => 1, 'name' => 'Main office' } },
      { 'id' => 11, 'name' => 'db1', 'is_deleted' => false,
        'entity' => { 'id' => 3, 'name' => 'Customer A', 'completename' => 'Root entity > Customers > Customer A' }, 'location' => nil },
      { 'id' => 12, 'name' => 'gone.example.com', 'is_deleted' => true,
        'entity' => { 'id' => 0, 'name' => 'Root entity', 'completename' => 'Root entity' }, 'location' => nil },
    ]
  end

  def copy(value)
    Marshal.load(Marshal.dump(value))
  end

  before(:each) do
    File.write(config_file, config.to_yaml)
    allow(described_class).to receive_messages(config_path: config_file, build_transport: transport)
    lists = { '/Assets/Computer' => -> { computers }, '/Administration/Entity' => -> { entities }, '/Dropdowns/Location' => -> { locations } }
    allow(transport).to receive(:get_all) { |_ctx, p, _q| copy(lists.fetch(p).call) }
    allow(transport).to receive(:get) do |_ctx, p, _q = nil|
      copy(entity_items.fetch(p) { computers.find { |c| "/Assets/Computer/#{c['id']}" == p } })
    end
    allow(transport).to receive(:patch)
    allow(transport).to receive(:post)
    allow(transport).to receive(:delete)
    allow(type).to receive(:feature?).and_return(false)
    allow(type).to receive(:feature?).with('simple_get_filter').and_return(true)
    allow(context).to receive(:updating) { |_name, &block| block.call }
    [:debug, :info, :notice, :warning, :err].each { |level| allow(context).to receive(level) }
  end

  after(:each) { FileUtils.remove_entry(config_dir) }

  def should_for(name, overrides = {})
    { name: name, entity: nil, entity_tag: nil, location: nil }.merge(overrides)
  end

  def is_for(name)
    provider.get(context, [name]).first
  end

  def insync(name, attribute, should)
    provider.insync?(context, name, attribute, is_for(name), should_for(name, attribute => should))
  end

  it 'can be loaded twice without constant warnings' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_computer_placement/glpi_computer_placement.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  describe 'missing computer' do
    it 'warning, no create' do
      expect(is_for('new.example.com')).to be_nil
      expect(provider.insync?(context, 'new.example.com', :location, nil, should_for('new.example.com', location: 'Lab'))).to be true
      provider.update(context, 'new.example.com', should_for('new.example.com', location: 'Lab'))
      expect(context).to have_received(:warning).with(%r{no GLPI computer matches 'new.example.com'.*not created}).at_least(:once)
      expect(transport).not_to have_received(:post)
      expect(transport).not_to have_received(:patch)
    end

    it 'treats a trashed computer as missing' do
      expect(is_for('gone.example.com')).to be_nil
      expect(insync('gone.example.com', :entity, 'Customer A')).to be true
      expect(context).to have_received(:warning).with(%r{gone.example.com})
    end

    it 'set never creates: a change for a missing computer only warns' do
      provider.set(context, 'new.example.com' => { is: nil, should: should_for('new.example.com', entity: 'Customer A') })
      expect(transport).not_to have_received(:post)
      expect(transport).not_to have_received(:patch)
    end
  end

  describe "missing computer with unresolved => 'fail'" do
    before(:each) { File.write(config_file, config.merge('unresolved' => 'fail').to_yaml) }

    it 'insync? fails the resource once with the warning text, no warning' do
      should = should_for('new.example.com', entity: 'Customer A', location: 'Lab')
      expect { provider.insync?(context, 'new.example.com', :entity, nil, should) }.to raise_error(
        Puppet::ResourceError, "glpi_computer_placement: no GLPI computer matches 'new.example.com' (or it is in the trash); " \
                               'not placed, computers are not created'
      )
      expect(provider.insync?(context, 'new.example.com', :location, nil, should)).to be true
      expect(context).not_to have_received(:warning)
    end

    it 'a trashed computer fails too' do
      expect { insync('gone.example.com', :entity, 'Customer A') }.to raise_error(Puppet::ResourceError, %r{gone.example.com})
    end

    it 'the next run (a new target state) fails again' do
      expect { insync('new.example.com', :entity, 'Customer A') }.to raise_error(Puppet::ResourceError)
      expect { insync('new.example.com', :entity, 'Customer A') }.to raise_error(Puppet::ResourceError)
    end

    it 'update of a computer gone since insync? fails, writes nothing' do
      expect { provider.update(context, 'new.example.com', should_for('new.example.com', location: 'Lab')) }.to raise_error(
        Puppet::ResourceError, %r{no GLPI computer matches 'new.example.com'}
      )
      expect(transport).not_to have_received(:patch)
    end

    it 'an existing computer is compared and written as before' do
      expect(insync('web1.example.com', :location, 'Main office')).to be true
      expect(insync('web1.example.com', :entity, 'Customer A')).to be false
      provider.update(context, 'web1.example.com', should_for('web1.example.com', entity: 'Customer A'))
      expect(transport).to have_received(:patch).with(context, '/Assets/Computer/10', { 'entity' => 3 })
    end
  end

  describe 'get' do
    it 'lists nothing without names (no purge, no puppet resource listing)' do
      expect(provider.get(context)).to eq([])
      expect(provider.get(context, [])).to eq([])
    end

    it 'entity resolves by completename and reads back as completename' do
      expect(is_for('db1')).to include(name: 'db1', entity: 'Root entity > Customers > Customer A')
      expect(insync('db1', :entity, 'Root entity > Customers > Customer A')).to be true
      expect(insync('web1.example.com', :entity, 'Root entity > Customers > Customer A')).to be false
    end

    it 'reads the location as its complete name and the entity tag of the current entity' do
      expect(is_for('web1.example.com')).to eq(name: 'web1.example.com', entity: 'Root entity', entity_tag: nil, location: 'Main office')
      expect(is_for('db1')).to include(entity_tag: '10001', location: '')
    end

    it 'returns values that pass the type schema (no tag reads back as undef)' do
      definition = Puppet::Type.type(:glpi_computer_placement).type_definition
      ['web1.example.com', 'db1'].each { |name| expect(definition.check_schema_values(is_for(name))).to eq({}) }
    end

    it 'returns the name exactly as requested (matched by short name, case-insensitive)' do
      expect(is_for('DB1.example.com')).to include(name: 'DB1.example.com', entity: 'Root entity > Customers > Customer A')
    end
  end

  describe 'insync?' do
    it 'accepts a unique entity name, compared by id' do
      expect(insync('db1', :entity, 'Customer A')).to be true
      expect(insync('db1', :entity, 'Customer & B')).to be false
    end

    it 'resolves entity names and complete names case-insensitively' do
      expect(insync('db1', :entity, 'customer a')).to be true
      expect(insync('db1', :entity, 'ROOT entity > customers > CUSTOMER a')).to be true
    end

    it 'decodes entity names' do
      computers[1]['entity'] = { 'id' => 4, 'name' => 'Customer &#38; B', 'completename' => 'Root entity > Customers > Customer &#38; B' }
      expect(is_for('db1')).to include(entity: 'Root entity > Customers > Customer & B')
      expect(insync('db1', :entity, 'Root entity > Customers > Customer & B')).to be true
    end

    it 'fails on an ambiguous entity name' do
      expect { insync('db1', :entity, 'Twin') }.to raise_error(Puppet::ResourceError, %r{2 GLPI entities .*'Twin'.*ids 5, 6})
    end

    it 'fails on an unknown entity' do
      expect { insync('db1', :entity, 'Nobody') }.to raise_error(Puppet::ResourceError, %r{no GLPI entity 'Nobody'})
    end

    it 'entity_tag selects the entity with that tag' do
      expect(insync('db1', :entity_tag, '10001')).to be true
      expect(insync('web1.example.com', :entity_tag, '10001')).to be false
    end

    it 'entity_tag finds tags of entities listed without one (read by id)' do
      computers[0]['entity'] = { 'id' => 2, 'name' => 'Customers', 'completename' => 'Root entity > Customers' }
      expect(is_for('web1.example.com')).to include(entity_tag: '10009')
      expect(insync('web1.example.com', :entity_tag, '10009')).to be true
    end

    it 'fails on an unknown entity tag' do
      expect { insync('db1', :entity_tag, '99999') }.to raise_error(Puppet::ResourceError, %r{no GLPI entity has the tag '99999'})
    end

    it 'fails on a duplicated entity tag' do
      entities[5]['tag'] = '10001'
      expect { insync('db1', :entity_tag, '10001') }.to raise_error(Puppet::ResourceError, %r{2 GLPI entities have the tag '10001'})
    end

    it 'compares locations by complete name or unique name' do
      computers[0]['location'] = { 'id' => 2, 'name' => 'Branch' }
      expect(is_for('web1.example.com')).to include(location: 'Main office > Branch')
      expect(insync('web1.example.com', :location, 'Main office > Branch')).to be true
      expect(insync('web1.example.com', :location, 'Branch')).to be true
      expect(insync('web1.example.com', :location, 'Lab')).to be false
    end

    it 'empty location means none' do
      expect(insync('db1', :location, '')).to be true
      expect(insync('web1.example.com', :location, '')).to be false
    end

    it 'fails on an unknown location' do
      expect { insync('db1', :location, 'Mars') }.to raise_error(Puppet::ResourceError, %r{no GLPI location 'Mars'})
    end
  end

  describe 'without the transport file (first run, before class glpi wrote it)' do
    before(:each) { File.delete(config_file) }

    it 'get reports nothing and insync? defers to set instead of failing the resource' do
      expect(provider.get(context, ['web1.example.com'])).to eq([])
      expect(provider.insync?(context, 'web1.example.com', :location, nil, should_for('web1.example.com', location: 'Lab'))).to be_nil
      expect(transport).not_to have_received(:get_all)
    end

    it 'set re-reads the real state once the file exists' do
      provider.get(context, ['web1.example.com'])
      File.write(config_file, config.to_yaml)
      provider.set(context, 'web1.example.com' => { is: nil, should: should_for('web1.example.com', location: 'Lab') })
      expect(transport).to have_received(:patch).with(context, '/Assets/Computer/10', { 'location' => 3 })
    end
  end

  it 'fails on an ambiguous computer name' do
    computers << { 'id' => 13, 'name' => 'WEB1.example.com', 'is_deleted' => false, 'entity' => computers[0]['entity'], 'location' => nil }
    expect { is_for('web1.example.com') }.to raise_error(Puppet::ResourceError, %r{2 GLPI computers match 'web1.example.com' \(ids 10, 13\)})
  end

  it 'reads an entity listed without a tag once, across updates' do
    computers[0]['entity'] = { 'id' => 2, 'name' => 'Customers', 'completename' => 'Root entity > Customers' }
    2.times do
      is_for('web1.example.com')
      provider.update(context, 'web1.example.com', should_for('web1.example.com', entity_tag: '10009'))
    end
    expect(transport).to have_received(:get).with(context, '/Administration/Entity/2').once
  end

  describe 'update' do
    it 'PATCHes only the declared fields that differ' do
      provider.update(context, 'web1.example.com', should_for('web1.example.com', location: 'Lab', entity: 'Root entity'))
      expect(transport).to have_received(:patch).once
      expect(transport).to have_received(:patch).with(context, '/Assets/Computer/10', { 'location' => 3 })
    end

    it 'writes the entity selected by entity_tag' do
      provider.update(context, 'db1.example.com', should_for('db1.example.com', entity_tag: '10002'))
      expect(transport).to have_received(:patch).with(context, '/Assets/Computer/11', { 'entity' => 4 })
    end

    it 'clears the location with an empty string' do
      provider.update(context, 'web1.example.com', should_for('web1.example.com', location: ''))
      expect(transport).to have_received(:patch).with(context, '/Assets/Computer/10', { 'location' => 0 })
    end

    it 'set updates through update() although the type has no ensure' do
      provider.set(context, 'web1.example.com' => { is: is_for('web1.example.com'), should: should_for('web1.example.com', location: 'Lab') })
      expect(transport).to have_received(:patch).with(context, '/Assets/Computer/10', { 'location' => 3 })
    end
  end

  describe 'write-through' do
    it 'updating N computers costs one list read, N writes and N item reads' do
      allow(transport).to receive(:patch) { |_c, p, body| computers.find { |c| "/Assets/Computer/#{c['id']}" == p }['location'] = { 'id' => body['location'] } }
      ['web1.example.com', 'db1'].each do |name|
        provider.set(context, name => { is: is_for(name), should: should_for(name, location: 'Lab') })
      end
      expect(transport).to have_received(:get_all).with(context, '/Assets/Computer', anything).once
      expect(transport).to have_received(:patch).twice
      expect(transport).to have_received(:get).with(context, %r{\A/Assets/Computer/}).twice
      expect(insync('db1', :location, 'Lab')).to be true
    end
  end
end
# rubocop:enable RSpec/MessageSpies
