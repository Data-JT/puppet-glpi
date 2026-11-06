# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_custom_asset'

RSpec.describe 'the glpi_custom_asset type' do
  let(:type) { Puppet::Type.type(:glpi_custom_asset) }
  let(:definition) { type.type_definition }

  it 'declares the features the base provider relies on' do
    expect(definition.feature?('simple_get_filter')).to be true
    expect(definition.feature?('custom_insync')).to be true
  end

  it 'autorequires the transport file and installs the deletion-plan hook' do
    expect(type.ancestors).to include(Puppet::Type::GlpiTransportAutorequire::DeletionPlanHook)
  end

  it 'identifies an asset by definition and name' do
    expect(definition.namevars).to contain_exactly(:definition, :name)
  end

  it 'takes definition and name from a Definition/Name title (the name may contain slashes)' do
    resource = type.new(title: 'Website/example.com/shop')
    expect([resource[:definition], resource[:name]]).to eq(['Website', 'example.com/shop'])
  end

  it 'keeps the same name in two definitions apart in one catalog' do
    catalog = Puppet::Resource::Catalog.new
    [['Website/www.example.com', 'Website'], ['Domain/www.example.com', 'Domain']].each do |title, definition|
      resource = Puppet::Resource.new(:glpi_custom_asset, title)
      catalog.add_resource(type.new(resource))
      expect(catalog.resource(:glpi_custom_asset, title)[:definition]).to eq(definition)
    end
    expect(catalog.resources.map(&:title)).to contain_exactly('Website/www.example.com', 'Domain/www.example.com')
  end

  it 'refuses a title without a definition' do
    expect { type.new(Puppet::Resource.new(:glpi_custom_asset, 'www.example.com', parameters: { definition: 'Website' })) }
      .to raise_error(Puppet::Error, %r{title patterns matched the title "www.example.com"|must be '<definition>/<name>'})
  end

  it 'refuses definition or name attributes that disagree with the title' do
    expect { type.new(Puppet::Resource.new(:glpi_custom_asset, 'Website/a', parameters: { name: 'b' })) }
      .to raise_error(Puppet::ResourceError, %r{must be '<definition>/<name>'.*'Website/b'})
  end

  it 'resolves a relationship by the declared Definition/Name title' do
    catalog = Puppet::Resource::Catalog.new
    asset = Puppet::Resource.new(:glpi_custom_asset, 'Website/www.example.com')
    note = Puppet::Resource.new(:notify, 'after', parameters: { require: 'Glpi_custom_asset[Website/www.example.com]' })
    [asset, note].each { |resource| catalog.add_resource(resource) }
    ral = catalog.to_ral
    edges = ral.resource('Notify[after]').builddepends
    expect(edges.map { |edge| edge.source.ref }).to eq(['Glpi_custom_asset[Website/www.example.com]'])
  end

  it 'accepts fields and field_refs, field_refs defaulting to none' do
    resource = type.new(title: 'Website/www.example.com', fields: { 'url' => 'https://www.example.com/' })
    expect(resource[:fields]).to eq('url' => 'https://www.example.com/')
    expect(resource[:field_refs]).to eq({})
    expect { type.new(title: 'Website/a', field_refs: { 'runs_on' => 'Printer' }) }.to raise_error(Puppet::ResourceError)
  end

  it 'needs nothing but the identity (no mandatory attribute)' do
    resource = type.new(Puppet::Resource.new(:glpi_custom_asset, 'Website/www.example.com'))
    expect(resource.instance_variable_get(:@missing_attrs)).to eq([])
    expect(resource[:fields]).to eq({})
  end

  it 'refuses entity and entity_tag together' do
    expect {
      type.new(title: 'Website/www.example.com', entity: 'Customer A', entity_tag: '10001')
    }.to raise_error(Puppet::ResourceError, %r{entity and entity_tag are mutually exclusive})
  end

  # The Resource API (2.x) caches get per provider for the run: start empty.
  it 'tells the provider the declared fields before reading the state' do
    type.instance_variable_set(:@rsapi_provider_get_cache, nil)
    resource = type.new(title: 'Website/www.example.com', fields: { 'url' => 'x' }, field_refs: { 'url' => 'Computer' })
    expect(type.my_provider).to receive(:declare_fields).with(resource.rsapi_title, { 'url' => 'x' }, { 'url' => 'Computer' })
    allow(type.my_provider).to receive(:get).and_return([])
    resource.retrieve
  end
end
