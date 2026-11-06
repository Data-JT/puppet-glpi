# frozen_string_literal: true

require_relative '../glpi_base_provider'
require_relative '../../../puppet_x/glpi/names'
require_relative '../../../puppet_x/glpi/lookups'
require_relative '../../../puppet_x/glpi/item_links'

# @api private
module Puppet::Provider::GlpiCertificate; end

# Provider for glpi_certificate over API v2:
#   /Assets/Certificate[/<id>]                               certificates
#   GraphQL Certificate_Item (itemtype==Computer)            the computer links (one paged read, shared)
#   /Assets/Computer/<computer id>/Certificate[/<link id>]   link / unlink one computer
#
# Adoption policy :adopt. Only Computer links are ever read or written.
class Puppet::Provider::GlpiCertificate::GlpiCertificate < Puppet::Provider::GlpiBaseProvider
  include PuppetX::Glpi::Lookups
  include PuppetX::Glpi::ItemLinks

  COMPUTER_PATH = '/Assets/Computer' unless const_defined?(:COMPUTER_PATH)

  def collection_path
    '/Assets/Certificate'
  end

  def link_spec
    {
      type: 'Certificate_Item',
      selection: 'id itemtype items_id certificate { id }',
      filter: 'itemtype==Computer',
      owner: ->(row) { row['certificate'].is_a?(Hash) ? to_int(row['certificate']['id']) : nil },
      peer: ->(row) { to_int(row['items_id']) },
      add: ->(certificate, computer) { ["#{COMPUTER_PATH}/#{computer}/Certificate", { 'certificate' => { 'id' => certificate } }] },
      remove: ->(_certificate, computer, link) { "#{COMPUTER_PATH}/#{computer}/Certificate/#{link}" },
    }
  end

  def api_to_resource(context, object)
    {
      name: PuppetX::Glpi::Names.normalize(object['name']),
      dns_name: PuppetX::Glpi::Names.normalize(object['dns_name']),
      serial: PuppetX::Glpi::Names.normalize(object['serial']),
      expiration: to_date(object['date_expiration']),
      self_signed: to_bool(object['is_selfsign']) == true,
      comment: strip_marker(object['comment']),
      computers: linked_peers(context, to_int(object['id'])).map { |id| computer_name(context, id) }.sort,
    }.merge(entity_attributes(context, object))
  end

  # New certificate: name, comment and every declared attribute. Existing
  # one: only what differs (the comment also when not marked yet).
  def resource_to_api(context, should, existing)
    body = {}
    body['name'] = should[:name] unless existing
    comment = comment_body(should, existing)
    body['comment'] = comment unless comment.nil?
    { dns_name: 'dns_name', serial: 'serial' }.each do |attribute, field|
      wanted = wanted_value(should, attribute, existing)
      next if wanted.nil? || (existing && PuppetX::Glpi::Names.same?(existing[field], wanted))

      body[field] = wanted
    end
    expiration = wanted_value(should, :expiration, existing)
    unless expiration.nil? || (existing && to_date(existing['date_expiration']) == expiration)
      body['date_expiration'] = expiration
    end
    unless should[:self_signed].nil? || (existing && (to_bool(existing['is_selfsign']) == true) == should[:self_signed])
      body['is_selfsign'] = should[:self_signed]
    end
    entity = resolvable_entity(context, should)
    body['entity'] = { 'id' => entity } unless entity.nil? || (existing && embedded_id(existing['entity']) == entity)
    body
  end

  def create(context, name, should)
    super
    sync_computers(context, name, should)
  end

  def update(context, name, should)
    super
    sync_computers(context, name, should)
  end

  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, is_hash, should_hash)
    result = super
    return result unless result.nil?
    return nil if should_hash[:ensure].to_s == 'absent' || is_hash.nil? || is_hash[:ensure].to_s == 'absent'

    case attribute_name
    when :comment, :dns_name, :serial
      PuppetX::Glpi::Names.same?(is_hash[attribute_name], should_hash[attribute_name])
    when :entity, :entity_tag
      return nil if should_hash[attribute_name].nil?

      object = lookup_object(context, name)
      return nil if object.nil?

      wanted = resolvable_entity(context, should_hash)
      wanted.nil? || embedded_id(object['entity']) == wanted
    when :computers
      computers_state(context, name, should_hash)
    end
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  private

  def computer_name(context, id)
    computer = cached_list(context, COMPUTER_PATH).find { |candidate| to_int(candidate['id']) == id }
    computer ? PuppetX::Glpi::Names.normalize(computer['name']) : "##{id}"
  end

  # [wanted computer ids, messages for names that match nothing].
  def wanted_computers(context, should)
    computers = cached_list(context, COMPUTER_PATH)
    missing = []
    ids = Array(should[:computers]).filter_map do |name|
      computer = resolve_computer(computers, name)
      missing << "glpi_certificate '#{should[:name]}': no Computer matches '#{PuppetX::Glpi::Names.normalize(name)}'; link skipped" if computer.nil?
      computer && to_int(computer['id'])
    end
    [ids.uniq, missing.uniq]
  end

  # [adds, removes, missing] for the certificate object.
  def computer_plan(context, certificate, should)
    wanted, missing = wanted_computers(context, should)
    exclusive = should[:computers_exclusive] != false
    adds, removes = link_plan(context, to_int(certificate['id']), wanted, ->(_computer) { exclusive })
    [adds, removes, missing]
  end

  def computers_state(context, name, should)
    certificate = lookup_object(context, name)
    return nil if certificate.nil?

    adds, removes, missing = computer_plan(context, certificate, should)
    in_sync = adds.empty? && removes.empty?
    # With links to write, a failure waits until set has written them.
    report_unresolved_links(context, should, missing, write_pending: !in_sync)
    return true if in_sync

    [false, "computers: #{plan_message(context, adds, removes)}"]
  end

  def plan_message(context, adds, removes)
    linked = adds.map { |id| "link '#{computer_name(context, id)}'" }
    unlinked = removes.map { |link| link['peer'] }.uniq.map { |id| "unlink '#{computer_name(context, id)}'" }
    (linked + unlinked).join('; ')
  end

  # After the certificate is written: its computer links, against the
  # certificate as read again after the write.
  def sync_computers(context, name, should)
    return if should[:computers].nil?

    certificate = lookup_object(context, name)
    raise Puppet::ResourceError, "glpi_certificate '#{resource_key(name)}' not found after writing it" if certificate.nil?
    return unless marked?(certificate)

    adds, removes, missing = computer_plan(context, certificate, should)
    write_links(context, to_int(certificate['id']), adds, removes)
    report_unresolved_links(context, should, missing)
  end
end
