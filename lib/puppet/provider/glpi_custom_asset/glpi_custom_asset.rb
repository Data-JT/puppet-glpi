# frozen_string_literal: true

require 'set'
require_relative '../glpi_base_provider'
require_relative '../../../puppet_x/glpi/names'
require_relative '../../../puppet_x/glpi/lookups'

# @api private
module Puppet::Provider::GlpiCustomAsset; end

# Provider for glpi_custom_asset over API v2:
#   /Assets/Custom/                          the asset definitions ({itemtype, name, href})
#   /Assets/Custom/<definition>[/<id>]       the assets of one definition
#   /Assets/Custom/<definition>Type          the definition's type dropdown
#   /Administration/Entity                   entities (complete name rebuilt from the parent chain; tag)
#
# Identity is (definition, name). The list the base works on holds the
# assets of every definition this provider was asked about (the catalog's
# titles, requested names) and, for a listing without names (purge,
# `puppet resource`), of every definition GLPI lists; each object is tagged
# with its definition in '_definition'. The purge guard counts per
# definition. Adoption policy :adopt.
#
# Only the custom fields a resource declares are read (declare_fields, from
# the type before its state is read), compared and written; a partial
# custom_fields PATCH leaves the others alone. Fields in field_refs hold an
# object id: written as the id the declared name resolves to, read back as
# that object's name. A name that resolves to nothing is never written.
class Puppet::Provider::GlpiCustomAsset::GlpiCustomAsset < Puppet::Provider::GlpiBaseProvider
  include PuppetX::Glpi::Lookups

  BASE_PATH = '/Assets/Custom' unless const_defined?(:BASE_PATH)
  REF_PATHS = { 'Computer' => '/Assets/Computer', 'Appliance' => '/Assets/Appliance' }.freeze unless const_defined?(:REF_PATHS)
  EMPTY_REFS = ['', '0'].freeze unless const_defined?(:EMPTY_REFS)
  ITEM_PATH  = %r{\A/Assets/Custom/([^/]+)/\d+\z} unless const_defined?(:ITEM_PATH)

  def collection_path
    BASE_PATH
  end

  def definition_path(definition)
    "#{BASE_PATH}/#{definition}"
  end

  def item_path(object)
    "#{definition_path(object['_definition'])}/#{object['id']}"
  end

  def create_path(should)
    definition_path(canonical_definition(definition_of(should)))
  end

  def object_key(object)
    key_for(object['_definition'], object['name'])
  end

  # "<definition>/<name>" (a String title is already that form).
  def resource_key(name)
    return key_for(name[:definition], name[:name]) if name.is_a?(Hash)

    name
  end

  # The definition: of a raw object (its '_definition' tag), of a composite
  # title or target state (:definition), or of a "<definition>/<name>" key.
  def guard_scope(key_or_object)
    PuppetX::Glpi::Names.normalize(definition_of(key_or_object))
  end

  # ---- definitions read ---------------------------------------------------

  # Called by the type before a resource's state is read: get() then reads
  # only these custom fields for it (nil: none), and field_refs maps the
  # reference fields back to names.
  def declare_fields(name, fields, refs)
    note_definitions([name])
    @declared_fields ||= {}
    @declared_fields[natural_key(resource_key(name))] = { keys: fields&.keys&.map(&:to_s), refs: (refs || {}).transform_keys(&:to_s) }
  end

  def plan_deletions(plan_id, titles, declared = [])
    note_definitions(Array(titles) + Array(declared))
    super
  end

  def get(context, names = nil)
    if names.nil? || names.empty?
      invalidate_objects unless @fetched_all
      @list_all = true
    else
      note_definitions(names)
    end
    super
  end

  def lookup_object(context, name)
    note_definitions([name])
    found = super
    refuse_unknown_definition(name)
    found
  end

  # Also ends a listing of every definition: the next read covers the
  # known definitions only, until get() without names asks again.
  def invalidate_objects
    super
    @fetched_all = false
    @list_all = false
  end

  # The assets of every definition known so far (see the class comment),
  # each tagged with its definition as GLPI spells it. A known definition
  # GLPI does not list is not read (its resources fail alone, see
  # refuse_unknown_definition); when the listing is unusable every known
  # definition is read as declared.
  def fetch_objects(context)
    listed = listed_definitions(context)
    @canonical_definitions = listed ? listed.to_h { |definition| [natural_key(definition), definition] } : {}
    known = wanted_definitions.to_h { |key, definition| [key, @canonical_definitions.fetch(key, definition)] }
    @unknown_definitions = listed ? known.reject { |key, _| @canonical_definitions.key?(key) } : {}
    definitions = known.reject { |key, _| @unknown_definitions.key?(key) }
    definitions = @canonical_definitions.merge(definitions) if @list_all && listed
    list = definitions.values.flat_map do |definition|
      Array(transport(context).get_all(context, definition_path(definition), collection_query)).map do |object|
        object.merge('_definition' => definition)
      end
    end
    @fetched_definitions = known.keys.to_set | definitions.keys.to_set
    @fetched_all = @list_all == true
    list
  end

  # The re-read object keeps the definition of its path.
  def cache_object(_context, fresh, path)
    definition = ITEM_PATH.match(path.to_s)&.captures&.first
    fresh.merge('_definition' => definition)
  end

  # ---- mapping --------------------------------------------------------------

  def api_to_resource(context, object)
    declared = (@declared_fields || {})[natural_key(object_key(object))]
    custom = object['custom_fields'].is_a?(Hash) ? object['custom_fields'] : {}
    refs = declared ? declared[:refs] : {}
    keys = declared ? Array(declared[:keys]) : custom.keys.map(&:to_s)
    definition = object['_definition'].to_s
    name = PuppetX::Glpi::Names.normalize(object['name'])
    {
      title: "#{definition}/#{name}",
      definition: definition,
      name: name,
      asset_type: dropdown_label(object['type']),
      comment: strip_marker(object['comment']),
      fields: keys.to_h { |key| [key, read_field(context, custom[key], refs[key])] },
    }.merge(entity_attributes(context, object))
  end

  # New asset: name, comment, and every declared attribute. Existing asset:
  # only what differs; the comment also when the asset is not marked yet
  # (adoption: the marker goes first, the text is kept).
  def resource_to_api(context, should, existing)
    body = {}
    body['name'] = should[:name] unless existing
    comment = comment_body(should, existing)
    body['comment'] = comment unless comment.nil?
    type_id = dropdown_id(context, "#{create_path(should)}Type", wanted_value(should, :asset_type, existing))
    body['type'] = { 'id' => type_id } unless type_id.nil? || (existing && embedded_id(existing['type']) == type_id)
    entity = resolvable_entity(context, should)
    body['entity'] = { 'id' => entity } unless entity.nil? || (existing && embedded_id(existing['entity']) == entity)
    changes, = field_plan(context, existing, should)
    body['custom_fields'] = changes unless changes.empty?
    body
  end

  def create(context, name, should)
    super
    unresolved_fields(context, should)
  end

  def update(context, name, should)
    super
    unresolved_fields(context, should)
  end

  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, is_hash, should_hash)
    result = super
    return result unless result.nil?
    return nil if should_hash[:ensure].to_s == 'absent' || is_hash.nil? || is_hash[:ensure].to_s == 'absent'

    case attribute_name
    when :comment
      PuppetX::Glpi::Names.same?(is_hash[:comment], should_hash[:comment])
    when :asset_type
      natural_key(is_hash[:asset_type]) == natural_key(should_hash[:asset_type])
    when :entity, :entity_tag
      return nil if should_hash[attribute_name].nil?

      object = lookup_object(context, name)
      return nil if object.nil?

      wanted = resolvable_entity(context, should_hash)
      wanted.nil? || embedded_id(object['entity']) == wanted
    when :fields
      fields_state(context, name, should_hash)
    end
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  private

  def key_for(definition, name)
    "#{PuppetX::Glpi::Names.normalize(definition)}/#{PuppetX::Glpi::Names.normalize(name)}"
  end

  def definition_of(value)
    case value
    when Hash
      value.key?('_definition') ? value['_definition'] : value[:definition]
    else
      value.to_s.split('/', 2).first if value.to_s.include?('/')
    end
  end

  # natural key of the definition => definition as first named.
  def wanted_definitions
    @wanted_definitions ||= {}
  end

  def note_definitions(names)
    added = false
    names.each do |name|
      definition = PuppetX::Glpi::Names.normalize(definition_of(name))
      next if definition.empty?

      key = natural_key(definition)
      next if wanted_definitions.key?(key)

      wanted_definitions[key] = definition
      added = true
    end
    # A definition the cached list does not cover: read the list again.
    invalidate_objects if added && @fetched_definitions && !wanted_definitions.keys.to_set.subset?(@fetched_definitions)
  end

  # GLPI's spelling of +definition+ (from the listing), else as declared.
  def canonical_definition(definition)
    (@canonical_definitions || {}).fetch(natural_key(definition), definition)
  end

  # Fails a resource whose definition GLPI does not list (only that one:
  # the others of the run are read and written as usual).
  def refuse_unknown_definition(name)
    definition = PuppetX::Glpi::Names.normalize(definition_of(name))
    return unless (@unknown_definitions || {}).key?(natural_key(definition))

    raise Puppet::ResourceError,
          "#{type_name}: GLPI has no custom asset definition '#{definition}' " \
          "(#{BASE_PATH}/ lists: #{(@canonical_definitions || {}).values.sort.join(', ')})"
  end

  # Requested names of an unknown definition fail (get is called per
  # resource, so only that resource).
  def requested_resources(context, all, names)
    names.each { |name| refuse_unknown_definition(name) }
    super
  end

  # The definitions GLPI lists (GET /Assets/Custom/: [{itemtype, name,
  # href}], itemtype = system name), read once per CACHE_TTL; nil when the
  # answer has another shape (then only the catalog's definitions are read,
  # as declared).
  def listed_definitions(context)
    return @listed_definitions if @listed_definitions_read_at && Time.now - @listed_definitions_read_at <= CACHE_TTL

    answer = transport(context).get(context, "#{BASE_PATH}/")
    listed = Array(answer).filter_map { |entry| (entry.is_a?(Hash) && entry['itemtype'].is_a?(String) && !entry['itemtype'].empty?) ? entry['itemtype'] : nil }
    context.debug("#{type_name}: GET #{BASE_PATH}/ listed no definitions; only the catalog's are read") if listed.empty?
    @listed_definitions_read_at = Time.now
    @listed_definitions = listed.empty? ? nil : listed
  end

  def read_field(context, value, ref)
    return field_text(value) if ref.nil?

    text = value.nil? ? '' : value.to_s
    return '' if EMPTY_REFS.include?(text.strip)

    object = cached_list(context, REF_PATHS.fetch(ref)).find { |candidate| candidate['id'].to_s == text.strip }
    object ? PuppetX::Glpi::Names.normalize(object['name']) : "##{text.strip}"
  end

  # [changes (field => value to write), messages for declared reference
  # names that match nothing]. Plain fields compare as text; reference
  # fields by the id their name resolves to. +existing+ nil: every field.
  def field_plan(context, existing, should)
    stored = (existing && existing['custom_fields'].is_a?(Hash)) ? existing['custom_fields'] : {}
    refs = (should[:field_refs] || {}).transform_keys(&:to_s)
    changes = {}
    missing = []
    (should[:fields] || {}).each do |key, value|
      key = key.to_s
      current = stored[key].nil? ? '' : stored[key].to_s
      ref = refs[key]
      if ref.nil?
        changes[key] = value.to_s unless existing && same_field?(stored[key], value)
      elsif PuppetX::Glpi::Names.normalize(value).empty?
        changes[key] = '' unless existing && EMPTY_REFS.include?(current.strip)
      else
        id = resolve_ref(context, ref, value)
        if id.nil?
          missing << "#{definition_of(should)}/#{should[:name]}: field #{key}: no #{ref} matches '#{PuppetX::Glpi::Names.normalize(value)}'; " \
                     'the stored value is kept'
        elsif !(existing && current.strip == id.to_s)
          changes[key] = id
        end
      end
    end
    [changes, missing]
  end

  # A plain field as text for comparison: a JSON boolean as '1'/'0', a
  # datetime at midnight as its date (date fields come back either way).
  def field_text(value)
    return '1' if value == true
    return '0' if value == false

    text = PuppetX::Glpi::Names.normalize(value)
    text[%r{\A(\d{4}-\d{2}-\d{2})[ T]00:00:00\z}, 1] || text
  end

  # A declared value against the stored one. Against a boolean, 'true'/'1'
  # and 'false'/'0'/'' are the same value.
  def same_field?(stored, declared)
    if [true, false].include?(stored)
      wanted = to_bool(PuppetX::Glpi::Names.normalize(declared).downcase)
      return wanted == stored
    end
    field_text(stored) == field_text(declared)
  end

  def resolve_ref(context, ref, value)
    live = cached_list(context, REF_PATHS.fetch(ref)).reject { |object| trashed?(object) }
    if ref == 'Computer'
      computer = resolve_computer(live, value)
      return computer && to_int(computer['id'])
    end
    wanted = PuppetX::Glpi::Names.normalize(value)
    matches = live.select { |object| natural_key(object['name']) == natural_key(wanted) }
    if matches.size > 1
      raise Puppet::ResourceError,
            "#{type_name}: #{matches.size} GLPI #{ref} objects match '#{wanted}' (ids #{matches.map { |object| object['id'] }.join(', ')})"
    end
    matches.empty? ? nil : to_int(matches.first['id'])
  end

  # true, [false, message], or nil (no object: the default compare).
  def fields_state(context, name, should)
    object = lookup_object(context, name)
    return nil if object.nil?

    changes, missing = field_plan(context, object, should)
    # With fields to write, a failure waits until set has written them.
    report_unresolved(context, should, missing, write_pending: !changes.empty?)
    return true if changes.empty?

    [false, "change #{changes.keys.sort.join(', ')}"]
  end

  # After a write: the declared references that resolved to nothing.
  def unresolved_fields(context, should)
    _, missing = field_plan(context, nil, should)
    report_unresolved(context, should, missing)
  end

  # A warning each ('warn'), or one failure of the resource ('fail'; not
  # while +write_pending+, i.e. from an insync? that leaves fields for set
  # to write: set fails after writing them).
  def report_unresolved(context, should, missing, write_pending: false)
    return if missing.empty?

    if fail_unresolved?
      raise_unresolved(should, missing) unless write_pending
      return
    end

    @warned_fields ||= Set.new
    missing.each do |message|
      key = [message, @objects_read_at]
      next if @warned_fields.include?(key)

      @warned_fields << key
      context.warning(message)
    end
  end
end
