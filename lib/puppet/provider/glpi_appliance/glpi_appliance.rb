# frozen_string_literal: true

require 'set'
require_relative '../glpi_base_provider'
require_relative '../../../puppet_x/glpi/names'
require_relative '../../../puppet_x/glpi/lookups'

# @api private
module Puppet::Provider::GlpiAppliance; end

# Provider for glpi_appliance over API v2:
#   /Assets/Appliance[/<id>]                              appliances
#   GraphQL Appliance_Item                                all member links (REST cannot list them)
#   /Assets/<itemtype>/<items_id>/Appliance[/<link id>]   link / unlink one member
#
# Adoption policy :skip_unmarked. Trashed appliances are invisible. Only
# links of the resource's member_types are read and written. A member that
# matches nothing is skipped with a warning, or (class glpi
# unresolved => 'fail') the others are synced and the resource fails.
class Puppet::Provider::GlpiAppliance::GlpiAppliance < Puppet::Provider::GlpiBaseProvider
  include PuppetX::Glpi::Lookups

  # itemtype => [collection, whether API v2 can link it to an appliance].
  # Keep in step with the Enum in lib/puppet/type/glpi_appliance.rb.
  unless const_defined?(:ITEMTYPES)
    ITEMTYPES = {
      'Computer'         => ['/Assets/Computer', true],
      'Monitor'          => ['/Assets/Monitor', true],
      'NetworkEquipment' => ['/Assets/NetworkEquipment', true],
      'Peripheral'       => ['/Assets/Peripheral', true],
      'Phone'            => ['/Assets/Phone', true],
      'Printer'          => ['/Assets/Printer', true],
      'SoftwareLicense'  => ['/Assets/SoftwareLicense', true],
      'Certificate'      => ['/Assets/Certificate', true],
      'Unmanaged'        => ['/Assets/Unmanaged', true],
      'Appliance'        => ['/Assets/Appliance', true],
      'Cluster'          => ['/Management/Cluster', false],
    }.freeze
  end
  TYPE_PATH        = '/Dropdowns/ApplianceType' unless const_defined?(:TYPE_PATH)
  ENVIRONMENT_PATH = '/Dropdowns/ApplianceEnvironment' unless const_defined?(:ENVIRONMENT_PATH)
  LINK_FIELDS      = 'id itemtype items_id appliance { id }' unless const_defined?(:LINK_FIELDS)

  def collection_path
    '/Assets/Appliance'
  end

  def adoption_policy
    :skip_unmarked
  end

  def invalidate_objects
    super
    @links = nil
  end

  # Called by the type before a resource's state is read: get() then reads
  # only the links of these itemtypes for it. Undeclared names (puppet
  # resource, purge) read every supported itemtype.
  def declare_member_types(name, types)
    @member_types ||= {}
    @member_types[natural_key(resource_key(name))] = Array(types).map(&:to_s)
  end

  def api_to_resource(context, object)
    types = (@member_types || {})[natural_key(object_key(object))] || ITEMTYPES.keys
    members = current_links(context, object, types).map do |link|
      { 'itemtype' => link['itemtype'], 'name' => item_name(context, link['itemtype'], link['items_id']) }
    end
    {
      name: PuppetX::Glpi::Names.normalize(object['name']),
      appliance_type: dropdown_label(object['type']),
      environment: dropdown_label(object['environment']),
      comment: strip_marker(object['comment']),
      members: members.sort_by { |member| [member['itemtype'], member['name']] },
    }
  end

  # Existing appliance: comment (kept when not declared), type, environment.
  # New appliance: also name and the root entity, recursive. The base puts
  # the marker first.
  def resource_to_api(context, should, existing)
    body = {}
    body['name'] = should[:name] unless existing
    comment = wanted_value(should, :comment, existing)
    body['comment'] = (comment.nil? && existing) ? strip_marker(existing['comment']) : comment.to_s
    type_id = dropdown_id(context, TYPE_PATH, wanted_value(should, :appliance_type, existing), 'entity' => 0, 'is_recursive' => true)
    body['type'] = type_id unless type_id.nil?
    environment_id = dropdown_id(context, ENVIRONMENT_PATH, wanted_value(should, :environment, existing))
    body['environment'] = environment_id unless environment_id.nil?
    existing ? body : body.merge('entity' => 0, 'is_recursive' => true)
  end

  def create(context, name, should)
    super
    unresolved_members(context, should, sync_members(context, name, should))
  end

  def update(context, name, should)
    super
    unresolved_members(context, should, sync_members(context, name, should))
  end

  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, is_hash, should_hash)
    result = super
    return result unless result.nil?
    return nil if should_hash[:ensure].to_s == 'absent' || is_hash.nil?

    case attribute_name
    when :comment
      PuppetX::Glpi::Names.same?(is_hash[attribute_name], should_hash[attribute_name])
    when :appliance_type, :environment
      natural_key(is_hash[attribute_name]) == natural_key(should_hash[attribute_name])
    when :members
      appliance = lookup_object(context, name)
      return nil if appliance.nil?

      adds, removes, missing = member_plan(context, appliance, should_hash)
      in_sync = adds.empty? && removes.empty?
      # With links to write, a failure waits until set has written them.
      unresolved_members(context, should_hash, missing, write_pending: !in_sync)
      return true if in_sync

      [false, "members: #{plan_message(context, adds, removes)}"]
    end
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  private

  # Every Appliance_Item link, read once per CACHE_TTL (kept current by
  # sync_members, dropped with the appliance list).
  def links(context)
    if @links.nil? || Time.now - @links_read_at > CACHE_TTL
      @links = Array(transport(context).graphql_all(context, 'Appliance_Item', LINK_FIELDS))
      @links_read_at = Time.now
    end
    @links
  end

  def current_links(context, appliance, types)
    id = to_int(appliance['id'])
    links(context).select do |link|
      owner = link['appliance']
      owner.is_a?(Hash) && to_int(owner['id']) == id && types.include?(link['itemtype'].to_s)
    end
  end

  def item_name(context, itemtype, items_id)
    path, = ITEMTYPES[itemtype.to_s]
    item = path && cached_list(context, path).find { |candidate| to_int(candidate['id']) == to_int(items_id) }
    item ? PuppetX::Glpi::Names.normalize(item['name']) : "##{items_id}"
  end

  # [[[itemtype, id, name]] the declared members resolve to, [[itemtype,
  # name]] of those that match nothing]. A member of an itemtype outside
  # member_types fails.
  def wanted_members(context, should)
    types = Array(should[:member_types] || ['Computer']).map(&:to_s)
    missing = []
    resolved = Array(should[:members]).filter_map do |member|
      itemtype = member['itemtype'].to_s
      name = member['name'].to_s
      unless types.include?(itemtype)
        raise Puppet::ResourceError,
              "glpi_appliance '#{should[:name]}': member #{itemtype} '#{name}' is not of member_types #{types.join(', ')}"
      end
      id = resolve_member(context, itemtype, name)
      missing << [itemtype, name] if id.nil?
      id && [itemtype, id, name]
    end
    [resolved.uniq { |itemtype, id, _| [itemtype, id] }, missing.uniq]
  end

  # Computers: case-insensitive full name, else the first DNS label (resolve_computer).
  def resolve_member(context, itemtype, name)
    path, = ITEMTYPES[itemtype]
    live = cached_list(context, path).reject { |object| trashed?(object) }
    wanted = PuppetX::Glpi::Names.normalize(name)
    if itemtype == 'Computer'
      computer = resolve_computer(live, name)
      return computer && to_int(computer['id'])
    end
    unique_member(itemtype, wanted, live.select { |object| natural_key(object['name']) == natural_key(wanted) })
  end

  def unique_member(itemtype, wanted, matches)
    return to_int(matches.first['id']) if matches.size == 1
    return nil if matches.empty?

    raise Puppet::ResourceError,
          "glpi_appliance: #{matches.size} GLPI #{itemtype} objects match '#{wanted}' (ids #{matches.map { |object| object['id'] }.join(', ')})"
  end

  # Members that match nothing: a warning each ('warn'), or one failure of
  # the resource ('fail'; not while +write_pending+, i.e. from an insync?
  # that leaves links for set to write: set fails after writing them).
  def unresolved_members(context, should, missing, write_pending: false)
    return if missing.empty?

    messages = missing.map { |itemtype, name| "glpi_appliance '#{should[:name]}': no #{itemtype} matches '#{name}'; member skipped" }
    if fail_unresolved?
      raise_unresolved(should, messages) unless write_pending
      return
    end

    @warned_members ||= Set.new
    missing.zip(messages).each do |(itemtype, name), message|
      key = [should[:name], itemtype, name, @objects_read_at]
      next if @warned_members.include?(key)

      @warned_members << key
      context.warning(message)
    end
  end

  # [adds, removes, missing]: wanted members without a link, links of
  # member_types that are not wanted, and declared members that match
  # nothing ([itemtype, name]).
  def member_plan(context, appliance, should)
    types = Array(should[:member_types] || ['Computer']).map(&:to_s)
    wanted, missing = wanted_members(context, should)
    current = current_links(context, appliance, types)
    have = current.map { |link| [link['itemtype'].to_s, to_int(link['items_id'])] }.to_set
    want = wanted.map { |itemtype, id, _| [itemtype, id] }.to_set
    adds = wanted.reject { |itemtype, id, _| have.include?([itemtype, id]) }
    removes = current.reject { |link| want.include?([link['itemtype'].to_s, to_int(link['items_id'])]) }
    [adds, removes, missing]
  end

  def plan_message(context, adds, removes)
    linked = adds.map { |itemtype, _, name| "link #{itemtype} '#{name}'" }
    unlinked = removes.map { |link| "unlink #{link['itemtype']} '#{item_name(context, link['itemtype'], link['items_id'])}'" }
    (linked + unlinked).join('; ')
  end

  # After the appliance body is written: links against the appliance as read
  # again after that write (the base's write-through) and the link list of
  # this run. New links go in before old ones go. Nothing is written when
  # any change needs an itemtype the API cannot link. Each link written is
  # recorded in the cached link list (the API answers a link POST with the
  # link's id); a POST without an id, or any failure, drops the link list
  # and the next appliance reads it whole. Returns the declared members that
  # match nothing ([itemtype, name]).
  def sync_members(context, name, should)
    return [] if should[:members].nil?

    appliance = lookup_object(context, name)
    raise Puppet::ResourceError, "glpi_appliance '#{resource_key(name)}' not found after writing it" if appliance.nil?
    return [] unless marked?(appliance)

    adds, removes, missing = member_plan(context, appliance, should)
    refuse_unlinkable(should[:name], adds.map { |itemtype, _, member| [itemtype, member, 'link'] } +
                                     removes.map { |link| [link['itemtype'].to_s, item_name(context, link['itemtype'], link['items_id']), 'unlink'] })
    appliance_id = to_int(appliance['id'])
    adds.each do |itemtype, id, _|
      created = transport(context).post(context, "#{ITEMTYPES[itemtype][0]}/#{id}/Appliance", { 'appliance' => appliance_id })
      record_link(created, itemtype, id, appliance_id)
    end
    removes.each do |link|
      transport(context).delete(context, "#{ITEMTYPES[link['itemtype'].to_s][0]}/#{to_int(link['items_id'])}/Appliance/#{to_int(link['id'])}")
      @links&.reject! { |cached| to_int(cached['id']) == to_int(link['id']) }
    end
    missing
  rescue StandardError
    @links = nil
    raise
  end

  def record_link(created, itemtype, items_id, appliance_id)
    return if @links.nil?

    link_id = created.is_a?(Hash) ? to_int(created['id']) : nil
    return @links = nil unless link_id.is_a?(Integer)

    @links << { 'id' => link_id, 'itemtype' => itemtype, 'items_id' => items_id, 'appliance' => { 'id' => appliance_id } }
  end

  def refuse_unlinkable(appliance, changes)
    blocked = changes.reject { |itemtype, _, _| ITEMTYPES.fetch(itemtype, [nil, false])[1] }
    return if blocked.empty?

    details = blocked.map { |itemtype, member, verb| "cannot #{verb} a #{itemtype} ('#{member}')" }.join('; ')
    raise Puppet::ResourceError,
          "glpi_appliance '#{appliance}': GLPI API v2 #{details}; change these links in GLPI. No link was changed"
  end
end
