# frozen_string_literal: true

require 'set'
require_relative '../glpi_base_provider'
require_relative '../../../puppet_x/glpi/names'
require_relative '../../../puppet_x/glpi/lookups'

# @api private
module Puppet::Provider::GlpiItemPlacement; end

# Provider for glpi_item_placement over API v2:
#   /Assets/NetworkEquipment[/<id>]  network devices (location {id, name})
#   /Management/DataCenter[/<id>]    data centers (location {id, name})
#   /Dropdowns/Location              locations (shared with glpi_computer_placement)
#
# Update-only: no ensure, no marker, nothing listed without names, nothing
# created or deleted. A missing or trashed item is a warning and in sync,
# or (class glpi unresolved => 'fail') fails the resource. One provider
# serves both itemtypes, so the item lists are the shared per-path lists,
# not the base provider's single object list.
class Puppet::Provider::GlpiItemPlacement::GlpiItemPlacement < Puppet::Provider::GlpiBaseProvider
  include PuppetX::Glpi::Lookups

  unless const_defined?(:PATHS)
    PATHS = {
      'NetworkEquipment' => '/Assets/NetworkEquipment',
      'DataCenter' => '/Management/DataCenter',
    }.freeze
  end

  # Placeholder the base provider requires: reads and writes go through
  # PATHS per itemtype, never through this path.
  def collection_path
    PATHS.fetch('NetworkEquipment')
  end

  def adoption_policy
    :match_only
  end

  def creatable?
    false
  end

  def resource_key(name)
    name.is_a?(Hash) ? name[:name] : name
  end

  def itemtype_of(name)
    itemtype = name.is_a?(Hash) ? name[:itemtype] : nil
    raise Puppet::ResourceError, "#{type_name}: no itemtype in the title '#{name}'" unless PATHS.key?(itemtype)

    itemtype
  end

  def lookup_object(context, name)
    wanted = natural_key(resource_key(name))
    live = cached_list(context, PATHS.fetch(itemtype_of(name))).reject { |object| trashed?(object) }
    matches = live.select { |object| natural_key(object['name']) == wanted }
    return matches.first if matches.size <= 1

    raise Puppet::ResourceError,
          "#{type_name}: #{matches.size} GLPI items match '#{PuppetX::Glpi::Names.normalize(resource_key(name))}' " \
          "(ids #{matches.map { |object| object['id'] }.join(', ')})"
  end

  # Only requested names; an item that does not exist is left out
  # (insync? warns and reports it in sync).
  def get(context, names = nil)
    return [] if names.nil? || names.empty?

    names.filter_map do |name|
      item = lookup_object(context, name)
      item && api_to_resource(context, item).merge(
        itemtype: itemtype_of(name), name: resource_key(name), title: "#{itemtype_of(name)}/#{resource_key(name)}",
      )
    end
  rescue TransportConfigMissing
    @transport_config_missing = true
    []
  end

  def api_to_resource(context, item)
    location_id = embedded_id(item['location'])
    {
      name: PuppetX::Glpi::Names.normalize(item['name']),
      location: location_id.zero? ? '' : location_paths(context).fetch(location_id.to_s) { embedded_label(item['location']) },
    }
  end

  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, _is_hash, should_hash)
    return nil unless attribute_name == :location
    return nil if should_hash[:location].nil?
    # No transport file yet (get reported nothing): the default compare
    # reports a change and set() re-reads the real state.
    return nil if @transport_config_missing

    item = lookup_object(context, name)
    return missing_item(context, name, should_hash) if item.nil?

    embedded_id(item['location']) == location_id(context, should_hash[:location])
  rescue TransportConfigMissing
    @transport_config_missing = true
    nil
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  # The type has no ensure: every change is an update of the existing item.
  def set(context, changes)
    if @transport_config_missing
      @transport = nil
      @transport_signature = nil
      @transport_config_missing = false
    end
    changes.each do |name, change|
      context.updating(name) { update(context, name, change[:should]) }
    end
  end

  def update(context, name, should)
    item = lookup_object(context, name)
    return missing_item(context, name, should) if item.nil?
    return if should[:location].nil?

    wanted = location_id(context, should[:location])
    return if wanted == embedded_id(item['location'])

    path = "#{PATHS.fetch(itemtype_of(name))}/#{item['id']}"
    transport(context).patch(context, path, { 'location' => wanted })
    refresh_cached_object(context, path, item)
  rescue StandardError
    drop_cached_lists(context) { PATHS[itemtype_of(name)] }
    raise
  end

  private

  def missing_item(context, title, should)
    message = "#{type_name}: no GLPI #{itemtype_of(title)} matches '#{resource_key(title)}' (or it is in the trash); " \
              'not placed, items are not created'
    if fail_unresolved?
      raise_unresolved(should, [message])
      return true
    end

    @warned_missing ||= Set.new
    key = [itemtype_of(title), PuppetX::Glpi::Names.normalize(resource_key(title)).downcase]
    unless @warned_missing.include?(key)
      @warned_missing << key
      context.warning(message)
    end
    true
  end
end
