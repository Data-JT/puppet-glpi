# frozen_string_literal: true

require 'set'
require_relative '../glpi_base_provider'
require_relative '../../../puppet_x/glpi/names'
require_relative '../../../puppet_x/glpi/lookups'
require_relative '../../../puppet_x/glpi/item_links'

# @api private
module Puppet::Provider::GlpiDomain; end

# Provider for glpi_domain over API v2:
#   /Management/Domain[/<id>]                           domains
#   /Management/Contract                                contracts (matched by name)
#   GraphQL Contract_Item (itemtype==Domain)            the domain links of every contract (one paged read, shared)
#   /Management/Domain/<domain id>/Contract[/<link id>] link / unlink one contract
#
# Adoption policy :adopt. Only links to contracts of the resource's scope
# (contract_scope, else its contracts) are read or written.
class Puppet::Provider::GlpiDomain::GlpiDomain < Puppet::Provider::GlpiBaseProvider
  include PuppetX::Glpi::Lookups
  include PuppetX::Glpi::ItemLinks

  CONTRACT_PATH = '/Management/Contract' unless const_defined?(:CONTRACT_PATH)

  def collection_path
    '/Management/Domain'
  end

  def link_spec
    {
      type: 'Contract_Item',
      selection: 'id itemtype items_id contract { id }',
      filter: 'itemtype==Domain',
      owner: ->(row) { to_int(row['items_id']) },
      peer: ->(row) { row['contract'].is_a?(Hash) ? to_int(row['contract']['id']) : nil },
      add: ->(domain, contract) { ["#{collection_path}/#{domain}/Contract", { 'contract' => { 'id' => contract } }] },
      remove: ->(domain, _contract, link) { "#{collection_path}/#{domain}/Contract/#{link}" },
    }
  end

  # Called by the type before a resource's state is read: get() then reads
  # only the links to contracts of the scope (contract_scope, else
  # contracts). Undeclared (puppet resource, purge): every contract.
  def declare_contracts(name, contracts, scope)
    @scopes ||= {}
    names = scope.nil? ? contracts : scope
    @scopes[natural_key(resource_key(name))] = names.nil? ? nil : Array(names).map { |contract| natural_key(contract) }.to_set
  end

  def api_to_resource(context, object)
    scope = (@scopes || {})[natural_key(object_key(object))]
    contracts = linked_peers(context, to_int(object['id'])).filter_map do |id|
      name = contract_name(context, id)
      name if scope.nil? || scope.include?(natural_key(name))
    end
    {
      name: PuppetX::Glpi::Names.normalize(object['name']),
      expiration: to_date(object['date_expiration']),
      comment: strip_marker(object['comment']),
      contracts: contracts.sort,
    }.merge(entity_attributes(context, object))
  end

  # New domain: name (as declared), comment and every declared attribute.
  # Existing one: only what differs (the comment also when not marked yet).
  def resource_to_api(context, should, existing)
    body = {}
    body['name'] = should[:name] unless existing
    comment = comment_body(should, existing)
    body['comment'] = comment unless comment.nil?
    expiration = wanted_value(should, :expiration, existing)
    unless expiration.nil? || (existing && to_date(existing['date_expiration']) == expiration)
      body['date_expiration'] = expiration
    end
    entity = resolvable_entity(context, should)
    body['entity'] = { 'id' => entity } unless entity.nil? || (existing && embedded_id(existing['entity']) == entity)
    body
  end

  def create(context, name, should)
    super
    sync_contracts(context, name, should)
  end

  def update(context, name, should)
    super
    sync_contracts(context, name, should)
  end

  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, is_hash, should_hash)
    result = super
    return result unless result.nil?
    return nil if should_hash[:ensure].to_s == 'absent' || is_hash.nil? || is_hash[:ensure].to_s == 'absent'

    case attribute_name
    when :comment
      PuppetX::Glpi::Names.same?(is_hash[:comment], should_hash[:comment])
    when :entity, :entity_tag
      return nil if should_hash[attribute_name].nil?

      object = lookup_object(context, name)
      return nil if object.nil?

      wanted = resolvable_entity(context, should_hash)
      wanted.nil? || embedded_id(object['entity']) == wanted
    when :contracts
      contracts_state(context, name, should_hash)
    end
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  private

  def contract_name(context, id)
    contract = cached_list(context, CONTRACT_PATH).find { |candidate| to_int(candidate['id']) == id }
    contract ? PuppetX::Glpi::Names.normalize(contract['name']) : "##{id}"
  end

  def scope_keys(should)
    Array(should[:contract_scope] || should[:contracts]).to_set { |name| natural_key(name) }
  end

  # [wanted contract ids, keys of names that matched 0 or several live
  # contracts, messages for those]. A declared contract outside a declared
  # scope fails the resource.
  def wanted_contracts(context, should)
    scope = scope_keys(should)
    live = cached_list(context, CONTRACT_PATH).reject { |object| trashed?(object) }
    unresolved = Set.new
    missing = []
    ids = Array(should[:contracts]).filter_map do |declared|
      wanted = PuppetX::Glpi::Names.normalize(declared)
      unless scope.include?(natural_key(wanted))
        raise Puppet::ResourceError, "glpi_domain '#{should[:name]}': contract '#{wanted}' is not in contract_scope; no link was changed"
      end

      matches = live.select { |object| natural_key(object['name']) == natural_key(wanted) }
      next to_int(matches.first['id']) if matches.size == 1

      unresolved << natural_key(wanted)
      missing << if matches.empty?
                   "glpi_domain '#{should[:name]}': no live contract matches '#{wanted}'; link skipped"
                 else
                   "glpi_domain '#{should[:name]}': #{matches.size} live contracts match '#{wanted}' " \
                   "(ids #{matches.map { |object| object['id'] }.join(', ')}); link skipped, no contract link of the domain is removed"
                 end
      nil
    end
    [ids.uniq, unresolved, missing.uniq]
  end

  # [adds, removes, missing] for the domain object: a link is removable
  # when its contract is in the scope, and only while every declared
  # contract resolved (a typo must not strip the links that exist).
  def contract_plan(context, domain, should)
    wanted, unresolved, missing = wanted_contracts(context, should)
    scope = scope_keys(should)
    removable = ->(contract) do
      key = natural_key(contract_name(context, contract))
      unresolved.empty? && scope.include?(key)
    end
    adds, removes = link_plan(context, to_int(domain['id']), wanted, removable)
    [adds, removes, missing]
  end

  def contracts_state(context, name, should)
    domain = lookup_object(context, name)
    return nil if domain.nil?

    adds, removes, missing = contract_plan(context, domain, should)
    in_sync = adds.empty? && removes.empty?
    # With links to write, a failure waits until set has written them.
    report_unresolved_links(context, should, missing, write_pending: !in_sync)
    return true if in_sync

    [false, "contracts: #{plan_message(context, adds, removes)}"]
  end

  def plan_message(context, adds, removes)
    linked = adds.map { |id| "link '#{contract_name(context, id)}'" }
    unlinked = removes.map { |link| link['peer'] }.uniq.map { |id| "unlink '#{contract_name(context, id)}'" }
    (linked + unlinked).join('; ')
  end

  # After the domain is written: its contract links, against the domain as
  # read again after the write.
  def sync_contracts(context, name, should)
    return if should[:contracts].nil?

    domain = lookup_object(context, name)
    raise Puppet::ResourceError, "glpi_domain '#{resource_key(name)}' not found after writing it" if domain.nil?
    return unless marked?(domain)

    adds, removes, missing = contract_plan(context, domain, should)
    write_links(context, to_int(domain['id']), adds, removes)
    report_unresolved_links(context, should, missing)
  end
end
