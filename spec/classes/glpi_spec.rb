# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

RSpec.describe 'glpi', type: :class do
  let(:client_secret) { 'client-secret-value-0123456789' }
  let(:password) { 'service-password-value-9876543210' }
  let(:config_file) { File.join(Puppet.settings[:confdir], 'glpi_transport.yaml') }
  let(:params) do
    {
      base_url: 'https://glpi.example.com/api.php',
      client_id: 'puppet',
      client_secret: sensitive(client_secret),
      username: 'puppet-api',
      password: sensitive(password),
    }
  end

  def rendered
    content = catalogue.resource('File', config_file)[:content]
    content = content.unwrap if content.respond_to?(:unwrap)
    YAML.safe_load(content)
  end

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      it { is_expected.to compile.with_all_deps }

      # The default path follows the AGENT's confdir (fact glpi_confdir), not
      # the compiling server's $settings::confdir: an AIO server compiling for
      # a Debian agent must not put the file under /etc/puppetlabs/puppet there.
      context 'when the agent reports a different confdir than the server' do
        let(:facts) { os_facts.merge(glpi_confdir: '/etc/puppet') }

        it { is_expected.to contain_file('/etc/puppet/glpi_transport.yaml').with('ensure' => 'file', 'mode' => '0600') }
        it { is_expected.not_to contain_file(config_file) }
      end

      it 'writes the transport file 0600 with Sensitive content' do
        is_expected.to contain_file(config_file).with(
          'ensure' => 'file',
          'owner'  => 'root',
          'group'  => 'root',
          'mode'   => '0600',
        )
        expect(catalogue.resource('File', config_file).sensitive_parameters).to include(:content)
      end

      it 'renders the connection info and module settings with defaults' do
        expect(rendered).to eq(
          'base_url'           => 'https://glpi.example.com/api.php',
          'client_id'          => 'puppet',
          'client_secret'      => client_secret,
          'username'           => 'puppet-api',
          'password'           => password,
          'grant_type'         => 'password',
          'ssl_verify'         => true,
          'marker'             => '[managed by puppet]',
          'type_markers'       => {},
          'purge_max_fraction' => 0.5,
          'purge_max_per_run'  => 3,
          'unresolved'         => 'warn',
          'restore_trashed'    => false,
          'type_restore_trashed' => {},
        )
      end

      it 'never exposes a secret in a non-sensitive catalog parameter' do
        catalogue.resources.each do |resource|
          resource.to_hash.each do |param, value|
            next if resource.sensitive_parameters.include?(param)

            expect(value.to_s).not_to include(client_secret)
            expect(value.to_s).not_to include(password)
          end
        end
      end

      context 'with every setting' do
        let(:params) do
          super().merge(
            grant_type: 'client_credentials',
            ssl_verify: false,
            ssl_ca_file: '/etc/ssl/certs/ca.pem',
            marker: "[it's ours: #1]",
            type_markers: { 'glpi_cluster' => '[cluster marker]' },
            purge_max_fraction: 0.2,
            unresolved: 'fail',
            restore_trashed: true,
            type_restore_trashed: { 'glpi_cluster' => false },
          )
        end

        it 'writes restore_trashed and type_restore_trashed' do
          expect(rendered).to include('restore_trashed' => true, 'type_restore_trashed' => { 'glpi_cluster' => false })
        end

        it 'renders them as valid YAML, quoting included' do
          expect(rendered).to include(
            'grant_type' => 'client_credentials', 'ssl_verify' => false, 'ssl_ca_file' => '/etc/ssl/certs/ca.pem',
            'marker' => "[it's ours: #1]", 'type_markers' => { 'glpi_cluster' => '[cluster marker]' },
            'purge_max_fraction' => 0.2, 'unresolved' => 'fail'
          )
        end
      end

      context 'with purge_max_per_run' do
        let(:params) { super().merge(purge_max_per_run: 10) }

        it { expect(rendered['purge_max_per_run']).to eq(10) }
      end

      context 'with purge_max_per_run 0 (no absolute cap)' do
        let(:params) { super().merge(purge_max_per_run: 0) }

        it { expect(rendered['purge_max_per_run']).to eq(0) }
      end

      context 'with a negative purge_max_per_run' do
        let(:params) { super().merge(purge_max_per_run: -1) }

        it { is_expected.to compile.and_raise_error(%r{purge_max_per_run}) }
      end

      context 'with purge_max_fraction given as the integer 1' do
        let(:params) { super().merge(purge_max_fraction: 1) }

        it 'writes it as a float' do
          expect(rendered['purge_max_fraction']).to be_a(Float).and eq(1.0)
        end
      end

      context 'with config_file set' do
        let(:params) { super().merge(config_file: '/etc/example/puppet/glpi_transport.yaml') }

        it 'writes the transport file there, 0600 with Sensitive content' do
          is_expected.to contain_file('/etc/example/puppet/glpi_transport.yaml').with('mode' => '0600')
          expect(catalogue.resource('File', '/etc/example/puppet/glpi_transport.yaml').sensitive_parameters).to include(:content)
          expect(catalogue.resource('File', config_file)).to be_nil
        end
      end

      context 'with a relative config_file' do
        let(:params) { super().merge(config_file: 'glpi_transport.yaml') }

        it { is_expected.to compile.and_raise_error(%r{config_file}) }
      end

      # A blank marker would match any comment with that much whitespace in it,
      # so objects nobody marked could be purged.
      ['', ' ', "  \n"].each do |marker|
        context "with marker #{marker.inspect}" do
          let(:params) { super().merge(marker: marker) }

          it { is_expected.to compile.and_raise_error(%r{marker}) }
        end
      end

      # base_url must be an http(s) URL: the transport builds every request
      # URI from it. Anything else used to fail only at the agent, on the
      # first request.
      ['glpi.example.com/api.php', 'ftp://glpi.example.com/api.php', 'https://', 'https://glpi example.com/api.php', ''].each do |url|
        context "with base_url #{url.inspect}" do
          let(:params) { super().merge(base_url: url) }

          it { is_expected.to compile.and_raise_error(%r{base_url}) }
        end
      end

      [
        'http://glpi.example.com/api.php', 'https://192.0.2.10:8443/glpi/api.php', 'https://[2001:db8::1]/api.php',
        'https://glpi.example.com/api.php/', 'HTTPS://glpi.example.com/api.php'
      ].each do |url|
        context "with base_url #{url.inspect}" do
          let(:params) { super().merge(base_url: url) }

          it { is_expected.to compile.with_all_deps }
        end
      end

      context 'with a relative ssl_ca_file' do
        let(:params) { super().merge(ssl_ca_file: 'certs/ca.pem') }

        it { is_expected.to compile.and_raise_error(%r{ssl_ca_file}) }
      end

      context 'with an unknown unresolved mode' do
        let(:params) { super().merge(unresolved: 'ignore') }

        it { is_expected.to compile.and_raise_error(%r{unresolved}) }
      end

      context 'with purge_max_fraction above 1' do
        let(:params) { super().merge(purge_max_fraction: 1.5) }

        it { is_expected.to compile.and_raise_error(%r{purge_max_fraction}) }
      end
    end
  end
end
