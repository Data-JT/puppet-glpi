# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../../../../lib/puppet/provider/glpi_config/glpi_config'
require_relative '../../../../../lib/puppet/type/glpi_config'

# rubocop:disable RSpec/MessageSpies
RSpec.describe Puppet::Provider::GlpiConfig::GlpiConfig do
  subject(:provider) { described_class.new }

  let(:config_dir) { Dir.mktmpdir('glpi-config-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password'
    }
  end
  let(:transport) { instance_double('Puppet::Transport::Glpi') }
  let(:type) { instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_config', namevars: [:name], ensurable?: false) }
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }
  let(:store) do
    { 'inventory/stale_agents_delay' => '14', 'inventory/import_process' => 0, 'inventory/empty' => nil }
  end

  def not_found
    Puppet::Transport::Glpi::ApiError.new('GLPI API error 404', status: 404)
  end

  before(:each) do
    File.write(config_file, config.to_yaml)
    allow(described_class).to receive_messages(config_path: config_file, build_transport: transport)
    allow(transport).to receive(:get) do |_ctx, path, _q = nil|
      key = path.delete_prefix('/Setup/Config/')
      raise not_found unless store.key?(key)

      context_name, name = key.split('/', 2)
      { 'context' => context_name, 'name' => name, 'value' => store[key] }
    end
    allow(transport).to receive(:patch) { |_ctx, path, body| store[path.delete_prefix('/Setup/Config/')] = body['value'] }
    allow(transport).to receive(:post)
    allow(transport).to receive(:delete)
    allow(transport).to receive(:get_all)
    allow(context).to receive(:updating) { |_name, &block| block.call }
    [:debug, :info, :notice, :warning, :err].each { |level| allow(context).to receive(level) }
  end

  after(:each) { FileUtils.remove_entry(config_dir) }

  def should_for(name, value)
    { name: name, value: value }
  end

  it 'can be loaded twice without constant warnings' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_config/glpi_config.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  describe 'get' do
    it 'lists nothing without names (no purge, no puppet resource listing)' do
      expect(provider.get(context)).to eq([])
      expect(provider.get(context, [])).to eq([])
      expect(transport).not_to have_received(:get)
    end

    it 'reads one key by context and name' do
      expect(provider.get(context, ['inventory/stale_agents_delay'])).to eq([{ name: 'inventory/stale_agents_delay', value: '14' }])
      expect(transport).to have_received(:get).with(context, '/Setup/Config/inventory/stale_agents_delay', nil)
    end

    it 'value compares as string: a number from the API reads as its string' do
      expect(provider.get(context, ['inventory/import_process'])).to eq([{ name: 'inventory/import_process', value: '0' }])
      expect(provider.insync?(context, 'inventory/import_process', :value, nil, should_for('inventory/import_process', '0'))).to be true
    end

    it 'reads a null value as the empty string' do
      expect(provider.get(context, ['inventory/empty'])).to eq([{ name: 'inventory/empty', value: '' }])
    end

    it 'leaves an unknown key out' do
      expect(provider.get(context, ['inventory/nope'])).to eq([])
    end

    it 'does not hide other API errors' do
      allow(transport).to receive(:get).and_raise(Puppet::Transport::Glpi::ApiError.new('GLPI API error 500', status: 500))
      expect { provider.get(context, ['inventory/stale_agents_delay']) }.to raise_error(Puppet::ResourceError, %r{500})
    end
  end

  describe 'unknown key' do
    it 'fails the resource instead of creating it (PATCH would create it)' do
      expect {
        provider.insync?(context, 'inventory/nope', :value, nil, should_for('inventory/nope', '1'))
      }.to raise_error(Puppet::ResourceError, %r{no GLPI configuration key 'inventory/nope'.*not created})
      expect { provider.update(context, 'inventory/nope', should_for('inventory/nope', '1')) }.to raise_error(Puppet::ResourceError, %r{not created})
      expect(transport).not_to have_received(:patch)
    end
  end

  describe 'update' do
    it 'patches only the value of the addressed key' do
      provider.update(context, 'inventory/stale_agents_delay', should_for('inventory/stale_agents_delay', '15'))
      expect(transport).to have_received(:patch).with(context, '/Setup/Config/inventory/stale_agents_delay', { 'value' => '15' })
    end

    it 'does not patch when the value already matches' do
      provider.update(context, 'inventory/stale_agents_delay', should_for('inventory/stale_agents_delay', '14'))
      expect(transport).not_to have_received(:patch)
    end

    it 'set only ever updates, never posts or deletes' do
      provider.set(context, 'inventory/stale_agents_delay' => { is: nil, should: should_for('inventory/stale_agents_delay', '15') })
      expect(store['inventory/stale_agents_delay']).to eq('15')
      expect(transport).not_to have_received(:post)
      expect(transport).not_to have_received(:delete)
    end
  end

  describe 'secret keys' do
    it 'refuses to read or write them, without echoing a value' do
      name = 'inventory/basic_auth_password'
      expect { provider.get(context, [name]) }.to raise_error(Puppet::ResourceError, %r{secret})
      expect { provider.update(context, name, should_for(name, 'hunter2')) }.to raise_error(Puppet::ResourceError) { |e| expect(e.message).not_to include('hunter2') }
      expect(transport).not_to have_received(:get)
      expect(transport).not_to have_received(:patch)
    end
  end

  describe 'update-only contract' do
    it 'never creates, marks or lists keys' do
      expect(provider.adoption_policy).to eq(:match_only)
      expect(provider.creatable?).to be(false)
      expect(provider.collection_path).to eq('/Setup/Config')
    end

    it 'refuses a name that is not <context>/<key>' do
      expect { provider.get(context, ['inventory']) }.to raise_error(Puppet::ResourceError, %r{not <context>/<key>})
    end
  end

  describe 'without the transport file (first run)' do
    let(:name) { 'inventory/stale_agents_delay' }

    before(:each) { File.delete(config_file) }

    it 'reports nothing and leaves the comparison to the default' do
      expect(provider.get(context, [name])).to eq([])
      expect(provider.insync?(context, name, :value, nil, should_for(name, '30'))).to be_nil
    end

    it 'falls back to the default comparison when the file goes away during insync?' do
      expect(provider.insync?(context, name, :value, nil, should_for(name, '30'))).to be_nil
    end

    it 're-reads the real state in set and writes only what differs' do
      provider.get(context, [name])
      File.write(config_file, config.to_yaml)
      provider.set(context, name => { is: nil, should: should_for(name, '30') })
      expect(store[name]).to eq('30')
    end
  end
end
# rubocop:enable RSpec/MessageSpies
