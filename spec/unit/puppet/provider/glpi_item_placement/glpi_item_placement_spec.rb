# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../../../../lib/puppet/provider/glpi_item_placement/glpi_item_placement'
require_relative '../../../../../lib/puppet/type/glpi_item_placement'

# rubocop:disable RSpec/MessageSpies
RSpec.describe Puppet::Provider::GlpiItemPlacement::GlpiItemPlacement do
  subject(:provider) { described_class.new }

  let(:config_dir) { Dir.mktmpdir('glpi-item-placement-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password'
    }
  end
  let(:transport) { instance_double('Puppet::Transport::Glpi') }
  let(:type) { instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_item_placement', namevars: [:itemtype, :name], ensurable?: false) }
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }

  let(:locations) do
    [
      { 'id' => 1, 'name' => 'Main office', 'parent' => nil },
      { 'id' => 2, 'name' => 'Branch', 'completename' => 'Main office > Branch', 'parent' => { 'id' => 1, 'name' => 'Main office' } },
      { 'id' => 3, 'name' => 'Lab', 'completename' => 'Lab', 'parent' => nil },
    ]
  end
  let(:network_equipment) do
    [
      { 'id' => 20, 'name' => 'core1', 'is_deleted' => false, 'location' => { 'id' => 2, 'name' => 'Branch' } },
      { 'id' => 21, 'name' => 'edge1', 'is_deleted' => false, 'location' => nil },
      { 'id' => 22, 'name' => 'old1', 'is_deleted' => true, 'location' => nil },
    ]
  end
  let(:data_centers) do
    [
      { 'id' => 30, 'name' => 'core1', 'is_deleted' => false, 'location' => { 'id' => 3, 'name' => 'Lab' } },
      { 'id' => 31, 'name' => 'dc2', 'is_deleted' => false, 'location' => nil },
    ]
  end

  def copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def item(itemtype, name)
    { itemtype: itemtype, name: name }
  end

  before(:each) do
    File.write(config_file, config.to_yaml)
    allow(described_class).to receive_messages(config_path: config_file, build_transport: transport)
    lists = {
      '/Assets/NetworkEquipment' => -> { network_equipment },
      '/Management/DataCenter' => -> { data_centers },
      '/Dropdowns/Location' => -> { locations },
    }
    allow(transport).to receive(:get_all) { |_ctx, p, _q| copy(lists.fetch(p).call) }
    allow(transport).to receive(:get) do |_ctx, p, _q = nil|
      copy((network_equipment + data_centers).find { |o| p.end_with?("/#{o['id']}") && lists.key?(p.sub(%r{/\d+\z}, '')) && lists[p.sub(%r{/\d+\z}, '')].call.include?(o) })
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

  def should_for(name, location)
    name.merge(location: location)
  end

  def is_for(name)
    provider.get(context, [name]).first
  end

  def insync(name, location)
    provider.insync?(context, name, :location, is_for(name), should_for(name, location))
  end

  it 'can be loaded twice without constant warnings' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_item_placement/glpi_item_placement.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  it 'two itemtypes, same name, are two items' do
    expect(is_for(item('NetworkEquipment', 'core1'))).to include(itemtype: 'NetworkEquipment', name: 'core1', title: 'NetworkEquipment/core1', location: 'Main office > Branch')
    expect(is_for(item('DataCenter', 'core1'))).to include(itemtype: 'DataCenter', name: 'core1', location: 'Lab')
    provider.update(context, item('DataCenter', 'core1'), should_for(item('DataCenter', 'core1'), 'Main office'))
    expect(transport).to have_received(:patch).with(context, '/Management/DataCenter/30', { 'location' => 1 })
  end

  it 'location insync by id, read back as complete name' do
    expect(insync(item('NetworkEquipment', 'core1'), 'Main office > Branch')).to be true
    expect(insync(item('NetworkEquipment', 'core1'), 'Branch')).to be true
    expect(insync(item('NetworkEquipment', 'core1'), 'branch')).to be true
    expect(insync(item('NetworkEquipment', 'core1'), 'Lab')).to be false
    expect(insync(item('NetworkEquipment', 'edge1'), 'Lab')).to be false
  end

  it 'returns values that pass the type schema' do
    definition = Puppet::Type.type(:glpi_item_placement).type_definition
    [item('NetworkEquipment', 'core1'), item('NetworkEquipment', 'edge1')].each do |name|
      expect(definition.check_schema_values(is_for(name))).to eq({})
    end
  end

  it 'matches the name case-insensitively and returns it as requested' do
    expect(is_for(item('NetworkEquipment', 'CORE1'))).to include(name: 'CORE1', location: 'Main office > Branch')
  end

  it 'does not match by a short name' do
    network_equipment << { 'id' => 23, 'name' => 'sw9.example.com', 'is_deleted' => false, 'location' => nil }
    expect(is_for(item('NetworkEquipment', 'sw9'))).to be_nil
  end

  it 'lists nothing without names' do
    expect(provider.get(context)).to eq([])
    expect(provider.get(context, [])).to eq([])
  end

  it 'fails on two live matches' do
    network_equipment << { 'id' => 24, 'name' => 'CORE1', 'is_deleted' => false, 'location' => nil }
    expect { is_for(item('NetworkEquipment', 'core1')) }.to raise_error(Puppet::ResourceError, %r{2 GLPI items match 'core1' \(ids 20, 24\)})
  end

  it 'fails on an unknown location' do
    expect { insync(item('NetworkEquipment', 'core1'), 'Mars') }.to raise_error(Puppet::ResourceError, %r{no GLPI location 'Mars'})
  end

  describe 'missing item' do
    it 'warn leaves it, no POST ever' do
      missing = item('NetworkEquipment', 'nope')
      expect(is_for(missing)).to be_nil
      expect(provider.insync?(context, missing, :location, nil, should_for(missing, 'Lab'))).to be true
      provider.update(context, missing, should_for(missing, 'Lab'))
      provider.set(context, missing => { is: nil, should: should_for(missing, 'Lab') })
      expect(context).to have_received(:warning).with(%r{no GLPI NetworkEquipment matches 'nope'.*not created}).once
      expect(transport).not_to have_received(:post)
      expect(transport).not_to have_received(:patch)
      expect(transport).not_to have_received(:delete)
    end

    it 'a trashed item is missing, and the other itemtype is not consulted' do
      expect(insync(item('NetworkEquipment', 'old1'), 'Lab')).to be true
      expect(is_for(item('DataCenter', 'edge1'))).to be_nil
      expect(transport).not_to have_received(:patch)
    end

    context "with unresolved => 'fail'" do
      before(:each) { File.write(config_file, config.merge('unresolved' => 'fail').to_yaml) }

      it 'fail raises, no POST ever' do
        missing = item('DataCenter', 'nope')
        expect { provider.insync?(context, missing, :location, nil, should_for(missing, 'Lab')) }.to raise_error(
          Puppet::ResourceError, "glpi_item_placement: no GLPI DataCenter matches 'nope' (or it is in the trash); not placed, items are not created"
        )
        expect { provider.update(context, missing, should_for(missing, 'Lab')) }.to raise_error(Puppet::ResourceError, %r{nope})
        expect(transport).not_to have_received(:post)
        expect(transport).not_to have_received(:patch)
        expect(context).not_to have_received(:warning)
      end
    end
  end

  describe 'update' do
    it 'PATCHes the resolved location id' do
      provider.update(context, item('NetworkEquipment', 'edge1'), should_for(item('NetworkEquipment', 'edge1'), 'Main office > Branch'))
      expect(transport).to have_received(:patch).with(context, '/Assets/NetworkEquipment/21', { 'location' => 2 })
    end

    it '"" clears the location' do
      provider.update(context, item('NetworkEquipment', 'core1'), should_for(item('NetworkEquipment', 'core1'), ''))
      expect(transport).to have_received(:patch).with(context, '/Assets/NetworkEquipment/20', { 'location' => 0 })
    end

    it 'writes nothing when already in place' do
      provider.update(context, item('NetworkEquipment', 'core1'), should_for(item('NetworkEquipment', 'core1'), 'Branch'))
      expect(transport).not_to have_received(:patch)
    end

    it 'set updates although the type has no ensure' do
      name = item('DataCenter', 'dc2')
      provider.set(context, name => { is: is_for(name), should: should_for(name, 'Lab') })
      expect(transport).to have_received(:patch).with(context, '/Management/DataCenter/31', { 'location' => 3 })
    end
  end

  describe 'without the transport file' do
    before(:each) { File.delete(config_file) }

    it 'get reports nothing, insync? defers to set, set re-reads once the file exists' do
      name = item('NetworkEquipment', 'edge1')
      expect(provider.get(context, [name])).to eq([])
      expect(provider.insync?(context, name, :location, nil, should_for(name, 'Lab'))).to be_nil
      File.write(config_file, config.to_yaml)
      provider.set(context, name => { is: nil, should: should_for(name, 'Lab') })
      expect(transport).to have_received(:patch).with(context, '/Assets/NetworkEquipment/21', { 'location' => 3 })
    end
  end
end
# rubocop:enable RSpec/MessageSpies
