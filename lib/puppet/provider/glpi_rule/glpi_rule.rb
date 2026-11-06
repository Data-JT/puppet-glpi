# frozen_string_literal: true

require_relative '../glpi_base_provider'
require_relative '../../../puppet_x/glpi/names'

# @api private
module Puppet::Provider::GlpiRule; end

# Provider for glpi_rule over API v2:
#   /Rule/Collection/<Collection>/Rule[/<id>]                   rules
#   /Rule/Collection/<Collection>/Rule/<id>/{Criteria,Action}[/<id>] their children
# The rule list already carries each rule's criteria and actions.
#
# One type spans several collections, so the objects of all supported
# collections are read into one list, each tagged with its collection.
# Constants are guarded: Puppet loads provider files more than once.
class Puppet::Provider::GlpiRule::GlpiRule < Puppet::Provider::GlpiBaseProvider
  unless const_defined?(:COLLECTIONS)
    COLLECTIONS = {
      'right'          => 'Right',
      'import_asset'   => 'ImportAsset',
      'mail_collector' => 'MailCollector',
    }.freeze
  end
  # Action fields whose value may be given by name.
  unless const_defined?(:LOOKUPS)
    LOOKUPS = {
      'profiles_id' => ['/Administration/Profile', 'profile'],
      'entities_id' => ['/Administration/Entity', 'entity'],
    }.freeze
  end
  COLLECTION_KEY = '_collection' unless const_defined?(:COLLECTION_KEY)

  def collection_path
    '/Rule/Collection'
  end

  def rules_path(collection)
    api_name = COLLECTIONS[collection.to_s]
    raise Puppet::ResourceError, "glpi_rule: unsupported collection '#{collection}'" if api_name.nil?

    "/Rule/Collection/#{api_name}/Rule"
  end

  def fetch_objects(context)
    COLLECTIONS.keys.flat_map do |collection|
      Array(transport(context).get_all(context, rules_path(collection), collection_query))
        .map { |rule| rule.merge(COLLECTION_KEY => collection) }
    end
  end

  def item_path(object)
    "#{rules_path(object[COLLECTION_KEY])}/#{object['id']}"
  end

  # A rule read again by id is tagged with the collection its path names.
  def cache_object(_context, fresh, path)
    fresh.merge(COLLECTION_KEY => collection_of(path))
  end

  # The cached rule drives sync_criteria/sync_actions: without its children
  # it would look childless, so such a re-read is not cached.
  def cacheable?(fresh, path)
    super && fresh.key?('criteria') && fresh.key?('actions') && !collection_of(path).nil?
  end

  def create_path(should)
    raise Puppet::ResourceError, "glpi_rule '#{should[:name]}': collection is required" if should[:collection].nil?

    rules_path(should[:collection])
  end

  def api_to_resource(context, object)
    {
      name: PuppetX::Glpi::Names.normalize(object['name']),
      collection: object[COLLECTION_KEY],
      match: object['match'].to_s.upcase,
      is_active: to_bool(object['is_active']),
      criteria: sorted(Array(object['criteria']).map { |criterion| criterion_hash(criterion) }),
      actions: sorted(Array(object['actions']).map { |action| action_hash(action, display_value(context, action['field'], action['value'])) }),
    }
  end

  # Rule body. A new rule gets entity 0, recursive and condition 0; an
  # existing one keeps its entity. The comment (marker) is the base's job.
  def resource_to_api(context, should, existing)
    if existing && existing[COLLECTION_KEY] != should[:collection].to_s
      raise Puppet::ResourceError,
            "glpi_rule: rule '#{should[:name]}' exists in collection #{existing[COLLECTION_KEY]} " \
            "and cannot be moved to #{should[:collection]}"
    end
    # Resolve names before anything is written: an unknown profile fails the
    # resource without a half-written rule.
    action_bodies(context, should[:actions])

    body = {
      'name'      => should[:name],
      'match'     => should[:match] || 'AND',
      'is_active' => should[:is_active].nil? ? true : should[:is_active],
    }
    # A case-only difference is in sync: an existing rule keeps its name.
    body.delete('name') if existing && case_only_difference?(existing['name'], should[:name])
    existing ? body : body.merge('entity' => 0, 'is_recursive' => true, 'condition' => 0)
  end

  def create(context, name, should)
    super
    sync_rule(context, name, should)
  end

  def update(context, name, should)
    super
    sync_rule(context, name, should)
  end

  # GLPI renumbers the rankings of a collection when a rule is deleted, so
  # the cached rankings of the other rules are stale: read them all again.
  def delete(context, name)
    super
  ensure
    invalidate_objects
  end

  # criteria/actions: unordered multisets, profile/entity values by id.
  # before_rule: in sync while the rule ranks above the named rule.
  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, is_hash, should_hash)
    result = super
    return result unless result.nil?
    return nil if should_hash[:ensure].to_s == 'absent' || is_hash.nil?

    case attribute_name
    when :criteria
      criteria_keys(should_hash[:criteria]).tally == criteria_keys(is_hash[:criteria]).tally
    when :actions
      action_bodies(context, should_hash[:actions]).tally == action_bodies(context, is_hash[:actions]).tally
    when :before_rule
      return true if should_hash[:before_rule].nil?

      rule = lookup_object(context, name)
      !rule.nil? && ranked_above?(rule, before_target(context, rule, should_hash))
    end
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  private

  def criterion_hash(criterion)
    {
      'criteria'  => criterion['criteria'].to_s,
      'condition' => to_int(criterion['condition']),
      'pattern'   => PuppetX::Glpi::Names.normalize(criterion['pattern']),
    }
  end

  def action_hash(action, value)
    { 'action_type' => action['action_type'].to_s, 'field' => action['field'].to_s, 'value' => value }
  end

  def sorted(list)
    list.sort_by { |item| item.values.map(&:to_s) }
  end

  def criteria_keys(criteria)
    Array(criteria).map { |criterion| criterion_hash(criterion) }
  end

  # Request bodies of the actions, profile/entity names resolved to ids.
  def action_bodies(context, actions)
    Array(actions).map { |action| action_hash(action, resolve_value(context, action['field'], action['value'])) }
  end

  # name -> id (as String) for profiles_id/entities_id; other values as given.
  def resolve_value(context, field, value)
    text = value.to_s
    path, kind = LOOKUPS[field.to_s]
    return text if path.nil? || text.match?(%r{\A\d+\z})

    matches = lookup_list(context, path).select { |object| labelled?(object, text) }.uniq { |object| object['id'] }
    raise Puppet::ResourceError, "glpi_rule: unknown #{kind} '#{text}' in an action on #{field}" if matches.empty?
    if matches.size > 1
      raise Puppet::ResourceError,
            "glpi_rule: #{matches.size} #{kind} objects match '#{text}' (ids #{matches.map { |object| object['id'] }.join(', ')}); " \
            'use the complete name or the id'
    end
    matches.first['id'].to_s
  end

  def case_only_difference?(current, wanted)
    natural_key(current) == natural_key(wanted) && !PuppetX::Glpi::Names.same?(current, wanted)
  end

  def labelled?(object, text)
    [object['name'], object['completename']].compact.any? { |label| natural_key(label) == natural_key(text) }
  end

  # id -> name for profiles_id/entities_id (complete name for entities);
  # an id that matches nothing is kept.
  def display_value(context, field, value)
    text = value.to_s
    path, = LOOKUPS[field.to_s]
    return text if path.nil?

    object = lookup_list(context, path).find { |candidate| candidate['id'].to_s == text }
    object ? PuppetX::Glpi::Names.normalize(object['completename'] || object['name']) : text
  end

  # Profiles and entities, shared with the other glpi_* providers.
  def lookup_list(context, path)
    shared_list(context, path)
  end

  def collection_of(path)
    COLLECTIONS.find { |_key, api_name| path.to_s.start_with?("/Rule/Collection/#{api_name}/Rule/") }&.first
  end

  # Through objects(): a failed re-read after a children change drops the
  # list, which is then read whole here (never an empty list).
  def before_target(context, rule, should)
    wanted = should[:before_rule]
    collection = should[:collection].to_s
    matches = objects(context).select do |object|
      object[COLLECTION_KEY] == collection && natural_key(object['name']) == natural_key(wanted)
    end
    raise Puppet::ResourceError, "glpi_rule '#{should[:name]}': before_rule: no rule '#{wanted}' in collection #{collection}" if matches.empty?
    if matches.size > 1
      raise Puppet::ResourceError,
            "glpi_rule '#{should[:name]}': before_rule: #{matches.size} rules named '#{wanted}' in collection #{collection}"
    end
    raise Puppet::ResourceError, "glpi_rule '#{should[:name]}': before_rule names the rule itself" if matches.first['id'] == rule['id']

    matches.first
  end

  def ranked_above?(rule, target)
    to_int(rule['ranking']) < to_int(target['ranking'])
  end

  # After the rule body is written: children and ranking, against the rule
  # as read again after that write (the base's write-through). Changed
  # children re-read this rule only; a ranking move shifts the other rules
  # of the collection, so it drops the whole list. Any failure drops it too.
  def sync_rule(context, name, should)
    rule = lookup_object(context, name)
    raise Puppet::ResourceError, "glpi_rule: rule '#{resource_key(name)}' not found after writing it" if rule.nil?

    children = [
      should[:criteria].nil? ? false : sync_criteria(context, rule, should[:criteria]),
      should[:actions].nil? ? false : sync_actions(context, rule, should[:actions]),
    ].any?
    refresh_cached_object(context, item_path(rule), rule) if children
    return if should[:before_rule].nil?

    invalidate_objects if move_above(context, rule, before_target(context, rule, should))
  rescue StandardError
    invalidate_objects
    raise
  end

  # Replaced as a whole. New criteria go in before the old ones go, so the
  # rule never has fewer conditions than intended (never matches too much).
  def sync_criteria(context, rule, criteria)
    wanted = criteria_keys(criteria)
    current = Array(rule['criteria'])
    return false if wanted.tally == criteria_keys(current).tally

    path = "#{item_path(rule)}/Criteria"
    wanted.each { |body| transport(context).post(context, path, body) }
    current.each { |criterion| transport(context).delete(context, "#{path}/#{criterion['id']}") }
    true
  end

  # Replaced as a whole. Old actions go first, so the rule never applies a
  # mix of old and new actions.
  def sync_actions(context, rule, actions)
    wanted = action_bodies(context, actions)
    current = Array(rule['actions'])
    return false if wanted.tally == action_bodies(context, current).tally

    path = "#{item_path(rule)}/Action"
    current.each { |action| transport(context).delete(context, "#{path}/#{action['id']}") }
    wanted.each { |body| transport(context).post(context, path, body) }
    true
  end

  # PATCHing ranking moves the rule (GLPI shifts the others): taking the
  # target's rank puts this rule directly above it.
  # true when it moved the rule.
  def move_above(context, rule, target)
    return false if ranked_above?(rule, target)

    context.info("glpi_rule: moving '#{rule['name']}' above '#{target['name']}' (rank #{target['ranking']})")
    transport(context).patch(context, item_path(rule), { 'ranking' => to_int(target['ranking']) })
    true
  end
end
