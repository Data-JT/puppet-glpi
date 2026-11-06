# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_item_placement'

RSpec.describe 'the glpi_item_placement type' do
  let(:type) { Puppet::Type.type(:glpi_item_placement) }
  let(:definition) { type.type_definition }

  it 'declares the features the base provider relies on' do
    expect(definition.feature?('simple_get_filter')).to be true
    expect(definition.feature?('custom_insync')).to be true
  end

  it 'autorequires the transport file' do
    expect(type.ancestors).to include(Puppet::Type::GlpiTransportAutorequire::DeletionPlanHook)
  end

  it 'is not ensurable' do
    expect(definition.ensurable?).to be false
  end

  it 'identifies an item by itemtype and name' do
    expect(definition.namevars).to contain_exactly(:itemtype, :name)
  end

  it 'takes itemtype and name from an ItemType/Name title' do
    resource = type.new(title: 'DataCenter/dc1')
    expect([resource[:itemtype], resource[:name]]).to eq(['DataCenter', 'dc1'])
  end

  it 'two itemtypes, same name, are two resources' do
    catalog = Puppet::Resource::Catalog.new
    ['NetworkEquipment/core1', 'DataCenter/core1'].each do |title|
      catalog.add_resource(type.new(Puppet::Resource.new(:glpi_item_placement, title)))
    end
    expect(catalog.resources.map(&:title)).to contain_exactly('NetworkEquipment/core1', 'DataCenter/core1')
  end

  it 'refuses an itemtype outside the supported two' do
    expect { type.new(title: 'Computer/web1') }.to raise_error(Puppet::Error)
  end
end
