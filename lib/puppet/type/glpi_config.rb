# frozen_string_literal: true

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

Puppet::ResourceApi.register_type(
  name: 'glpi_config',
  docs: <<-EOS,
@summary Sets an existing GLPI configuration value (Setup > General and the inventory settings) through API v2.

An update-only type over `/Setup/Config/<context>/<key>`: it never creates or
deletes configuration keys and never lists them (no purge).

* The title is `<context>/<key>`, for example `inventory/stale_agents_delay`
  (context `core` is the general setup, `inventory` the inventory settings).
* `value` is always a string, exactly as GLPI stores it (`'14'`, `'[2]'`, `'0'`);
  a number from the API reads back as its string.
* A key that does not exist fails the resource. The API would otherwise create
  a new, meaningless row on a write to an unknown key, so the provider reads
  the key first and refuses.
* Keys whose name suggests a secret (`pass`, `secret`, `token`, `key`, `pwd`,
  `credential`) are refused by the type, so no such value is ever read,
  compared or logged. GLPI itself hides its mail and proxy passwords from this
  API; the inventory basic-auth password is not hidden, hence the name rule.
  The rule is by name alone and also refuses harmless keys such as
  `password_min_length`.
* The value is shown in change events and in `--show_diff`-style output:
  manage only non-secret settings with this type.

@example
  glpi_config { 'inventory/stale_agents_delay':
    value => '14',
  }
  EOS
  features: ['simple_get_filter', 'custom_insync'],
  attributes: {
    name: {
      type: 'String[1]',
      desc: 'The configuration key as `<context>/<key>`.',
      behaviour: :namevar,
    },
    value: {
      type: 'String',
      desc: 'The value, as a string, as GLPI stores it.',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_config)

# @api private
# The title must be <context>/<key> and must not look like a secret.
module Puppet::Type::GlpiConfigValidation
  NAME_FORMAT = %r{\A[^/\s]+/[^/\s]+\z}
  SECRET_NAME = %r{pass|secret|token|key|pwd|credential}i

  def validate
    super
    name = self[:name].to_s
    raise Puppet::ResourceError, "glpi_config[#{title}]: the title must be <context>/<key> (for example inventory/stale_agents_delay)" unless name.match?(NAME_FORMAT)
    return unless name.split('/', 2).last.match?(SECRET_NAME)

    raise Puppet::ResourceError, "glpi_config[#{title}]: the key name suggests a secret; glpi_config does not manage those"
  end
end

glpi_config_type = Puppet::Type.type(:glpi_config)
glpi_config_type.prepend(Puppet::Type::GlpiConfigValidation) unless glpi_config_type.ancestors.include?(Puppet::Type::GlpiConfigValidation)
