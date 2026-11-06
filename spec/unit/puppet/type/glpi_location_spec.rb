# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_location'

RSpec.describe 'the glpi_location type' do
  let(:type) { Puppet::Type.type(:glpi_location) }
  let(:definition) { type.type_definition }

  it 'loads' do
    expect(type).not_to be_nil
  end

  it 'declares the features the base provider relies on' do
    expect(definition.feature?('simple_get_filter')).to be true
    expect(definition.feature?('custom_insync')).to be true
  end

  it 'autorequires the transport file and installs the deletion-plan hook' do
    expect(type.ancestors).to include(Puppet::Type::GlpiTransportAutorequire::DeletionPlanHook)
  end

  it 'accepts name, comment and parent' do
    resource = type.new(name: 'North branch', comment: 'Branch office', parent: 'Main office')
    expect(resource[:parent]).to eq('Main office')
  end

  it 'identifies a location by name and parent' do
    expect(definition.namevars).to contain_exactly(:name, :parent)
  end

  it 'takes parent and name from a Parent > Name title' do
    resource = type.new(title: 'Main office > North branch')
    expect([resource[:parent], resource[:name]]).to eq(['Main office', 'North branch'])
  end

  it 'has optional comment and parent' do
    resource = type.new(name: 'Main office')
    expect([resource[:comment], resource[:parent]]).to eq([nil, ''])
  end
end
