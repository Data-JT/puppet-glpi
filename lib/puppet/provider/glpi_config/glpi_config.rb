# frozen_string_literal: true

require_relative '../glpi_base_provider'

# @api private
module Puppet::Provider::GlpiConfig; end

# Provider for glpi_config over API v2:
#   /Setup/Config/<context>/<key>   one configuration value, {context, name, value}
#
# Update-only: no ensure, no marker, nothing listed without names, nothing
# created or deleted. PATCH on an unknown key would insert a new row, so every
# write is preceded by a read and an unknown key fails the resource. Keys
# whose name looks like a secret are refused here as well as in the type, and
# nothing in an error message carries a value.
class Puppet::Provider::GlpiConfig::GlpiConfig < Puppet::Provider::GlpiBaseProvider
  CONFIG_PATH = '/Setup/Config' unless const_defined?(:CONFIG_PATH)
  SECRET_NAME = %r{pass|secret|token|key|pwd|credential}i unless const_defined?(:SECRET_NAME)

  def collection_path
    CONFIG_PATH
  end

  def adoption_policy
    :match_only
  end

  def creatable?
    false
  end

  # Only requested names; an unknown key is left out (insync? and update fail it).
  def get(context, names = nil)
    return [] if names.nil? || names.empty?

    names.filter_map do |name|
      entry = read_entry(context, name)
      entry && { name: name, value: entry['value'].to_s }
    end
  rescue TransportConfigMissing
    @transport_config_missing = true
    []
  end

  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, _is_hash, should_hash)
    return nil unless attribute_name == :value
    return nil if should_hash[:value].nil?
    # No transport file yet: the default compare reports a change and set() re-reads.
    return nil if @transport_config_missing

    current_value(context, name) == should_hash[:value].to_s
  rescue TransportConfigMissing
    @transport_config_missing = true
    nil
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  # No ensure: every change is an update of the existing key.
  def set(context, changes)
    changes = refresh_changes(context, changes) if @transport_config_missing
    changes.each do |name, change|
      context.updating(name) { update(context, name, change[:should]) }
    end
  end

  def update(context, name, should)
    return if should[:value].nil?
    return if current_value(context, name) == should[:value].to_s

    context_name, key = split_name(name)
    transport(context).patch(context, "#{CONFIG_PATH}/#{context_name}/#{key}", 'value' => should[:value].to_s)
  end

  private

  def refresh_changes(context, changes)
    @transport = nil
    @transport_signature = nil
    @transport_config_missing = false
    changes.to_h { |name, change| [name, change.merge(is: get(context, [name]).first)] }
  end

  def split_name(name)
    context_name, key = name.to_s.split('/', 2)
    unless context_name && key && !context_name.empty? && !key.empty? && !key.include?('/')
      raise Puppet::ResourceError, "#{type_name}: '#{name}' is not <context>/<key>"
    end
    raise Puppet::ResourceError, "#{type_name}: '#{name}': the key name suggests a secret; not managed" if key.match?(SECRET_NAME)

    [context_name, key]
  end

  # The API entry, or nil when GLPI answers 404.
  def read_entry(context, title)
    context_name, key = split_name(title)
    transport(context).get(context, "#{CONFIG_PATH}/#{context_name}/#{key}", nil)
  rescue Puppet::ResourceError => error
    raise unless error.respond_to?(:status) && error.status == 404

    nil
  end

  # The unknown key is an error, not a creation.
  def current_value(context, title)
    entry = read_entry(context, title)
    if entry.nil?
      raise Puppet::ResourceError,
            "#{type_name}: no GLPI configuration key '#{title}'; keys are not created"
    end

    entry['value'].to_s
  end
end
