# frozen_string_literal: true

require_relative 'names'

# @api private
module PuppetX; end
# @api private
module PuppetX::Glpi; end

# Helpers for providers of the GLPI base provider: dropdown values by name,
# cached lists of other collections, computers and entities by name or tag.
# Mixed into a subclass of Puppet::Provider::GlpiBaseProvider (uses its
# +transport+, +objects+, +shared_list+, +natural_key+, +trashed?+ and +type_name+).
module PuppetX::Glpi::Lookups
  LOCATION_PATH = '/Dropdowns/Location' unless const_defined?(:LOCATION_PATH)

  # id (String) => complete name of every location.
  def location_paths(context)
    tree_paths(cached_list(context, LOCATION_PATH))
  end

  # Id of the location +value+ denotes (complete name, else unique name);
  # 0 for an empty value (no location). Unknown or ambiguous: ResourceError.
  def location_id(context, value)
    return 0 if PuppetX::Glpi::Names.normalize(value).empty?

    tree_id(cached_list(context, LOCATION_PATH), location_paths(context), value, 'location', 'locations')
  end

  # A collection other than the type's own, read once per CACHE_TTL and
  # shared by every provider on the same transport (the base's shared_list).
  def cached_list(context, path)
    shared_list(context, path)
  end

  def drop_cached_list(context, path)
    drop_shared_list(context, path)
  end

  # The one computer of +computers+ (not trashed) that +name+ denotes:
  # matched case-insensitively by full name, else by the first DNS label
  # of +name+ (agents may register short names). nil if none,
  # Puppet::ResourceError if several match at the deciding step.
  def resolve_computer(computers, name)
    live = Array(computers).reject { |object| trashed?(object) }
    wanted = PuppetX::Glpi::Names.normalize(name)
    match = unique_computer(wanted, live.select { |object| natural_key(object['name']) == natural_key(wanted) })
    return match if match

    short = wanted.split('.').first.to_s
    return nil if short.empty? || short == wanted

    unique_computer(wanted, live.select { |object| natural_key(object['name']) == natural_key(short) })
  end

  # id (String) => complete name ("A > B > C", decoded) of every object of a
  # tree dropdown (locations, entities), rebuilt from the parent chain: the
  # API lists an object that is another one's parent without its complete
  # name. A parent outside the list contributes its embedded name.
  def tree_paths(list)
    by_id = Array(list).to_h { |object| [object['id'].to_s, object] }
    paths = {}
    by_id.each_key { |id| tree_path(id, by_id, paths, []) }
    paths
  end

  # Name of a dropdown value as the API embeds it ({id, name} or nil); ''
  # for none.
  def dropdown_label(value)
    value.is_a?(Hash) ? PuppetX::Glpi::Names.normalize(value['name']) : ''
  end

  # Id of the dropdown value +name+ in +path+, created with +create_body+
  # when missing. '' means none (0); nil means not managed (nil).
  def dropdown_id(context, path, name, create_body = {})
    return nil if name.nil?

    wanted = PuppetX::Glpi::Names.normalize(name)
    return 0 if wanted.empty?

    matches = cached_list(context, path).select { |object| natural_key(object['name']) == natural_key(wanted) }
    if matches.size > 1
      raise Puppet::ResourceError,
            "#{type_name}: #{matches.size} values named '#{wanted}' in #{path} (ids #{matches.map { |object| object['id'] }.join(', ')})"
    end
    return to_int(matches.first['id']) if matches.size == 1

    context.info("#{type_name}: creating '#{wanted}' in #{path}")
    created = transport(context).post(context, path, { 'name' => wanted }.merge(create_body))
    id = created.is_a?(Hash) ? to_int(created['id']) : nil
    unless id.is_a?(Integer)
      drop_cached_list(context, path)
      raise Puppet::ResourceError, "#{type_name}: creating '#{wanted}' in #{path} returned no id"
    end

    # Into the shared list, so the next resource (of any type) finds it.
    refresh_shared_entry(context, path, id)
    id
  end

  # ---- entities -----------------------------------------------------------

  ENTITY_PATH = '/Administration/Entity' unless const_defined?(:ENTITY_PATH)

  # Every entity (shared list).
  def entities(context)
    cached_list(context, ENTITY_PATH)
  end

  # Entity id (String) => complete name.
  def entity_paths(context)
    tree_paths(entities(context))
  end

  # Id of the entity whose complete name is +value+, else of the one entity
  # named +value+; Puppet::ResourceError if none or several.
  def entity_id(context, value)
    tree_id(entities(context), entity_paths(context), value, 'entity', 'entities')
  end

  # Id of the one entity whose tag is +value+ (compared case-sensitively);
  # Puppet::ResourceError if none or several.
  def entity_id_by_tag(context, value)
    wanted = PuppetX::Glpi::Names.normalize(value)
    ids = entities(context).map { |entity| to_int(entity['id']) }.select { |id| entity_tag_of(context, id) == wanted }
    raise Puppet::ResourceError, "#{type_name}: no GLPI entity has the tag '#{wanted}'" if ids.empty?
    raise Puppet::ResourceError, "#{type_name}: #{ids.size} GLPI entities have the tag '#{wanted}' (ids #{ids.join(', ')})" if ids.size > 1

    ids.first
  end

  # Entity id a target state asks for: by +entity_tag+, else by +entity+;
  # nil when neither is set (the entity is not managed).
  def wanted_entity(context, should)
    return entity_id_by_tag(context, should[:entity_tag]) unless should[:entity_tag].nil?
    return entity_id(context, should[:entity]) unless should[:entity].nil?

    nil
  end

  # { entity: complete name, entity_tag: tag or nil } of a GLPI object.
  def entity_attributes(context, object)
    id = embedded_id(object['entity'])
    tag = entity_tag_of(context, id)
    { entity: entity_paths(context).fetch(id.to_s) { embedded_label(object['entity']) }, entity_tag: tag.empty? ? nil : tag }
  end

  # Tag of an entity ('' = none). The API lists an entity that is another
  # one's parent without its tag; such an entity is read by id, once per
  # CACHE_TTL (writes of assets do not change entities, so the cache
  # outlives invalidate_objects).
  def entity_tag_of(context, entity_id)
    ttl = self.class::CACHE_TTL
    @entity_tags = nil if @entity_tags_read_at && Time.now - @entity_tags_read_at > ttl
    unless @entity_tags
      @entity_tags = {}
      @entity_tags_read_at = Time.now
    end
    return @entity_tags[entity_id] if @entity_tags.key?(entity_id)

    entity = entities(context).find { |candidate| to_int(candidate['id']) == entity_id }
    entity = transport(context).get(context, "#{ENTITY_PATH}/#{entity_id}") if entity && !entity.key?('tag')
    @entity_tags[entity_id] = entity.is_a?(Hash) ? PuppetX::Glpi::Names.normalize(entity['tag']) : ''
  end

  # Id of an embedded dropdown value ({id, name} or nil); 0 for none.
  def embedded_id(value)
    value.is_a?(Hash) ? to_int(value['id']).to_i : 0
  end

  # Complete name (else name) of an embedded dropdown value; '' for none.
  def embedded_label(value)
    return '' unless value.is_a?(Hash)

    PuppetX::Glpi::Names.normalize(value['completename'] || value['name'])
  end

  # Id of the tree dropdown object whose complete name is +value+, else of
  # the one object named +value+.
  def tree_id(list, paths, value, singular, plural)
    wanted = PuppetX::Glpi::Names.normalize(value)
    by_path = paths.select { |_id, path| natural_key(path) == natural_key(wanted) }.keys
    by_path = list.select { |object| natural_key(object['name']) == natural_key(wanted) }.map { |object| object['id'].to_s } if by_path.empty?
    raise Puppet::ResourceError, "#{type_name}: no GLPI #{singular} '#{wanted}' (complete name or unique name)" if by_path.empty?
    if by_path.size > 1
      raise Puppet::ResourceError,
            "#{type_name}: #{by_path.size} GLPI #{plural} are named '#{wanted}' (ids #{by_path.join(', ')}); use the complete name"
    end

    to_int(by_path.first)
  end

  private

  def unique_computer(wanted, matches)
    return matches.first if matches.size <= 1

    raise Puppet::ResourceError,
          "#{type_name}: #{matches.size} GLPI computers match '#{wanted}' (ids #{matches.map { |object| object['id'] }.join(', ')})"
  end

  def tree_path(id, by_id, paths, seen)
    return paths[id] if paths.key?(id)

    object = by_id[id]
    name = PuppetX::Glpi::Names.normalize(object['name'])
    parent = object['parent']
    parent_id = parent.is_a?(Hash) ? parent['id'].to_s : ''
    prefix = if parent_id.empty? || parent_id == id || seen.include?(parent_id) || (parent_id == '0' && !by_id.key?('0'))
               ''
             elsif by_id.key?(parent_id)
               tree_path(parent_id, by_id, paths, seen + [id])
             else
               PuppetX::Glpi::Names.normalize(parent['name'])
             end
    paths[id] = prefix.empty? ? name : "#{prefix} > #{name}"
  end
end
