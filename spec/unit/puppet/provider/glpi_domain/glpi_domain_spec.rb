# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'webmock/rspec'
require_relative '../../../../support/fake_link_glpi'
require_relative '../../../../../lib/puppet/provider/glpi_domain/glpi_domain'

RSpec.describe Puppet::Provider::GlpiDomain::GlpiDomain do
  subject(:provider) { described_class.new }

  let(:marker) { '[managed by puppet]' }
  let(:config_dir) { Dir.mktmpdir('glpi-domain-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password',
      'marker' => marker, 'purge_max_fraction' => 0.5
    }
  end
  let(:type) do
    instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_domain', namevars: [:name], ensurable?: true)
  end
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }

  let(:domains) do
    [
      { 'id' => 1, 'name' => 'example.com', 'date_expiration' => '2027-02-28 00:00:00', 'comment' => "#{marker}\nMain domain",
        'is_deleted' => false, 'is_active' => false, 'entity' => { 'id' => 3, 'name' => 'Customer A' } },
      { 'id' => 2, 'name' => 'café.example', 'date_expiration' => nil, 'comment' => marker,
        'is_deleted' => false, 'is_active' => false, 'entity' => { 'id' => 0, 'name' => 'Root entity' } },
    ]
  end
  let(:contracts) do
    [
      { 'id' => 40, 'name' => 'Hosting A', 'is_deleted' => false },
      { 'id' => 41, 'name' => 'Hosting B', 'is_deleted' => false },
      { 'id' => 42, 'name' => 'Support', 'is_deleted' => false },
      { 'id' => 43, 'name' => 'Twin', 'is_deleted' => false },
      { 'id' => 44, 'name' => 'twin', 'is_deleted' => false },
      { 'id' => 45, 'name' => 'Ended', 'is_deleted' => true },
    ]
  end
  let(:collections) do
    {
      '/Management/Domain' => domains,
      '/Management/Contract' => contracts,
      '/Administration/Entity' => [
        { 'id' => 0, 'name' => 'Root entity', 'tag' => '', 'parent' => nil },
        { 'id' => 3, 'name' => 'Customer A', 'tag' => '10001', 'parent' => { 'id' => 0, 'name' => 'Root entity' } },
      ],
    }
  end
  # Domain 1 is linked to Hosting A and Support; a Computer item of
  # contract 41 is never read.
  let(:contract_items) do
    [
      { 'id' => 200, 'itemtype' => 'Domain', 'items_id' => 1, 'contract' => { 'id' => 40 } },
      { 'id' => 201, 'itemtype' => 'Domain', 'items_id' => 1, 'contract' => { 'id' => 42 } },
      { 'id' => 202, 'itemtype' => 'Computer', 'items_id' => 1, 'contract' => { 'id' => 41 } },
    ]
  end
  let(:glpi) { FakeLinkGlpi.new(collections, 'Certificate_Item' => [], 'Contract_Item' => contract_items) }

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

  def should_for(name, overrides = {})
    { name: name, ensure: 'present' }.merge(overrides)
  end

  def is_for(name, contracts = nil, scope = nil)
    provider.declare_contracts(name, contracts, scope)
    provider.get(context, [name]).first
  end

  def deep_values(value)
    case value
    when Hash then value.values.flat_map { |v| deep_values(v) }
    when Array then value.flat_map { |v| deep_values(v) }
    else [value]
    end
  end

  def domain_links(domain_id)
    contract_items.select { |row| row['itemtype'] == 'Domain' && row['items_id'] == domain_id }.map { |row| row['contract']['id'] }.sort
  end

  it 'can be loaded twice without constant warnings' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_domain/glpi_domain.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  it 'maps every attribute; without a declared scope every linked contract is read' do
    expect(provider.get(context, ['example.com']).first).to eq(
      name: 'example.com', ensure: 'present', expiration: '2027-02-28', comment: 'Main domain',
      entity: 'Root entity > Customer A', entity_tag: '10001', contracts: ['Hosting A', 'Support']
    )
    expect(glpi.graphql_queries.first).to include('Contract_Item(start: 0, limit: 100, sort: "id", filter: "itemtype==Domain")')
  end

  it 'domain expiration "2027-02-28 00:00:00" is insync with "2027-02-28"' do
    is = is_for('example.com')
    expect(is[:expiration]).to eq('2027-02-28')
    provider.update(context, 'example.com', should_for('example.com', expiration: '2027-02-28', comment: 'Main domain'))
    expect(glpi.writes).to eq([])
  end

  it 'expiration "" clears (sends "", never null); a date is written as YYYY-MM-DD' do
    provider.update(context, 'example.com', should_for('example.com', expiration: ''))
    provider.update(context, 'café.example', should_for('café.example', expiration: '2030-12-31'))
    expect(glpi.writes).to eq([['PATCH', '/Management/Domain/1', { 'date_expiration' => '' }],
                               ['PATCH', '/Management/Domain/2', { 'date_expiration' => '2030-12-31' }]])
    expect(domains[0]['date_expiration']).to be_nil
    expect(deep_values(glpi.bodies)).not_to include(nil)
  end

  it 'keeps a Unicode name as declared and matches it' do
    expect(is_for('Café.example')).to include(name: 'Café.example', ensure: 'present')
    provider.create(context, 'new-ä.example', should_for('new-ä.example', expiration: ''))
    expect(glpi.writes('POST').first[2]).to eq('name' => 'new-ä.example', 'comment' => marker, 'date_expiration' => '')
  end

  describe 'contracts' do
    it 'reads only the linked contracts of the scope' do
      expect(is_for('example.com', ['Hosting A'], ['Hosting A', 'Hosting B'])[:contracts]).to eq(['Hosting A'])
      # Scope unset: the declared contracts are the scope.
      expect(is_for('example.com', ['Hosting B'], nil)[:contracts]).to eq([])
    end

    it 'contract outside contract_scope is neither linked nor unlinked' do
      should = should_for('example.com', contracts: ['Hosting B'], contract_scope: ['Hosting A', 'Hosting B'])
      is = is_for('example.com', should[:contracts], should[:contract_scope])
      expect(provider.insync?(context, 'example.com', :contracts, is, should))
        .to eq([false, "contracts: link 'Hosting B'; unlink 'Hosting A'"])
      provider.update(context, 'example.com', should)
      expect(domain_links(1)).to eq([41, 42]) # Support (outside the scope) stays linked

      outside = should_for('example.com', contracts: ['Hosting B', 'Hosting A'], contract_scope: ['Hosting B'])
      expect { provider.update(context, 'example.com', outside) }
        .to raise_error(Puppet::ResourceError, %r{contract 'Hosting A' is not in contract_scope})
      expect(domain_links(1)).to eq([41, 42])
    end

    it 'moving a domain from contract A to B unlinks A and links B when both are in scope' do
      should = should_for('example.com', contracts: ['hosting b'], contract_scope: ['Hosting A', 'Hosting B'])
      provider.update(context, 'example.com', should)
      expect(glpi.writes).to eq([['POST', '/Management/Domain/1/Contract', { 'contract' => { 'id' => 41 } }],
                                 ['DELETE', '/Management/Domain/1/Contract/200', nil]])
      expect(provider.insync?(context, 'example.com', :contracts, is_for('example.com', should[:contracts], should[:contract_scope]), should)).to be true
      expect(glpi.graphql_queries.size).to eq(2) # one paged read for the run
    end

    it 'never links a trashed contract (it matches nothing)' do
      should = should_for('example.com', contracts: ['Ended'], contract_scope: ['Ended'])
      expect(context).to receive(:warning).with(%r{no live contract matches 'Ended'}).once
      provider.update(context, 'example.com', should)
      expect(glpi.writes).to eq([])
    end

    it 'a link row whose contract id comes back null raises instead of reading as no link' do
      contract_items << { 'id' => 204, 'itemtype' => 'Domain', 'items_id' => 2, 'contract' => nil }
      expect { provider.get(context, ['example.com']) }
        .to raise_error(Puppet::ResourceError, %r{link row 204 has no peer id; check the API user's rights})
    end

    it 'plans no removal while a declared contract is unresolved' do
      should = should_for('example.com', contracts: ['Nowhere'], contract_scope: ['Hosting A', 'Nowhere'])
      expect(context).to receive(:warning).with(%r{no live contract matches 'Nowhere'}).once
      provider.update(context, 'example.com', should)
      expect(glpi.writes).to eq([])
      expect(domain_links(1)).to eq([40, 42])
    end

    context 'with an unresolved contract and unresolved => fail' do
      let(:config) { super().merge('unresolved' => 'fail') }

      it 'fails and keeps the existing link' do
        should = should_for('example.com', contracts: ['Nowhere'], contract_scope: ['Hosting A', 'Nowhere'])
        expect { provider.update(context, 'example.com', should) }.to raise_error(Puppet::ResourceError, %r{no live contract matches 'Nowhere'})
        expect(glpi.writes).to eq([])
        expect(domain_links(1)).to eq([40, 42])
      end
    end

    describe 'two live contracts with the same name: unresolved' do
      let(:wanted) { should_for('example.com', contracts: ['Twin'], contract_scope: ['Twin', 'Hosting A']) }

      it 'warn mode: warns, links nothing for it, removes nothing at all' do
        contract_items << { 'id' => 203, 'itemtype' => 'Domain', 'items_id' => 1, 'contract' => { 'id' => 44 } }
        expect(context).to receive(:warning).with(%r{glpi_domain 'example.com': 2 live contracts match 'Twin' \(ids 43, 44\)}).once
        provider.update(context, 'example.com', wanted)
        expect(glpi.writes).to eq([])
        expect(domain_links(1)).to eq([40, 42, 44])
      end

      context 'with unresolved => fail' do
        let(:config) { super().merge('unresolved' => 'fail') }

        it 'raises from insync? when nothing else is to be written' do
          only = should_for('example.com', contracts: ['Twin'], contract_scope: ['Twin'])
          is = is_for('example.com', only[:contracts], only[:contract_scope])
          expect { provider.insync?(context, 'example.com', :contracts, is, only) }
            .to raise_error(Puppet::ResourceError, %r{2 live contracts match 'Twin'})
        end

        it 'raises without removing anything' do
          expect { provider.update(context, 'example.com', wanted) }.to raise_error(Puppet::ResourceError, %r{2 live contracts match 'Twin'})
          expect(glpi.writes).to eq([])
        end
      end
    end
  end

  it 'ensure absent trashes a marked domain' do
    provider.plan_deletions(1, ['example.com'])
    provider.delete(context, 'example.com')
    expect(glpi.writes).to eq([['DELETE', '/Management/Domain/1', nil]])
  end

  describe 'delete_properties' do
    before(:each) { provider.plan_deletions(:run, []) }

    it 'clears the comment and the expiration, keeping the marker and the contract links' do
      is_for('example.com')
      provider.update(context, 'example.com', should_for('example.com', delete_properties: ['comment', 'expiration']))
      expect(glpi.writes).to eq([['PATCH', '/Management/Domain/1', { 'comment' => marker, 'date_expiration' => '' }]])
    end

    it 'sends nothing once they read back empty' do
      is_for('café.example')
      provider.update(context, 'café.example', should_for('café.example', delete_properties: ['comment', 'expiration']))
      expect(glpi.writes).to be_empty
    end
  end

  describe 'insync? of the plain attributes' do
    let(:is) { is_for('example.com') }

    it 'compares the comment after normalization' do
      expect(provider.insync?(context, 'example.com', :comment, is, should_for('example.com', comment: 'Main domain'))).to be(true)
      expect(provider.insync?(context, 'example.com', :comment, is, should_for('example.com', comment: 'Other'))).to be(false)
    end

    it 'compares the entity by the id it resolves to' do
      expect(provider.insync?(context, 'example.com', :entity, is, should_for('example.com', entity: 'Customer A'))).to be(true)
      expect(provider.insync?(context, 'example.com', :entity_tag, is, should_for('example.com', entity_tag: '10001'))).to be(true)
      expect(provider.insync?(context, 'example.com', :entity, is, should_for('example.com', entity: 'Root entity'))).to be(false)
    end

    it 'leaves an undeclared entity and a vanished domain to the default compare' do
      expect(provider.insync?(context, 'example.com', :entity, is, should_for('example.com'))).to be_nil
      provider.get(context, ['example.com'])
      expect(provider.insync?(context, 'gone.example', :entity, is, should_for('gone.example', entity: 'Customer A'))).to be_nil
    end
  end
end
