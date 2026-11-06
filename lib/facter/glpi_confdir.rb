# frozen_string_literal: true

# The agent's own Puppet confdir: where the providers look for
# glpi_transport.yaml (Puppet.settings[:confdir] in the agent run).
#
# The class needs it at compile time, and $settings::confdir there is the
# COMPILING server's confdir. The two differ whenever server and agent use
# different layouts, e.g. an OpenVox/AIO server (/etc/puppetlabs/puppet)
# compiling for a Debian-packaged agent (/etc/puppet).
Facter.add(:glpi_confdir) do
  setcode do
    Puppet.settings[:confdir] if defined?(Puppet) && Puppet.respond_to?(:settings)
  end
end
