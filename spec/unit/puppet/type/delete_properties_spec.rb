# frozen_string_literal: true

require 'spec_helper'

# Every type with an optional property its provider can clear exposes
# delete_properties, and declares custom_insync so the provider's comparison
# runs at all: without it the attribute would never be in sync. The value is
# the attribute names each type can clear.
TYPES_WITH_DELETE_PROPERTIES = {
  glpi_appliance:    { title: { name: 'a' }, clearable: ['appliance_type', 'comment', 'environment'] },
  glpi_certificate:  { title: { name: 'c' }, clearable: ['comment', 'dns_name', 'expiration', 'serial'] },
  glpi_cluster:      { title: { name: 'c' }, clearable: ['cluster_type', 'comment'] },
  glpi_custom_asset: { title: { title: 'Website/w' }, clearable: ['asset_type', 'comment'] },
  glpi_domain:       { title: { name: 'd' }, clearable: ['comment', 'expiration'] },
  glpi_location:     { title: { title: 'l' }, clearable: ['comment'] },
}.freeze

RSpec.describe 'delete_properties' do
  TYPES_WITH_DELETE_PROPERTIES.each do |type_name, spec|
    describe type_name.to_s do
      let(:type) do
        require "puppet/type/#{type_name}"
        Puppet::Type.type(type_name)
      end

      it 'declares custom_insync so the provider decides when the deletion is done' do
        expect(type.context.type.feature?('custom_insync')).to be(true)
      end

      it 'is a property, so a pending deletion triggers an update' do
        expect(type.attrtype(:delete_properties)).to eq(:property)
      end

      it "accepts #{spec[:clearable].join(' and ')}" do
        resource = type.new(spec[:title].merge(delete_properties: spec[:clearable]))
        expect(resource[:delete_properties]).to eq(spec[:clearable])
      end

      it 'clears only optional attributes of the type' do
        optional = type.type_definition.attributes.select { |_n, o| o[:type].start_with?('Optional[') }.keys.map(&:to_s)
        expect(optional).to include(*spec[:clearable])
      end

      it 'stays optional, so no existing resource has to declare it' do
        expect(type.new(spec[:title])[:delete_properties]).to be_nil
      end

      it 'rejects an attribute the provider cannot clear' do
        expect { type.new(spec[:title].merge(delete_properties: ['name'])) }.to raise_error(Puppet::ResourceError)
      end

      it 'rejects a non-array value' do
        expect { type.new(spec[:title].merge(delete_properties: spec[:clearable].first)) }.to raise_error(Puppet::ResourceError)
      end
    end
  end

  # Through the RAL, as an agent run evaluates it: the Resource API hands the
  # property's insync? to the provider because of custom_insync.
  describe 'evaluated through the RAL' do
    let(:type) do
      require 'puppet/type/glpi_cluster'
      Puppet::Type.type(:glpi_cluster)
    end
    let(:resource) { type.new(name: 'c', delete_properties: ['comment']) }
    let(:current) { { ensure: 'present', name: 'c', cluster_type: '' } }

    # An agent run retrieves each resource before checking it, and the Resource
    # API (2.x) caches that state per provider for the run; start every example
    # with an empty cache, as a new run would.
    before(:each) { type.instance_variable_set(:@rsapi_provider_get_cache, nil) }

    it 'is out of sync while GLPI still holds a comment' do
      allow(type.my_provider).to receive(:get).and_return([current.merge(comment: 'old')])
      resource.retrieve
      expect(resource.property(:delete_properties).insync?(nil)).to be(false)
    end

    it 'is in sync once the comment is gone' do
      allow(type.my_provider).to receive(:get).and_return([current.merge(comment: '')])
      resource.retrieve
      expect(resource.property(:delete_properties).insync?(nil)).to be(true)
    end
  end

  # Types left out on purpose, so adding one is a deliberate decision.
  it 'is not offered where a value has no empty form or the attribute is a placement' do
    ['glpi_computer_placement', 'glpi_config', 'glpi_item_placement', 'glpi_rule'].each do |type_name|
      require "puppet/type/#{type_name}"
      expect(Puppet::Type.type(type_name.to_sym).validattr?(:delete_properties)).to be(false), type_name
    end
  end
end
