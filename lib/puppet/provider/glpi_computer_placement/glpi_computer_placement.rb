# frozen_string_literal: true

require 'set'
require_relative '../glpi_base_provider'
require_relative '../../../puppet_x/glpi/names'
require_relative '../../../puppet_x/glpi/lookups'

# @api private
module Puppet::Provider::GlpiComputerPlacement; end

# Provider for glpi_computer_placement over API v2:
#   /Assets/Computer[/<id>]        computers (entity {id, name, completename}, location {id, name})
#   /Administration/Entity[/<id>]  entities (complete name rebuilt from the parent chain; tag)
#   /Dropdowns/Location            locations (complete name rebuilt from the parent chain)
#
# Update-only: no ensure, no marker, nothing listed without names, nothing
# created or deleted (set() only ever calls update(); there is no create or
# delete). A missing or trashed computer is a warning and in sync, or
# (class glpi unresolved => 'fail') fails the resource.
# Values are compared by the id they resolve to.
class Puppet::Provider::GlpiComputerPlacement::GlpiComputerPlacement < Puppet::Provider::GlpiBaseProvider
  include PuppetX::Glpi::Lookups

  def collection_path
    '/Assets/Computer'
  end

  def adoption_policy
    :match_only
  end

  def creatable?
    false
  end

  def lookup_object(context, name)
    resolve_computer(objects(context), resource_key(name))
  end

  # Only requested names; a computer that does not exist is left out
  # (insync? warns and reports it in sync).
  def get(context, names = nil)
    return [] if names.nil? || names.empty?

    names.filter_map do |name|
      computer = lookup_object(context, name)
      computer && api_to_resource(context, computer).merge(name: name)
    end
  rescue TransportConfigMissing
    @transport_config_missing = true
    []
  end

  def api_to_resource(context, computer)
    entity_id = embedded_id(computer['entity'])
    location_id = embedded_id(computer['location'])
    {
      name: PuppetX::Glpi::Names.normalize(computer['name']),
      entity: entity_paths(context).fetch(entity_id.to_s) { embedded_label(computer['entity']) },
      entity_tag: entity_tag_of(context, entity_id).then { |tag| tag.empty? ? nil : tag },
      location: location_id.zero? ? '' : location_paths(context).fetch(location_id.to_s) { embedded_label(computer['location']) },
    }
  end

  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, _is_hash, should_hash)
    return nil unless [:entity, :entity_tag, :location].include?(attribute_name)
    return nil if should_hash[attribute_name].nil?
    # No transport file yet (get reported nothing): the default compare
    # reports a change and set() re-reads the real state.
    return nil if @transport_config_missing

    computer = lookup_object(context, name)
    return missing_computer(context, name, should_hash) if computer.nil?

    current_id(computer, attribute_name) == wanted_id(context, attribute_name, should_hash[attribute_name])
  rescue TransportConfigMissing
    @transport_config_missing = true
    nil
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  # The type has no ensure: every change is an update of the existing
  # computer (SimpleProvider refuses non-ensurable types).
  def set(context, changes)
    changes = refresh_changes(context, changes) if @transport_config_missing
    changes.each do |name, change|
      context.updating(name) { update(context, name, change[:should]) }
    end
  end

  # Against the computer list of this run, kept current by the write-through
  # (the written computer is read again by id; any failure drops the list).
  def update(context, name, should)
    computer = lookup_object(context, name)
    return missing_computer(context, name, should) if computer.nil?

    body = {}
    { entity: 'entity', entity_tag: 'entity', location: 'location' }.each do |attribute, field|
      next if should[attribute].nil?

      wanted = wanted_id(context, attribute, should[attribute])
      body[field] = wanted unless wanted == current_id(computer, attribute)
    end
    return if body.empty?

    path = item_path(computer)
    transport(context).patch(context, path, body)
    refresh_cached_object(context, path, computer)
  rescue StandardError
    drop_cached_lists(context) { computer && item_path(computer) }
    raise
  end

  private

  def refresh_changes(context, changes)
    @transport = nil
    @transport_signature = nil
    @transport_config_missing = false
    invalidate_objects
    changes.to_h { |name, change| [name, change.merge(is: get(context, [name]).first)] }
  end

  # Warning ('warn') or failure of the resource ('fail', once per resource
  # and run: the first attribute's insync? raises, the others are in sync).
  def missing_computer(context, title, should)
    message = "#{type_name}: no GLPI computer matches '#{resource_key(title)}' (or it is in the trash); " \
              'not placed, computers are not created'
    if fail_unresolved?
      raise_unresolved(should, [message])
      return true
    end

    @warned_missing ||= Set.new
    key = PuppetX::Glpi::Names.normalize(resource_key(title)).downcase
    unless @warned_missing.include?(key)
      @warned_missing << key
      context.warning(message)
    end
    true
  end

  def current_id(computer, attribute)
    embedded_id(computer[(attribute == :location) ? 'location' : 'entity'])
  end

  def wanted_id(context, attribute, value)
    case attribute
    when :entity then entity_id(context, value)
    when :entity_tag then entity_id_by_tag(context, value)
    when :location then location_id(context, value)
    end
  end
end
