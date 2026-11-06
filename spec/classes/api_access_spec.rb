# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'glpi::api_access', type: :class do
  let(:client_secret) { 'client-secret-value-0123456789' }
  let(:password) { 'service-password-value-9876543210' }
  let(:config_file) { '/etc/glpi-puppet/api-bootstrap.json' }
  let(:script) { '/etc/glpi-puppet/glpi-api-bootstrap.php' }
  let(:params) do
    {
      glpi_root: '/var/www/glpi',
      client_name: 'Puppet',
      client_id: 'puppet',
      client_secret: sensitive(client_secret),
      username: 'puppet-api',
      password: sensitive(password),
    }
  end

  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      it { is_expected.to compile.with_all_deps }

      it 'manages the config directory owned by system_user, mode 0700' do
        is_expected.to contain_file('/etc/glpi-puppet').with(
          'ensure' => 'directory',
          'owner'  => 'glpi',
          'mode'   => '0700',
        )
      end

      it 'writes the config file owned by system_user, mode 0600, content Sensitive' do
        is_expected.to contain_file(config_file).with(
          'ensure' => 'file',
          'owner'  => 'glpi',
          'mode'   => '0600',
        )
        expect(catalogue.resource('File', config_file).sensitive_parameters).to include(:content)
      end

      it 'puts every desired value into the config file' do
        content = catalogue.resource('File', config_file)[:content]
        content = content.unwrap if content.respond_to?(:unwrap)
        data = JSON.parse(content)
        expect(data).to eq(
          'glpi_root' => '/var/www/glpi',
          'client' => {
            'name' => 'Puppet', 'identifier' => 'puppet', 'secret' => client_secret,
            'grants' => ['password'], 'scopes' => ['api', 'graphql']
          },
          'user' => { 'name' => 'puppet-api', 'password' => password },
          'profile' => { 'name' => 'Super-Admin', 'entity_id' => 0, 'recursive' => true },
        )
      end

      it 'installs the bootstrap script owned by root, mode 0755' do
        is_expected.to contain_file(script).with(
          'ensure' => 'file',
          'owner'  => 'root',
          'mode'   => '0755',
          'source' => 'puppet:///modules/glpi/glpi-api-bootstrap.php',
        )
      end

      it 'exec runs the script as system_user with --config, unless "<script> --config <file> --check"' do
        is_expected.to contain_exec('glpi-api-bootstrap').with(
          'command' => "/usr/bin/php #{script} --config #{config_file}",
          'unless'  => "/usr/bin/php #{script} --config #{config_file} --check",
          'user'    => 'glpi',
        ).that_subscribes_to(["File[#{config_file}]", "File[#{script}]"])
      end

      it 'no exec command or unless string contains the client_secret or password' do
        catalogue.resources.select { |r| r.type == 'Exec' }.each do |exec|
          [:command, :unless, :onlyif, :environment].each do |attr|
            value = exec[attr].to_s
            expect(value).not_to include(client_secret)
            expect(value).not_to include(password)
          end
        end
      end

      it 'exposes no secret in any non-sensitive catalog parameter' do
        catalogue.resources.each do |resource|
          sensitive = resource.sensitive_parameters
          resource.to_hash.each do |param, value|
            next if sensitive.include?(param)

            expect(value.to_s).not_to include(client_secret), "client_secret in #{resource.ref}[#{param}]"
            expect(value.to_s).not_to include(password), "password in #{resource.ref}[#{param}]"
          end
        end
      end

      context 'with custom values' do
        let(:params) do
          super().merge(
            system_user: 'www-data', grants: ['password', 'client_credentials'],
            profile: 'Admin', entity_id: 3, recursive: false,
            config_dir: '/opt/glpi-puppet', php_binary: '/usr/bin/php8.2'
          )
        end

        it do
          is_expected.to contain_exec('glpi-api-bootstrap').with(
            'command' => '/usr/bin/php8.2 /opt/glpi-puppet/glpi-api-bootstrap.php --config /opt/glpi-puppet/api-bootstrap.json',
            'user'    => 'www-data',
          )
        end

        it do
          content = catalogue.resource('File', '/opt/glpi-puppet/api-bootstrap.json')[:content]
          content = content.unwrap if content.respond_to?(:unwrap)
          data = JSON.parse(content)
          expect(data['client']['grants']).to eq(['password', 'client_credentials'])
          expect(data['profile']).to eq('name' => 'Admin', 'entity_id' => 3, 'recursive' => false)
        end
      end

      it 'manages nothing in the config directory but its own two files' do
        files = catalogue.resources.select { |r| r.type == 'File' }.map(&:title)
        expect(files).to contain_exactly('/etc/glpi-puppet', config_file, script)
      end

      context 'with config_dir set' do
        let(:params) { super().merge(config_dir: '/srv/bootstrap/glpi-api') }

        it 'manages that directory and puts both files into it' do
          is_expected.to contain_file('/srv/bootstrap/glpi-api').with('ensure' => 'directory', 'owner' => 'glpi', 'mode' => '0700')
          is_expected.to contain_file('/srv/bootstrap/glpi-api/api-bootstrap.json')
          is_expected.to contain_file('/srv/bootstrap/glpi-api/glpi-api-bootstrap.php')
        end
      end

      ['/etc', '/etc/', '/opt', '/srv'].each do |dir|
        context "with config_dir #{dir} (not a dedicated directory)" do
          let(:params) { super().merge(config_dir: dir) }

          it { is_expected.to compile.and_raise_error(%r{config_dir}) }
        end
      end

      ['/var/www/glpi', '/var/www/glpi/config', '/etc/glpi', '/etc/glpi/x', '/var/lib/glpi', '/var/log/glpi/x'].each do |dir|
        context "with config_dir #{dir} (a directory GLPI itself uses)" do
          let(:params) { super().merge(config_dir: dir) }

          it { is_expected.to compile.and_raise_error(%r{config_dir.*GLPI}) }
        end
      end

      context 'without glpi_root' do
        let(:params) { super().reject { |k, _| k == :glpi_root } }

        it { is_expected.to compile.and_raise_error(%r{glpi_root}) }
      end

      ['bad user', 'glpi;id', '../glpi', '-glpi', ''].each do |user|
        context "with system_user #{user.inspect}" do
          let(:params) { super().merge(system_user: user) }

          it { is_expected.to compile.and_raise_error(%r{system_user}) }
        end
      end

      ['www-data', 'apache', 'svc.glpi', '_glpi', '33', 'glpi@ad.example.com', 'DOM\\glpi', 'glpi$', 'glpi+web'].each do |user|
        context "with system_user #{user.inspect}" do
          let(:params) { super().merge(system_user: user) }

          it { is_expected.to contain_exec('glpi-api-bootstrap').with('user' => user) }
        end
      end

      [:glpi_root, :config_dir, :php_binary].each do |path|
        context "with a relative #{path}" do
          let(:params) { super().merge(path => 'relative/path') }

          it { is_expected.to compile.and_raise_error(%r{#{path}}) }
        end
      end

      context 'with an unknown grant' do
        let(:params) { super().merge(grants: ['authorization_code']) }

        it { is_expected.to compile.and_raise_error(%r{grants}) }
      end
    end
  end
end
