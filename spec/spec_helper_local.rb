# frozen_string_literal: true

# The shared transport registry is process-wide state; start every example clean.
RSpec.configure do |c|
  c.before(:each) do
    Puppet::Provider::GlpiBaseProvider.reset_shared_transports! if defined?(Puppet::Provider::GlpiBaseProvider)
  end
end

# .fixtures.yml links spec/fixtures/modules/glpi to the repository root, and
# rspec-puppet puts spec/fixtures/modules/*/lib on the load path. Puppet's
# autoloader (which the Resource API also uses to load providers) would
# therefore Kernel.load lib/ files a second time through that link, redefining
# the classes the unit specs already required from lib/. SimpleCov drops every
# path containing '/spec', and Ruby restarts a file's line counts whenever it
# is loaded again, so whatever ran before or after such a reload went
# uncounted.
#
# This resolves an autoloaded file to its real location and skips loading it
# when a spec has already required it, exactly as Ruby's own require would.
module GlpiSpecRealAutoloadPath
  def get_file(name, env)
    file = super
    file && File.realpath(file)
  end

  def load_file(name, env)
    file = get_file(name.to_s, env)
    return super unless file && $LOADED_FEATURES.include?(file)

    mark_loaded(name, file)
    true
  end
end

Puppet::Util::Autoload.singleton_class.prepend(GlpiSpecRealAutoloadPath)
