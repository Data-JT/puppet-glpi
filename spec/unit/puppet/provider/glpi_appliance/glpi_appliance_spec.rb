# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../../../../lib/puppet/provider/glpi_appliance/glpi_appliance'

# rubocop:disable RSpec/MessageSpies
RSpec.describe Puppet::Provider::GlpiAppliance::GlpiAppliance do
  subject(:provider) { described_class.new }

  let(:marker) { '[managed by puppet]' }
  let(:config_dir) { Dir.mktmpdir('glpi-appliance-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password',
      'marker' => marker, 'purge_max_fraction' => 0.5
    }
  end
  let(:transport) { instance_double('Puppet::Transport::Glpi') }
  let(:type) { instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_appliance', namevars: [:name], ensurable?: true) }
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }
  let(:path) { '/Assets/Appliance' }

  let(:shop) do
    { 'id' => 1, 'name' => 'Web shop', 'comment' => "#{marker}\nShop &#38; blog", 'is_deleted' => false,
      'type' => { 'id' => 1, 'name' => 'Service' }, 'environment' => { 'id' => 2, 'name' => 'Production' } }
  end
  let(:handmade) { { 'id' => 2, 'name' => 'Hand made', 'comment' => 'kept by a human', 'is_deleted' => false, 'type' => nil, 'environment' => nil } }
  let(:trashed) { { 'id' => 3, 'name' => 'Old shop', 'comment' => marker, 'is_deleted' => true, 'type' => nil, 'environment' => nil } }
  let(:appliances) { [shop, handmade, trashed] }

  let(:computers) do
    [
      { 'id' => 10, 'name' => 'web1.example.com', 'is_deleted' => false },
      { 'id' => 11, 'name' => 'db1', 'is_deleted' => false },
      { 'id' => 12, 'name' => 'web2.example.com', 'is_deleted' => false },
      { 'id' => 13, 'name' => 'gone.example.com', 'is_deleted' => true },
    ]
  end
  let(:clusters) { [{ 'id' => 5, 'name' => 'Cluster A', 'is_deleted' => false }] }
  let(:monitors) { [{ 'id' => 7, 'name' => 'Screen 1', 'is_deleted' => false }] }
  let(:appliance_types) { [{ 'id' => 1, 'name' => 'Service' }] }
  let(:environments) { [{ 'id' => 2, 'name' => 'Production' }] }

  let(:links) do
    [
      { 'id' => 100, 'itemtype' => 'Computer', 'items_id' => 10, 'appliance' => { 'id' => 1 } },
      { 'id' => 101, 'itemtype' => 'Computer', 'items_id' => 11, 'appliance' => { 'id' => 1 } },
      { 'id' => 102, 'itemtype' => 'Monitor', 'items_id' => 7, 'appliance' => { 'id' => 1 } },
      { 'id' => 103, 'itemtype' => 'Glpi\\CustomAsset\\WebsiteAsset', 'items_id' => 3, 'appliance' => { 'id' => 1 } },
      { 'id' => 104, 'itemtype' => 'Cluster', 'items_id' => 5, 'appliance' => { 'id' => 1 } },
      { 'id' => 200, 'itemtype' => 'Computer', 'items_id' => 12, 'appliance' => { 'id' => 2 } },
    ]
  end

  def copy(list)
    Marshal.load(Marshal.dump(list))
  end

  before(:each) do
    File.write(config_file, config.to_yaml)
    allow(described_class).to receive_messages(config_path: config_file, build_transport: transport)
    lists = { path => -> { appliances }, '/Assets/Computer' => -> { computers }, '/Management/Cluster' => -> { clusters },
              '/Assets/Monitor' => -> { monitors }, '/Dropdowns/ApplianceType' => -> { appliance_types },
              '/Dropdowns/ApplianceEnvironment' => -> { environments } }
    allow(transport).to receive(:get_all) { |_ctx, p, _q| copy(lists.fetch(p).call) }
    allow(transport).to receive(:get) do |_ctx, p, _q = nil|
      collection, id = p.match(%r{\A(.+)/(\d+)\z}).captures
      copy(lists.fetch(collection).call.find { |o| o['id'].to_s == id })
    end
    allow(transport).to receive(:graphql_all).with(context, 'Appliance_Item', anything) { copy(links) }
    # A created object is stored, so the read-back after the POST finds it.
    allow(transport).to receive(:post) do |_ctx, p, body|
      lists[p]&.call&.push(body.merge('id' => 99, 'is_deleted' => false))
      { 'id' => 99 }
    end
    allow(transport).to receive(:patch)
    allow(transport).to receive(:delete)
    allow(type).to receive(:feature?).and_return(false)
    allow(type).to receive(:feature?).with('simple_get_filter').and_return(true)
    [:debug, :info, :notice, :warning, :err].each { |level| allow(context).to receive(level) }
  end

  after(:each) { FileUtils.remove_entry(config_dir) }

  def member(itemtype, name)
    { 'itemtype' => itemtype, 'name' => name }
  end

  def should_for(name, overrides = {})
    { name: name, ensure: 'present', member_types: ['Computer'] }.merge(overrides)
  end

  def is_for(name)
    provider.get(context, [name]).first
  end

  it 'can be loaded twice without constant warnings' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_appliance/glpi_appliance.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  describe 'get' do
    it 'maps type, environment and the comment without the marker (decoded)' do
      provider.declare_member_types('Web shop', ['Computer'])
      expect(is_for('Web shop')).to include(name: 'Web shop', ensure: 'present', appliance_type: 'Service',
                                            environment: 'Production', comment: 'Shop & blog')
    end

    it 'members of an itemtype outside member_types are ignored on read and never removed' do
      provider.declare_member_types('Web shop', ['Computer'])
      expect(is_for('Web shop')[:members]).to eq([member('Computer', 'db1'), member('Computer', 'web1.example.com')])

      provider.update(context, 'Web shop', should_for('Web shop', members: [member('Computer', 'web1.example.com')]))
      expect(transport).to have_received(:delete).once
      expect(transport).to have_received(:delete).with(context, '/Assets/Computer/11/Appliance/101')
    end

    it 'reads every supported itemtype when no member_types were declared (puppet resource)' do
      expect(is_for('Web shop')[:members]).to contain_exactly(
        member('Computer', 'db1'), member('Computer', 'web1.example.com'), member('Monitor', 'Screen 1'), member('Cluster', 'Cluster A')
      )
    end

    it 'never sees trashed appliances' do
      expect(provider.get(context, ['Old shop'])).to eq([])
      expect(provider.get(context, []).map { |r| r[:name] }).to eq(['Web shop'])
    end

    it 'reports an unmarked same-name appliance present (skip_unmarked)' do
      expect(is_for('Hand made')).to include(name: 'Hand made', comment: 'kept by a human')
    end
  end

  describe 'insync?' do
    it 'member order does not matter' do
      is = is_for('Web shop')
      should = should_for('Web shop', members: [member('Computer', 'db1'), member('Computer', 'web1.example.com')])
      reversed = should_for('Web shop', members: should[:members].reverse)
      expect(provider.insync?(context, 'Web shop', :members, is, should)).to be true
      expect(provider.insync?(context, 'Web shop', :members, is, reversed)).to be true
    end

    it 'matches computers case-insensitively and by first label (agents may register short names)' do
      is = is_for('Web shop')
      should = should_for('Web shop', members: [member('Computer', 'DB1.example.com'), member('Computer', 'WEB1.example.com')])
      expect(provider.insync?(context, 'Web shop', :members, is, should)).to be true
    end

    it 'compares only the links of member_types' do
      is = is_for('Web shop')
      should = should_for('Web shop', member_types: ['Computer', 'Cluster'],
                                      members: [member('Computer', 'db1'), member('Computer', 'web1.example.com'), member('Cluster', 'Cluster A')])
      expect(provider.insync?(context, 'Web shop', :members, is, should)).to be true
    end

    it 'reports what would be linked and unlinked' do
      is = is_for('Web shop')
      should = should_for('Web shop', members: [member('Computer', 'web1.example.com'), member('Computer', 'web2.example.com')])
      result, message = provider.insync?(context, 'Web shop', :members, is, should)
      expect(result).to be false
      expect(message).to match(%r{link Computer 'web2.example.com'.*unlink Computer 'db1'})
    end

    it 'skips a member that matches no object (trashed included), with a warning' do
      is = is_for('Web shop')
      should = should_for('Web shop', members: [member('Computer', 'db1'), member('Computer', 'web1.example.com'), member('Computer', 'gone.example.com')])
      expect(provider.insync?(context, 'Web shop', :members, is, should)).to be true
      expect(context).to have_received(:warning).with("glpi_appliance 'Web shop': no Computer matches 'gone.example.com'; member skipped")
    end

    it 'warn mode: update links the resolvable members and warns about the rest, without failing' do
      should = should_for('Web shop', members: [member('Computer', 'web2.example.com'), member('Computer', 'gone.example.com')])
      expect { provider.update(context, 'Web shop', should) }.not_to raise_error
      expect(transport).to have_received(:post).with(context, '/Assets/Computer/12/Appliance', { 'appliance' => 1 })
      expect(context).to have_received(:warning).with(%r{no Computer matches 'gone.example.com'})
    end

    it 'fails a member whose itemtype is not in member_types' do
      is = is_for('Web shop')
      should = should_for('Web shop', members: [member('Cluster', 'Cluster A')])
      expect { provider.insync?(context, 'Web shop', :members, is, should) }.to raise_error(Puppet::ResourceError, %r{member_types})
    end

    it 'compares type and environment by name' do
      is = is_for('Web shop')
      expect(provider.insync?(context, 'Web shop', :appliance_type, is, should_for('Web shop', appliance_type: ' Service'))).to be true
      expect(provider.insync?(context, 'Web shop', :environment, is, should_for('Web shop', environment: 'Test'))).to be false
    end

    it 'unmarked same-name appliance: warning, no change' do
      is = is_for('Hand made')
      should = should_for('Hand made', comment: 'other', members: [])
      expect(provider.insync?(context, 'Hand made', :comment, is, should)).to be true
      expect(provider.insync?(context, 'Hand made', :members, is, should)).to be true
      provider.update(context, 'Hand made', should)
      provider.create(context, 'Hand made', should)
      expect(context).to have_received(:warning).with(%r{'Hand made' left unchanged: it does not carry the marker}).at_least(:once)
      [:post, :patch, :delete].each { |verb| expect(transport).not_to have_received(verb) }
    end
  end

  describe "unresolved members with unresolved => 'fail'" do
    before(:each) { File.write(config_file, config.merge('unresolved' => 'fail').to_yaml) }

    let(:wanted) { [member('Computer', 'db1'), member('Computer', 'web1.example.com'), member('Computer', 'gone.example.com')] }

    it 'insync? fails the resource with the warning text when the links are otherwise in sync, no warning' do
      should = should_for('Web shop', members: wanted)
      expect { provider.insync?(context, 'Web shop', :members, is_for('Web shop'), should) }.to raise_error(
        Puppet::ResourceError, "glpi_appliance 'Web shop': no Computer matches 'gone.example.com'; member skipped"
      )
      expect(context).not_to have_received(:warning)
    end

    it 'joins several unresolved members into one failure' do
      should = should_for('Web shop', members: wanted + [member('Computer', 'nowhere.example.com')])
      expect { provider.insync?(context, 'Web shop', :members, is_for('Web shop'), should) }.to raise_error(
        Puppet::ResourceError, %r{'gone.example.com'; member skipped; glpi_appliance 'Web shop': no Computer matches 'nowhere.example.com'}
      )
    end

    it 'with links to change: insync? reports the change, update links the resolvable members, then fails' do
      should = should_for('Web shop', members: [member('Computer', 'web2.example.com'), member('Computer', 'gone.example.com')])
      result, message = provider.insync?(context, 'Web shop', :members, is_for('Web shop'), should)
      expect(result).to be false
      expect(message).to match(%r{link Computer 'web2.example.com'})
      expect { provider.update(context, 'Web shop', should) }.to raise_error(Puppet::ResourceError, %r{no Computer matches 'gone.example.com'})
      expect(transport).to have_received(:post).with(context, '/Assets/Computer/12/Appliance', { 'appliance' => 1 })
      expect(transport).to have_received(:delete).with(context, '/Assets/Computer/10/Appliance/100')
    end

    it 'does not fail a second time in set when insync? already failed the resource (another attribute changed)' do
      should = should_for('Web shop', comment: 'New', members: wanted)
      expect { provider.insync?(context, 'Web shop', :members, is_for('Web shop'), should) }.to raise_error(Puppet::ResourceError)
      expect { provider.update(context, 'Web shop', should) }.not_to raise_error
      expect(transport).to have_received(:patch).with(context, "#{path}/1", hash_including('comment' => "#{marker}\nNew"))
    end

    it 'create links the resolvable members, then fails' do
      appliances << { 'id' => 99, 'name' => 'New app', 'comment' => marker, 'is_deleted' => false }
      allow(transport).to receive(:get_all).with(context, path, anything).and_return(copy([shop, handmade]), copy(appliances))
      should = should_for('New app', members: [member('Computer', 'web1.example.com'), member('Computer', 'gone.example.com')])
      expect { provider.create(context, 'New app', should) }.to raise_error(Puppet::ResourceError, %r{'New app': no Computer matches 'gone.example.com'})
      expect(transport).to have_received(:post).with(context, '/Assets/Computer/10/Appliance', { 'appliance' => 99 })
    end

    it 'all members resolvable and in sync: no failure' do
      should = should_for('Web shop', members: wanted.first(2))
      expect(provider.insync?(context, 'Web shop', :members, is_for('Web shop'), should)).to be true
    end
  end

  describe 'update' do
    it 'writes the comment marker-first and the type and environment by id' do
      provider.update(context, 'Web shop', should_for('Web shop', comment: 'New', appliance_type: 'Service', environment: 'Production'))
      expect(transport).to have_received(:patch).with(context, "#{path}/1", { 'comment' => "#{marker}\nNew", 'type' => 1, 'environment' => 2 })
    end

    it 'keeps the stored comment when none is declared, and an empty type means none' do
      provider.update(context, 'Web shop', should_for('Web shop', appliance_type: ''))
      expect(transport).to have_received(:patch).with(context, "#{path}/1", { 'comment' => "#{marker}\nShop & blog", 'type' => 0 })
    end

    it 'links new members before unlinking old ones' do
      provider.update(context, 'Web shop', should_for('Web shop', members: [member('Computer', 'web2.example.com')]))
      expect(transport).to have_received(:post).with(context, '/Assets/Computer/12/Appliance', { 'appliance' => 1 }).ordered
      expect(transport).to have_received(:delete).with(context, '/Assets/Computer/10/Appliance/100').ordered
      expect(transport).to have_received(:delete).with(context, '/Assets/Computer/11/Appliance/101').ordered
    end

    it 'fails before writing any link when an itemtype cannot be linked through the API' do
      links.reject! { |l| l['itemtype'] == 'Cluster' }
      should = should_for('Web shop', member_types: ['Computer', 'Cluster'],
                                      members: [member('Computer', 'web2.example.com'), member('Cluster', 'Cluster A')])
      expect { provider.update(context, 'Web shop', should) }.to raise_error(Puppet::ResourceError, %r{cannot link a Cluster})
      expect(transport).not_to have_received(:post)
      expect(transport).not_to have_received(:delete)
    end

    it 'leaves members alone when none are declared' do
      provider.update(context, 'Web shop', should_for('Web shop', comment: 'x'))
      expect(transport).not_to have_received(:post)
      expect(transport).not_to have_received(:delete)
    end
  end

  describe 'create' do
    it 'POSTs entity 0, recursive, marker-first comment, type and environment, then links the members' do
      appliances << { 'id' => 99, 'name' => 'New app', 'comment' => marker, 'is_deleted' => false }
      allow(transport).to receive(:get_all).with(context, path, anything).and_return(copy([shop, handmade]), copy(appliances))
      provider.create(context, 'New app', should_for('New app', appliance_type: 'Service', environment: 'Production',
                                                                members: [member('Computer', 'web1.example.com')]))
      expect(transport).to have_received(:post).with(
        context, path, { 'name' => 'New app', 'comment' => marker, 'type' => 1, 'environment' => 2, 'entity' => 0, 'is_recursive' => true }
      )
      expect(transport).to have_received(:post).with(context, '/Assets/Computer/10/Appliance', { 'appliance' => 99 })
    end

    it 'creates a missing type or environment by name' do
      provider.create(context, 'New app', should_for('New app', appliance_type: 'Shop', environment: 'Staging'))
      expect(transport).to have_received(:post).with(context, '/Dropdowns/ApplianceType', { 'name' => 'Shop', 'entity' => 0, 'is_recursive' => true })
      expect(transport).to have_received(:post).with(context, '/Dropdowns/ApplianceEnvironment', { 'name' => 'Staging' })
    end

    it 'creates a new appliance next to a trashed one of the same name, never restoring it' do
      provider.create(context, 'Old shop', should_for('Old shop'))
      expect(transport).to have_received(:post).with(context, path, hash_including('name' => 'Old shop'))
      expect(transport).not_to have_received(:patch)
      expect(context).to have_received(:warning).with(%r{trashed.*'Old shop'.*id 3})
    end
  end

  describe 'delete' do
    it 'moves a marked appliance to the trash' do
      provider.get(context, ['Web shop'])
      provider.plan_deletions(1, ['Web shop'])
      provider.delete(context, 'Web shop')
      expect(transport).to have_received(:delete).with(context, "#{path}/1")
    end
  end

  describe 'write-through' do
    it 'reads the link list once for several appliances and records each link written' do
      allow(transport).to receive(:post).with(context, %r{/Appliance\z}, anything).and_return({ 'id' => 300 }, { 'id' => 301 })
      provider.update(context, 'Web shop', should_for('Web shop', members: [member('Computer', 'web1.example.com'), member('Computer', 'web2.example.com')]))
      wanted = should_for('Web shop', members: [member('Computer', 'web1.example.com'), member('Computer', 'web2.example.com')])
      expect(provider.insync?(context, 'Web shop', :members, provider.get(context, ['Web shop']).first, wanted)).to be true
      expect(provider.get(context, ['Hand made']).first[:members]).to eq([member('Computer', 'web2.example.com')])
      expect(transport).to have_received(:graphql_all).once
      expect(transport).to have_received(:get_all).with(context, path, anything).once
      expect(transport).to have_received(:get).with(context, "#{path}/1").once
    end

    it 'reads the links again when a link POST answers without an id' do
      allow(transport).to receive(:post).with(context, %r{/Appliance\z}, anything).and_return(nil)
      provider.update(context, 'Web shop', should_for('Web shop', members: [member('Computer', 'web2.example.com')]))
      provider.get(context, ['Web shop'])
      expect(transport).to have_received(:graphql_all).twice
    end

    it 'drops a trashed appliance from the cache after deleting it' do
      provider.get(context, ['Web shop'])
      provider.plan_deletions(1, ['Web shop'])
      provider.delete(context, 'Web shop')
      expect(provider.get(context, ['Web shop'])).to eq([])
      expect(transport).to have_received(:get_all).with(context, path, anything).once
    end
  end

  describe 'delete_properties' do
    before(:each) { provider.plan_deletions(:run, []) }

    it 'clears comment, type and environment, keeping the marker, and leaves the links alone' do
      provider.get(context, ['Web shop'])
      provider.update(context, 'Web shop', should_for('Web shop', delete_properties: ['appliance_type', 'comment', 'environment']))
      expect(transport).to have_received(:patch).with(context, "#{path}/1", 'comment' => marker, 'type' => 0, 'environment' => 0)
      expect(transport).not_to have_received(:delete)
    end

    it 'never writes an unmarked appliance' do
      is = is_for('Hand made')
      listed = should_for('Hand made', delete_properties: ['comment'])
      expect(provider.insync?(context, 'Hand made', :delete_properties, is, listed)).to be(true)
      provider.update(context, 'Hand made', listed)
      expect(transport).not_to have_received(:patch)
    end

    it 'keeps the stored comment and type of a catalog without it' do
      provider.get(context, ['Web shop'])
      provider.update(context, 'Web shop', should_for('Web shop'))
      expect(transport).to have_received(:patch).with(context, "#{path}/1", 'comment' => "#{marker}\nShop & blog")
    end
  end

  describe 'a member other than a computer' do
    let(:monitors) { [{ 'id' => 7, 'name' => 'Screen', 'is_deleted' => false }, { 'id' => 8, 'name' => 'screen', 'is_deleted' => false }] }

    it 'fails on two matches, with their ids, and writes no link' do
      provider.get(context, ['Web shop'])
      wanted = should_for('Web shop', member_types: ['Monitor'], members: [member('Monitor', 'SCREEN')])
      expect { provider.update(context, 'Web shop', wanted) }.to raise_error(Puppet::ResourceError, %r{2 GLPI Monitor objects match.*7, 8})
      expect(transport).not_to have_received(:post)
    end

    it 'skips one that matches nothing, with a warning' do
      provider.get(context, ['Web shop'])
      provider.update(context, 'Web shop', should_for('Web shop', member_types: ['Monitor'], members: [member('Monitor', 'Nothing')]))
      expect(context).to have_received(:warning).with(%r{no Monitor matches 'Nothing'})
    end
  end

  it 'compares the comment after normalization' do
    is = is_for('Web shop')
    expect(provider.insync?(context, 'Web shop', :comment, is, should_for('Web shop', comment: 'Shop & blog'))).to be(true)
  end
end
# rubocop:enable RSpec/MessageSpies
