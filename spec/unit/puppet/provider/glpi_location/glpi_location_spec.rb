# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../../../../../lib/puppet/provider/glpi_location/glpi_location'

# rubocop:disable RSpec/MessageSpies
RSpec.describe Puppet::Provider::GlpiLocation::GlpiLocation do
  subject(:provider) { described_class.new }

  let(:marker) { '[managed by puppet]' }
  let(:config_dir) { Dir.mktmpdir('glpi-location-spec') }
  let(:config_file) { File.join(config_dir, 'glpi_transport.yaml') }
  let(:config) do
    {
      'base_url' => 'https://glpi.example.com/api.php', 'client_id' => 'puppet',
      'client_secret' => 'not-a-real-secret', 'username' => 'svc', 'password' => 'not-a-real-password',
      'marker' => marker, 'purge_max_fraction' => 0.5
    }
  end
  let(:transport) { instance_double('Puppet::Transport::Glpi') }
  let(:type) do
    instance_double('Puppet::ResourceApi::TypeDefinition', name: 'glpi_location', namevars: [:name, :parent], ensurable?: true)
  end
  let(:context) { instance_double('Puppet::ResourceApi::BaseContext', type: type) }
  let(:path) { '/Dropdowns/Location' }

  let(:main) do
    { 'id' => 1, 'name' => 'Main office', 'comment' => 'Head office &#38; lab', 'parent' => nil }
  end
  let(:zurich) do
    { 'id' => 2, 'name' => 'North branch', 'comment' => 'Café wing, 2nd floor', 'parent' => { 'id' => 1, 'name' => 'Main office' } }
  end
  let(:locations) { [main, zurich] }

  before(:each) do
    File.write(config_file, config.to_yaml)
    allow(described_class).to receive_messages(config_path: config_file, build_transport: transport)
    allow(transport).to receive(:get_all).with(context, path, anything) { locations.map { |l| Marshal.load(Marshal.dump(l)) } }
    allow(transport).to receive(:get) { |_ctx, p, _q = nil| Marshal.load(Marshal.dump(locations.find { |l| "#{path}/#{l['id']}" == p })) }
    # A created location is stored, so the read-back after the POST finds it.
    allow(transport).to receive(:post) do |_c, _p, body|
      id = locations.map { |l| l['id'] }.max + 1
      locations << body.merge('id' => id, 'parent' => body['parent'].to_i.zero? ? nil : { 'id' => body['parent'], 'name' => 'x' })
      { 'id' => id }
    end
    allow(transport).to receive(:patch)
    allow(transport).to receive(:delete)
    allow(type).to receive(:feature?).and_return(false)
    allow(type).to receive(:feature?).with('simple_get_filter').and_return(true)
    allow(type).to receive(:check_schema)
    [:debug, :info, :notice, :warning, :err].each { |level| allow(context).to receive(level) }
    [:creating, :updating, :deleting].each { |action| allow(context).to receive(action).and_yield }
  end

  after(:each) { FileUtils.remove_entry(config_dir) }

  def title(name, parent = nil)
    { name: name, parent: parent || '' }
  end

  def should_for(name, parent = nil, comment = 'x')
    { name: name, parent: parent || '', ensure: 'present', comment: comment }
  end

  it 'can be loaded twice without constant warnings' do
    file = File.expand_path('../../../../../lib/puppet/provider/glpi_location/glpi_location.rb', __dir__)
    expect { load file }.not_to output.to_stderr
  end

  describe 'get' do
    it 'get/set map name+comment+parent, decoding entities' do
      result = provider.get(context, [title('Main office'), title('North branch', 'Main office')])
      expect(result).to eq(
        [
          { title: 'Main office', name: 'Main office', ensure: 'present', comment: 'Head office & lab', parent: '' },
          { title: 'Main office > North branch', name: 'North branch', ensure: 'present', comment: 'Café wing, 2nd floor', parent: 'Main office' },
        ],
      )
    end

    it 'does not match a child when no parent is declared' do
      expect(provider.get(context, [title('North branch')])).to eq([])
    end

    it 'does not match a top-level location when another parent is declared' do
      expect(provider.get(context, [title('Main office', 'North branch')])).to eq([])
    end

    it 'matches the right one when a name exists under two parents' do
      locations << { 'id' => 3, 'name' => 'Annex', 'comment' => 'a', 'parent' => nil }
      locations << { 'id' => 4, 'name' => 'North branch', 'comment' => 'other', 'parent' => { 'id' => 3, 'name' => 'Annex' } }
      expect(provider.get(context, [title('North branch', 'Annex')]).first[:comment]).to eq('other')
      expect(provider.get(context, [title('North branch', 'Main office')]).first[:comment]).to eq('Café wing, 2nd floor')
    end

    it 'resolves nested parents by complete name' do
      locations << { 'id' => 3, 'name' => 'Lab', 'comment' => 'lab', 'parent' => { 'id' => 2, 'name' => 'North branch' } }
      expect(provider.get(context, [title('Lab', 'Main office > North branch')]).first[:comment]).to eq('lab')
    end

    it 'fails alone when the same name and parent exist twice' do
      locations << main.merge('id' => 9)
      expect(provider.get(context, [title('Main office')])).to eq([])
      expect(context).to have_received(:err).with(%r{2 GLPI objects})
    end

    it 'matches name and parent case-insensitively and keeps the declared title' do
      expect(provider.get(context, [title('NORTH Branch', 'main OFFICE')]).first)
        .to include(name: 'NORTH Branch', parent: 'main OFFICE', comment: 'Café wing, 2nd floor')
    end

    it 'resolves a parent for a new location case-insensitively' do
      provider.create(context, title('Annex', 'main office'), should_for('Annex', 'main office'))
      expect(transport).to have_received(:post).with(context, path, hash_including('parent' => 1))
    end

    it 'fails alone when two locations differ only in case' do
      locations << main.merge('id' => 9, 'name' => 'MAIN OFFICE')
      expect(provider.get(context, [title('Main office')])).to eq([])
      expect(context).to have_received(:err).with(%r{2 GLPI objects})
    end

    it 'returns nothing without names, so there is nothing to purge' do
      expect(provider.get(context, [])).to eq([])
    end

    context 'when the list holds a parent location only partially' do
      # The API lists a parent as id/name/entity/parent (no comment).
      let(:partial) { { 'id' => 1, 'name' => 'Main office', 'parent' => nil } }

      before(:each) do
        allow(transport).to receive(:get_all).with(context, path, anything).and_return([partial, Marshal.load(Marshal.dump(zurich))])
      end

      it 'reads the matched location again by id' do
        allow(transport).to receive(:get).with(context, "#{path}/1").and_return(main)
        expect(provider.get(context, [title('Main office')]).first[:comment]).to eq('Head office & lab')
      end

      it 'does not read unmatched partial entries' do
        provider.get(context, [title('North branch', 'Main office')])
        expect(transport).not_to have_received(:get) if transport.respond_to?(:get)
      end

      it 'fails only that resource when the re-read fails' do
        allow(transport).to receive(:get).with(context, "#{path}/1").and_raise(StandardError, 'boom')
        result = provider.get(context, [title('Main office'), title('North branch', 'Main office')])
        expect(result.map { |r| r[:name] }).to eq(['North branch'])
        expect(context).to have_received(:err).with(%r{reading location 1 failed: boom})
      end

      it 'treats an empty re-read as a failure of that resource' do
        allow(transport).to receive(:get).with(context, "#{path}/1").and_return(nil)
        expect(provider.get(context, [title('Main office')])).to eq([])
        expect(context).to have_received(:err).with(%r{returned nothing})
      end
    end
  end

  describe 'insync?' do
    let(:is) { provider.get(context, [title('North branch', 'Main office')]).first }

    it 'comment with accents is insync after normalize (NFD vs NFC)' do
      should = should_for('North branch', 'Main office', "Cafe\u0301 wing, 2nd floor")
      expect(provider.insync?(context, title('North branch', 'Main office'), :comment, is, should)).to be true
    end

    it 'a changed comment is out of sync' do
      expect(provider.insync?(context, title('North branch', 'Main office'), :comment, is, should_for('North branch', 'Main office', 'Other'))).to be false
    end

    it 'ensure absent on any location is a warning no-op' do
      expect(context).to receive(:warning).with(%r{never deletes})
      should = { name: 'North branch', parent: 'Main office', ensure: 'absent' }
      expect(provider.insync?(context, title('North branch', 'Main office'), :ensure, is, should)).to be true
    end
  end

  describe 'update' do
    it 'PATCHes only the comment and never adds the marker or a parent' do
      provider.get(context, [title('North branch', 'Main office')])
      provider.update(context, title('North branch', 'Main office'), should_for('North branch', 'Main office', 'New'))
      expect(transport).to have_received(:patch).with(context, "#{path}/2", { 'comment' => 'New' })
    end

    it 'keeps the stored comment when none is declared (an empty body sends nothing)' do
      provider.update(context, title('Main office'), { name: 'Main office', ensure: 'present' })
      expect(transport).not_to have_received(:patch)
    end
  end

  describe 'create' do
    it 'POSTs entity 0, recursive, parent 0 and the comment, unmarked' do
      provider.create(context, title('Annex'), should_for('Annex', nil, 'Spare'))
      expect(transport).to have_received(:post).with(
        context, path, { 'name' => 'Annex', 'comment' => 'Spare', 'entity' => 0, 'is_recursive' => true, 'parent' => 0 }
      )
    end

    it 'creates at top level, not moving the child, when only a child has that name' do
      provider.create(context, title('North branch'), should_for('North branch'))
      expect(transport).to have_received(:post).with(context, path, hash_including('name' => 'North branch', 'parent' => 0))
      expect(transport).not_to have_received(:patch)
    end

    it 'creates under the declared parent, not moving a same-named child of another parent' do
      locations << { 'id' => 3, 'name' => 'Annex', 'comment' => 'a', 'parent' => nil }
      provider.create(context, title('North branch', 'Annex'), should_for('North branch', 'Annex'))
      expect(transport).to have_received(:post).with(context, path, hash_including('parent' => 3))
      expect(transport).not_to have_received(:patch)
    end

    it 'fails clearly for an unknown parent' do
      expect { provider.create(context, title('Annex', 'Nope'), should_for('Annex', 'Nope')) }
        .to raise_error(Puppet::ResourceError, %r{unknown parent 'Nope'})
    end
  end

  describe 'delete' do
    it 'never deletes' do
      provider.get(context, [title('Main office')])
      provider.delete(context, title('Main office'))
      expect(transport).not_to have_received(:delete)
    end
  end

  describe 'write-through' do
    before(:each) do
      allow(transport).to receive(:post) do |_c, _p, body|
        locations << body.merge('id' => 7, 'parent' => body['parent'].zero? ? nil : { 'id' => body['parent'], 'name' => 'x' })
        { 'id' => 7 }
      end
    end

    it 'caches a created location with its complete name, without reading the list again' do
      provider.create(context, title('Annex', 'Main office'), should_for('Annex', 'Main office', 'Spare'))
      expect(provider.get(context, [title('Annex', 'Main office')])).to eq(
        [{ title: 'Main office > Annex', name: 'Annex', ensure: 'present', comment: 'Spare', parent: 'Main office' }],
      )
      expect(transport).to have_received(:get_all).once
    end

    it 'can be the parent of the next location created in the run' do
      provider.create(context, title('Annex', 'Main office'), should_for('Annex', 'Main office'))
      allow(transport).to receive(:post) do |_c, _p, body|
        locations << body.merge('id' => 8, 'parent' => { 'id' => body['parent'], 'name' => 'Annex' })
        { 'id' => 8 }
      end
      provider.create(context, title('Room 1', 'Main office > Annex'), should_for('Room 1', 'Main office > Annex'))
      expect(transport).to have_received(:post).with(context, path, hash_including('name' => 'Room 1', 'parent' => 7))
    end
  end

  describe 'delete_properties' do
    let(:name) { title('Main office') }
    let(:listed) { { name: 'Main office', parent: '', ensure: 'present', delete_properties: ['comment'] } }

    it 'empties the comment of a location, which carries no marker' do
      provider.get(context, [name])
      provider.update(context, name, listed)
      expect(transport).to have_received(:patch).with(context, "#{path}/1", 'comment' => '')
    end

    it 'is in sync once the comment reads back empty' do
      is = provider.get(context, [name]).first
      expect(provider.insync?(context, name, :delete_properties, is, listed)).to be(false)
      expect(provider.insync?(context, name, :delete_properties, is.merge(comment: ''), listed)).to be(true)
    end

    it 'still keeps a comment that is merely undeclared' do
      provider.get(context, [name])
      provider.update(context, name, listed.except(:delete_properties))
      expect(transport).not_to have_received(:patch)
    end
  end
end
# rubocop:enable RSpec/MessageSpies
