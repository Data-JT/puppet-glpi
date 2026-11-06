# frozen_string_literal: true

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

Puppet::ResourceApi.register_type(
  name: 'glpi_domain',
  docs: <<-EOS,
@summary Manages a GLPI domain and its links to contracts through API v2.

Domains are matched by `name` among the domains that are not in the trash,
case-insensitively after HTML-entity decoding and Unicode normalisation.
The name is written as declared (Unicode included, e.g. an IDN in its
Unicode form).

* An unmarked domain of the same name is adopted: it gets the marker and
  is managed from then on (a one-time change).
* The marker is written first in the GLPI comment, followed by `comment`;
  `comment` reads back without it. Unset: the stored comment is kept.
* `expiration` is a date `YYYY-MM-DD` (GLPI reads it back with a time of
  day, which is ignored); an empty string clears it. Unset: not managed.
* `delete_properties` clears `comment` or `expiration` of an existing
  domain; the marker stays.
* `entity` / `entity_tag` select the entity by complete or unique name, or
  by tag (mutually exclusive). Unset: not managed.
* `contracts` are the contracts the domain is linked to, by name. The
  resource is authoritative only for the contracts named in
  `contract_scope` (unset: the contracts in `contracts`): a link to a
  contract outside the scope is never read, added or removed, so links
  made by hand or by other tools coexist. A declared contract outside a
  declared scope fails the resource. Moving a domain between two contracts
  of the scope links the new one and then unlinks the old one.
* A contract name that matches no live contract, or more than one, is
  skipped with a warning (class glpi `unresolved => 'warn'`) or fails the
  resource after the other links are written (`unresolved => 'fail'`).
  While any declared contract is unresolved, no contract link of the
  domain is removed at all (a typo must not strip the links that exist);
  the other links are still added.
* Reading the links uses the GLPI GraphQL API: the OAuth client needs the
  `graphql` scope in addition to `api` (see `glpi::api_access`).
* GLPI's `is_active` flag is not managed.
* `ensure => absent` and purge move a marked domain to the trash; an
  unmarked one is never deleted. With `restore_trashed` (class glpi) a
  marked trashed domain of the same name is restored instead.

@example A domain linked to a contract
  glpi_domain { 'example.com':
    expiration     => '2027-02-28',
    entity_tag     => '10001',
    contracts      => ['Hosting Customer A'],
    contract_scope => ['Hosting Customer A', 'Hosting Customer B'],
  }
  EOS
  features: ['simple_get_filter', 'custom_insync'],
  attributes: {
    ensure: {
      type: 'Enum[present, absent]',
      desc: 'Whether the domain should be present or absent (absent moves it to the trash).',
      default: 'present',
    },
    name: {
      type: 'String[1]',
      desc: 'The domain name, kept as declared.',
      behaviour: :namevar,
    },
    expiration: {
      type: 'Optional[Pattern[/\A(\d{4}-\d{2}-\d{2})?\z/]]',
      desc: 'The expiration date, `YYYY-MM-DD`. Empty string: cleared. Unset: not managed.',
    },
    comment: {
      type: 'Optional[String]',
      desc: 'The comment, without the marker. Unset: the stored comment is kept.',
    },
    entity: {
      type: 'Optional[String]',
      desc: 'Complete name or unique name of the entity. Unset: not managed.',
    },
    entity_tag: {
      type: 'Optional[String]',
      desc: 'Tag of the entity (alternative to `entity`), compared case-sensitively. Unset: not managed.',
    },
    contracts: {
      type: 'Optional[Array[String[1]]]',
      desc: 'Names of the contracts the domain is linked to (within `contract_scope`). Compared as an unordered set. Unset: links are not managed.',
    },
    contract_scope: {
      type: 'Optional[Array[String[1]]]',
      desc: 'Names of the contracts this resource is authoritative for. Unset: the contracts in `contracts`.',
      behaviour: :parameter,
    },
    delete_properties: {
      type: "Optional[Array[Enum['comment', 'expiration']]]",
      desc: 'Optional properties to clear on update, by attribute name. Removing an attribute from the manifest only stops Puppet managing it. The marker stays in the GLPI comment.',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_domain)

# @api private
# entity and entity_tag both select the entity: only one may be declared.
# Hands the provider a resource's contracts and contract_scope before its
# current state is read, so get() reads only the links of the scope.
module Puppet::Type::GlpiDomainHooks
  def validate
    super
    return unless self[:entity] && self[:entity_tag]

    raise Puppet::ResourceError, "glpi_domain[#{title}]: entity and entity_tag are mutually exclusive"
  end

  def refresh_current_state
    if my_provider.respond_to?(:declare_contracts)
      target = rsapi_canonicalized_target_state
      my_provider.declare_contracts(rsapi_title, target[:contracts], target[:contract_scope])
    end
    super
  end
end

glpi_domain_type = Puppet::Type.type(:glpi_domain)
glpi_domain_type.prepend(Puppet::Type::GlpiDomainHooks) unless glpi_domain_type.ancestors.include?(Puppet::Type::GlpiDomainHooks)
