# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'webmock/rspec'
require_relative '../../../../support/fake_link_glpi'
require_relative '../../../../../lib/puppet/provider/glpi_certificate/glpi_certificate'

RSpec.describe Puppet::Provider::GlpiCertificate::GlpiCertificate do
  subject(:provider) { described_class.new }

  let(:marker) { '[managed by puppet]' }
  let(:config_dir) { Dir.mktmpdir('glpi-certificate-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password',
      'marker' => marker, 'purge_max_fraction' => 0.5
    }
  end
  let(:type) do
    instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_certificate', namevars: [:name], ensurable?: true)
  end
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }

  let(:certificates) do
    [
      { 'id' => 1, 'name' => 'www.example.com', 'dns_name' => 'www.example.com', 'serial' => '0A1B',
        'date_expiration' => '2027-02-28', 'is_selfsign' => false, 'comment' => "#{marker}\nShop & co".gsub('&', '&#38;'),
        'is_deleted' => false, 'entity' => { 'id' => 3, 'name' => 'Customer A' } },
      { 'id' => 2, 'name' => 'hand.example.com', 'dns_name' => 'hand.example.com', 'serial' => '', 'date_expiration' => nil,
        'is_selfsign' => 1, 'comment' => 'kept by a human', 'is_deleted' => false, 'entity' => { 'id' => 0, 'name' => 'Root entity' } },
      { 'id' => 3, 'name' => 'old.example.com', 'dns_name' => '', 'serial' => '', 'date_expiration' => nil,
        'is_selfsign' => false, 'comment' => marker, 'is_deleted' => true, 'entity' => { 'id' => 0, 'name' => 'Root entity' } },
    ]
  end
  let(:computers) do
    [
      { 'id' => 10, 'name' => 'web1.example.com', 'is_deleted' => false },
      { 'id' => 11, 'name' => 'db1', 'is_deleted' => false },
      { 'id' => 12, 'name' => 'web2.example.com', 'is_deleted' => false },
    ]
  end
  let(:collections) do
    {
      '/Assets/Certificate' => certificates,
      '/Assets/Computer' => computers,
      '/Administration/Entity' => [
        { 'id' => 0, 'name' => 'Root entity', 'tag' => '', 'parent' => nil },
        { 'id' => 3, 'name' => 'Customer A', 'tag' => '10001', 'parent' => { 'id' => 0, 'name' => 'Root entity' } },
      ],
    }
  end
  # Link rows of certificate 1: computers 10 and 11 (11 twice: GLPI has no
  # unique constraint), and a Domain item that is never read or touched.
  let(:certificate_items) do
    [
      { 'id' => 100, 'itemtype' => 'Computer', 'items_id' => 10, 'certificate' => { 'id' => 1 } },
      { 'id' => 101, 'itemtype' => 'Computer', 'items_id' => 11, 'certificate' => { 'id' => 1 } },
      { 'id' => 102, 'itemtype' => 'Computer', 'items_id' => 11, 'certificate' => { 'id' => 1 } },
      { 'id' => 103, 'itemtype' => 'Domain', 'items_id' => 10, 'certificate' => { 'id' => 1 } },
      { 'id' => 104, 'itemtype' => 'Computer', 'items_id' => 12, 'certificate' => { 'id' => 2 } },
    ]
  end
  let(:glpi) { FakeLinkGlpi.new(collections, 'Certificate_Item' => certificate_items, 'Contract_Item' => []) }

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
    { name: name, ensure: 'present', computers_exclusive: true }.merge(overrides)
  end

  def is_for(name)
    provider.get(context, [name]).first
  end

  def deep_values(value)
    case value
    when Hash then value.values.flat_map { |v| deep_values(v) }
    when Array then value.flat_map { |v| deep_values(v) }
    else [value]
    end
  end

  def computer_rows(certificate_id)
    certificate_items.select { |row| row['itemtype'] == 'Computer' && row['certificate']['id'] == certificate_id }
  end

  it 'can be loaded twice without constant warnings' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_certificate/glpi_certificate.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  it 'maps every attribute; duplicate links of one computer read as one' do
    expect(is_for('www.example.com')).to eq(
      name: 'www.example.com', ensure: 'present', dns_name: 'www.example.com', serial: '0A1B',
      expiration: '2027-02-28', self_signed: false, comment: 'Shop & co',
      entity: 'Root entity > Customer A', entity_tag: '10001', computers: ['db1', 'web1.example.com']
    )
    hand = provider.get(context, ['hand.example.com']).first
    expect(hand).to be_nil # unmarked: adopted on create, reported absent
  end

  it 'reads the links in one filtered, paged GraphQL query shared by every resource' do
    is_for('www.example.com')
    provider.get(context, [])
    # One paged read: the first page, then the empty page that ends it.
    expect(glpi.graphql_queries.size).to eq(2)
    expect(glpi.graphql_queries.first).to include('Certificate_Item(start: 0, limit: 100, sort: "id", filter: "itemtype==Computer")')
  end

  it 'certificate CN case differs from GLPI name: matched, no duplicate' do
    should = should_for('WWW.Example.COM', dns_name: 'www.example.com', computers: ['web1.example.com', 'db1'])
    is = is_for('WWW.Example.COM')
    expect(is).to include(name: 'WWW.Example.COM', ensure: 'present')
    expect(provider.insync?(context, 'WWW.Example.COM', :computers, is, should)).to be true
    provider.create(context, 'WWW.Example.COM', should)
    expect(glpi.writes('POST')).to eq([])
    expect(certificates.count { |c| c['name'].casecmp?('www.example.com') }).to eq(1)
  end

  it 'expiration "" clears (sends "", never null)' do
    is = is_for('www.example.com')
    should = should_for('www.example.com', expiration: '')
    expect(provider.insync?(context, 'www.example.com', :expiration, is, should)).to be_nil # default compare
    provider.update(context, 'www.example.com', should)
    expect(glpi.writes).to eq([['PATCH', '/Assets/Certificate/1', { 'date_expiration' => '' }]])
    expect(certificates[0]['date_expiration']).to be_nil
    expect(is_for('www.example.com')[:expiration]).to eq('')
    expect(deep_values(glpi.bodies)).not_to include(nil)
  end

  it 'writes only what differs; self_signed as is_selfsign' do
    provider.update(context, 'www.example.com', should_for('www.example.com', dns_name: 'www.example.com', serial: '0C',
                                                                              expiration: '2027-02-28', self_signed: true, comment: 'Shop & co'))
    expect(glpi.writes).to eq([['PATCH', '/Assets/Certificate/1', { 'serial' => '0C', 'is_selfsign' => true }]])
  end

  it 'creates a new certificate with every declared attribute, its entity by tag, and links it' do
    provider.create(context, 'new.example.com', should_for('new.example.com', dns_name: 'new.example.com', serial: 'FF',
                                                                              expiration: '2028-01-31', self_signed: false,
                                                                              entity_tag: '10001', computers: ['web2.example.com']))
    post, link = glpi.writes('POST')
    expect(post).to eq(['POST', '/Assets/Certificate',
                        { 'name' => 'new.example.com', 'comment' => marker, 'dns_name' => 'new.example.com', 'serial' => 'FF',
                          'date_expiration' => '2028-01-31', 'is_selfsign' => false, 'entity' => { 'id' => 3 } }])
    new_id = certificates.last['id']
    expect(link).to eq(['POST', '/Assets/Computer/12/Certificate', { 'certificate' => { 'id' => new_id } }])
    expect(is_for('new.example.com')[:computers]).to eq(['web2.example.com'])
  end

  it 'adopts an unmarked certificate of the same name (marker first, comment kept)' do
    provider.create(context, 'hand.example.com', should_for('hand.example.com', serial: '01'))
    expect(glpi.writes).to eq([['PATCH', '/Assets/Certificate/2', { 'comment' => "#{marker}\nkept by a human", 'serial' => '01' }]])
  end

  it 'entity and entity_tag unset are neither compared nor sent' do
    is = is_for('www.example.com')
    should = should_for('www.example.com', serial: 'X')
    expect(provider.insync?(context, 'www.example.com', :entity, is, should)).to be_nil
    provider.update(context, 'www.example.com', should)
    expect(glpi.bodies).to eq([{ 'serial' => 'X' }])
  end

  it 'entity compares by the resolved id' do
    is = is_for('www.example.com')
    expect(provider.insync?(context, 'www.example.com', :entity, is, should_for('www.example.com', entity: 'customer a'))).to be true
    expect(provider.insync?(context, 'www.example.com', :entity, is, should_for('www.example.com', entity: 'Root entity'))).to be false
  end

  it 'a link row whose certificate id comes back null raises instead of reading as no link' do
    certificate_items << { 'id' => 150, 'itemtype' => 'Computer', 'items_id' => 1, 'certificate' => nil }
    expect { provider.get(context, ['www.example.com']) }
      .to raise_error(Puppet::ResourceError, %r{link row 150 has no owner id; check the API user's rights})
  end

  describe 'computers' do
    it 'computers_exclusive false never deletes a link' do
      should = should_for('www.example.com', computers: ['web2.example.com'], computers_exclusive: false)
      is = is_for('www.example.com')
      expect(provider.insync?(context, 'www.example.com', :computers, is, should))
        .to eq([false, "computers: link 'web2.example.com'"])
      provider.update(context, 'www.example.com', should)
      expect(glpi.writes).to eq([['POST', '/Assets/Computer/12/Certificate', { 'certificate' => { 'id' => 1 } }]])
      expect(glpi.writes('DELETE')).to eq([])
      expect(provider.insync?(context, 'www.example.com', :computers, is_for('www.example.com'), should)).to be true
    end

    it 'computers_exclusive true removes an undeclared Computer link and never a Domain link' do
      should = should_for('www.example.com', computers: ['WEB1.example.com'])
      is = is_for('www.example.com')
      expect(provider.insync?(context, 'www.example.com', :computers, is, should)).to eq([false, "computers: unlink 'db1'"])
      provider.update(context, 'www.example.com', should)
      # Both rows of the duplicated pair go: the pair is removed entirely.
      expect(glpi.writes).to contain_exactly(['DELETE', '/Assets/Computer/11/Certificate/101', nil],
                                             ['DELETE', '/Assets/Computer/11/Certificate/102', nil])
      expect(certificate_items.map { |row| row['id'] }).to contain_exactly(100, 103, 104)
      expect(provider.insync?(context, 'www.example.com', :computers, is_for('www.example.com'), should)).to be true
    end

    it 'keeps both rows of a duplicated link that is declared' do
      provider.update(context, 'www.example.com', should_for('www.example.com', computers: ['web1.example.com', 'db1']))
      expect(glpi.writes).to eq([])
    end

    it 'leaves the links alone when computers is unset' do
      provider.update(context, 'www.example.com', should_for('www.example.com', serial: '0A1B'))
      expect(glpi.writes).to eq([])
    end

    it 'one link list per run: a link written is seen by the next resource without a re-read' do
      provider.update(context, 'www.example.com', should_for('www.example.com', computers: ['web1.example.com', 'db1', 'web2.example.com']))
      should = should_for('www.example.com', computers: ['web1.example.com', 'db1', 'web2.example.com'])
      expect(provider.insync?(context, 'www.example.com', :computers, is_for('www.example.com'), should)).to be true
      expect(glpi.graphql_queries.size).to eq(2)
    end

    describe 'a computer that matches nothing' do
      let(:wanted) { should_for('www.example.com', computers: ['web1.example.com', 'db1', 'nowhere.example.com']) }

      it 'warn mode: warns, links the rest' do
        expect(context).to receive(:warning).with(%r{glpi_certificate 'www.example.com': no Computer matches 'nowhere.example.com'}).once
        expect(provider.insync?(context, 'www.example.com', :computers, is_for('www.example.com'), wanted)).to be true
      end

      context 'with unresolved => fail' do
        let(:config) { super().merge('unresolved' => 'fail') }

        it 'raises from insync? when nothing else is to be written' do
          expect { provider.insync?(context, 'www.example.com', :computers, is_for('www.example.com'), wanted) }
            .to raise_error(Puppet::ResourceError, %r{no Computer matches 'nowhere.example.com'})
        end

        it 'writes the resolvable links, then raises' do
          more = should_for('www.example.com', computers: ['web2.example.com', 'nowhere'])
          expect(provider.insync?(context, 'www.example.com', :computers, is_for('www.example.com'), more)).to be_an(Array)
          expect { provider.update(context, 'www.example.com', more) }.to raise_error(Puppet::ResourceError, %r{no Computer matches 'nowhere'})
          expect(glpi.writes('POST')).to eq([['POST', '/Assets/Computer/12/Certificate', { 'certificate' => { 'id' => 1 } }]])
        end
      end
    end
  end

  it 'ensure absent trashes a marked certificate; an unmarked one is never deleted' do
    provider.plan_deletions(1, ['www.example.com'])
    provider.delete(context, 'www.example.com')
    provider.delete(context, 'hand.example.com')
    expect(glpi.writes).to eq([['DELETE', '/Assets/Certificate/1', nil]])
  end

  describe 'delete_properties' do
    let(:all) { ['comment', 'dns_name', 'expiration', 'serial'] }

    before(:each) { provider.plan_deletions(:run, []) }

    it 'sends each listed attribute empty, keeping the marker' do
      provider.get(context, ['www.example.com'])
      provider.update(context, 'www.example.com', should_for('www.example.com', delete_properties: all))
      expect(glpi.writes).to eq([['PATCH', '/Assets/Certificate/1', { 'comment' => marker, 'dns_name' => '', 'serial' => '', 'date_expiration' => '' }]])
    end

    it 'reads back in sync after the clearing update, so it is sent once' do
      listed = should_for('www.example.com', delete_properties: all)
      provider.get(context, ['www.example.com'])
      provider.update(context, 'www.example.com', listed)
      provider.invalidate_objects
      expect(provider.insync?(context, 'www.example.com', :delete_properties, is_for('www.example.com'), listed)).to be(true)
    end

    it 'adopts an unmarked certificate with the marker and without the listed comment' do
      provider.get(context, ['hand.example.com'])
      provider.create(context, 'hand.example.com', should_for('hand.example.com', delete_properties: ['comment']))
      expect(glpi.writes).to eq([['PATCH', '/Assets/Certificate/2', { 'comment' => marker }]])
    end

    it 'sends nothing for a new certificate beyond what is declared' do
      provider.get(context, ['new.example.com'])
      provider.create(context, 'new.example.com', should_for('new.example.com', delete_properties: all))
      expect(glpi.writes('POST').first.last).to eq('name' => 'new.example.com', 'comment' => marker)
    end

    it 'keeps the unresolved dedupe: the target state reaches the entity lookup unchanged' do
      config['unresolved'] = 'fail'
      File.write(config_file, config.to_yaml)
      listed = should_for('www.example.com', entity: 'No such entity', delete_properties: ['serial'])
      provider.get(context, ['www.example.com'])
      expect { provider.insync?(context, 'www.example.com', :entity, is_for('www.example.com'), listed) }.to raise_error(Puppet::ResourceError, %r{No such entity})
      provider.update(context, 'www.example.com', listed)
      expect(glpi.writes).to eq([['PATCH', '/Assets/Certificate/1', { 'serial' => '' }]])
    end
  end

  describe "a computer that matches nothing, with unresolved => 'fail'" do
    before(:each) do
      config['unresolved'] = 'fail'
      File.write(config_file, config.to_yaml)
    end

    let(:wanted) { should_for('www.example.com', computers: ['web1.example.com', 'db1', 'nothing.example.com']) }

    it 'writes the resolvable links first and then fails, once per resource' do
      is_for('www.example.com')
      expect { provider.update(context, 'www.example.com', wanted) }.to raise_error(Puppet::ResourceError, %r{no Computer matches 'nothing.example.com'})
      expect { provider.update(context, 'www.example.com', wanted) }.not_to raise_error
    end
  end
end
