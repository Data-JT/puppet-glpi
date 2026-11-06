# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet/type/glpi_certificate'

RSpec.describe 'the glpi_certificate type' do
  let(:type) { Puppet::Type.type(:glpi_certificate) }
  let(:definition) { type.type_definition }

  it 'declares the features the base provider relies on' do
    expect(definition.feature?('simple_get_filter')).to be true
    expect(definition.feature?('custom_insync')).to be true
  end

  it 'autorequires the transport file and installs the deletion-plan hook' do
    expect(type.ancestors).to include(Puppet::Type::GlpiTransportAutorequire::DeletionPlanHook)
  end

  it 'needs nothing but the name; computers_exclusive defaults to true' do
    resource = type.new(Puppet::Resource.new(:glpi_certificate, 'www.example.com'))
    expect(resource.instance_variable_get(:@missing_attrs)).to eq([])
    expect(resource[:computers_exclusive]).to be true
  end

  it 'accepts YYYY-MM-DD or an empty expiration only' do
    expect(type.new(title: 'a', expiration: '2027-02-28')[:expiration]).to eq('2027-02-28')
    expect(type.new(title: 'a', expiration: '')[:expiration]).to eq('')
    expect { type.new(title: 'a', expiration: '28.02.2027') }.to raise_error(Puppet::ResourceError)
  end

  it 'refuses entity and entity_tag together' do
    expect { type.new(title: 'a', entity: 'Customer A', entity_tag: '10001') }
      .to raise_error(Puppet::ResourceError, %r{entity and entity_tag are mutually exclusive})
  end
end
