# frozen_string_literal: true

require_relative '../glpi_base_provider'
require_relative '../../../puppet_x/glpi/names'
require_relative '../../../puppet_x/glpi/lookups'

# @api private
module Puppet::Provider::GlpiCluster; end

# Provider for glpi_cluster over API v2 (/Management/Cluster).
#
# Adoption policy :skip_unmarked: an unmarked cluster of the same name is
# reported in sync and never written. Trashed clusters are invisible.
class Puppet::Provider::GlpiCluster::GlpiCluster < Puppet::Provider::GlpiBaseProvider
  include PuppetX::Glpi::Lookups

  TYPE_PATH = '/Dropdowns/ClusterType' unless const_defined?(:TYPE_PATH)

  def collection_path
    '/Management/Cluster'
  end

  def adoption_policy
    :skip_unmarked
  end

  def api_to_resource(_context, object)
    {
      name: PuppetX::Glpi::Names.normalize(object['name']),
      cluster_type: dropdown_label(object['type']),
      comment: strip_marker(object['comment']),
    }
  end

  # Existing cluster: comment (kept when not declared) and type. New
  # cluster: also name and the root entity. The base puts the marker first.
  def resource_to_api(context, should, existing)
    body = {}
    body['name'] = should[:name] unless existing
    comment = wanted_value(should, :comment, existing)
    body['comment'] = (comment.nil? && existing) ? strip_marker(existing['comment']) : comment.to_s
    type_id = dropdown_id(context, TYPE_PATH, wanted_value(should, :cluster_type, existing), 'entity' => 0, 'is_recursive' => true)
    body['type'] = type_id unless type_id.nil?
    existing ? body : body.merge('entity' => 0, 'is_recursive' => true)
  end

  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, is_hash, should_hash)
    result = super
    return result unless result.nil?
    return nil if should_hash[:ensure].to_s == 'absent' || is_hash.nil?
    return nil unless [:comment, :cluster_type].include?(attribute_name)

    if attribute_name == :cluster_type
      natural_key(is_hash[attribute_name]) == natural_key(should_hash[attribute_name])
    else
      PuppetX::Glpi::Names.same?(is_hash[attribute_name], should_hash[attribute_name])
    end
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition
end
