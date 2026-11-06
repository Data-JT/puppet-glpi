# frozen_string_literal: true

require_relative '../glpi_base_provider'
require_relative '../../../puppet_x/glpi/names'

# @api private
module Puppet::Provider::GlpiLocation; end

# Provider for glpi_location over API v2 (/Dropdowns/Location).
#
# A match-and-update type (adoption policy :match_only): a location is
# identified by name AND parent (complete name of the parent, nil = top
# level), its comment is updated, it is never marked, moved or deleted.
# The API returns +parent+ as an object with the parent's id and name; the
# complete name of a location is rebuilt here from the parent chain.
class Puppet::Provider::GlpiLocation::GlpiLocation < Puppet::Provider::GlpiBaseProvider
  def collection_path
    '/Dropdowns/Location'
  end

  def adoption_policy
    :match_only
  end

  def creatable?
    true
  end

  # Every object gets its complete name and its parent's ('' = top level).
  def fetch_objects(context)
    list = Array(super)
    by_id = list.to_h { |object| [object['id'].to_s, object] }
    list.map { |object| object.merge('_path' => path_of(object, by_id), '_parent_path' => parent_path_of(object, by_id)) }
  end

  # A location read again after a write gets its complete names from the
  # cached list (with itself in place of its old entry).
  def cache_object(_context, fresh, path)
    by_id = (@objects || []).reject { |object| item_path(object) == path }.to_h { |object| [object['id'].to_s, object] }
    by_id[fresh['id'].to_s] = fresh
    fresh.merge('_path' => path_of(fresh, by_id), '_parent_path' => parent_path_of(fresh, by_id))
  end

  # Identity = complete name (parent path + name); names must not contain ' > '.
  def object_key(object)
    key_for(object['name'], object['_parent_path'])
  end

  def resource_key(name)
    return key_for(name, nil) unless name.is_a?(Hash)

    key_for(name[:name], name[:parent])
  end

  # Nothing is ever purged, so nothing is listed without names. A name whose
  # object cannot be read fails alone (logged), the others are still returned.
  def get(context, names = nil)
    return [] if names.nil? || names.empty?

    names.flat_map do |name|
      super(context, [name])
    rescue Puppet::ResourceError => error
      context.err("glpi_location '#{resource_key(name)}': #{error.message}")
      []
    end
  end

  # The API lists a location that is another location's parent with its id,
  # name, entity and parent only (observed on 11.0 / API v2: no comment, level
  # or complete name), so such an entry is read again by id, only when it was
  # matched.
  def api_to_resource(context, object)
    object = reread(context, object) unless object.key?('comment')
    parent = object['_parent_path'].to_s
    name = PuppetX::Glpi::Names.normalize(object['name'])
    {
      title: parent.empty? ? name : "#{parent} > #{name}",
      name: name,
      comment: PuppetX::Glpi::Names.normalize(object['comment']),
      parent: parent,
    }
  end

  # Existing location: the comment only (identity includes the parent, so
  # nothing is ever moved). New location: root entity, recursive, under the
  # parent (0 = top level).
  def resource_to_api(context, should, existing)
    body = {}
    comment = wanted_value(should, :comment, existing)
    body['comment'] = comment.to_s unless comment.nil? && existing
    return body if existing

    { 'name' => should[:name] }.merge(body).merge('entity' => 0, 'is_recursive' => true, 'parent' => parent_id(context, should[:parent]))
  end

  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, is_hash, should_hash)
    result = super
    return result unless result.nil?
    return nil if should_hash[:ensure].to_s == 'absent' || is_hash.nil?

    PuppetX::Glpi::Names.same?(is_hash[:comment], should_hash[:comment]) if attribute_name == :comment
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  private

  def key_for(name, parent)
    name = PuppetX::Glpi::Names.normalize(name)
    parent = PuppetX::Glpi::Names.normalize(parent)
    parent.empty? ? name : "#{parent} > #{name}"
  end

  def reread(context, object)
    full = transport(context).get(context, item_path(object))
    raise Puppet::ResourceError, "reading location #{object['id']} returned nothing" unless full.is_a?(Hash)

    full.merge('_path' => object['_path'], '_parent_path' => object['_parent_path'])
  rescue Puppet::ResourceError
    raise
  rescue StandardError => error
    raise Puppet::ResourceError, "reading location #{object['id']} failed: #{error.message}"
  end

  def path_of(object, by_id, seen = [])
    parent = parent_path_of(object, by_id, seen)
    name = PuppetX::Glpi::Names.normalize(object['name'])
    parent.empty? ? name : "#{parent} > #{name}"
  end

  def parent_path_of(object, by_id, seen = [])
    parent = object['parent']
    id = parent.is_a?(Hash) ? parent['id'].to_s : ''
    return '' if id.empty? || id == '0' || seen.include?(id)

    target = by_id[id]
    return PuppetX::Glpi::Names.normalize(parent['name']) if target.nil?

    path_of(target, by_id, seen + [id])
  end

  def parent_id(context, path)
    wanted = PuppetX::Glpi::Names.normalize(path)
    return 0 if wanted.empty?

    matches = objects(context).select { |object| natural_key(object['_path']) == natural_key(wanted) }
    raise Puppet::ResourceError, "glpi_location: unknown parent '#{wanted}'" if matches.empty?
    if matches.size > 1
      raise Puppet::ResourceError, "glpi_location: #{matches.size} locations have the complete name '#{wanted}'"
    end

    matches.first['id']
  end
end
