# frozen_string_literal: true

require 'puppet/resource_api'
require_relative 'glpi_transport_autorequire'

Puppet::ResourceApi.register_type(
  name: 'glpi_certificate',
  docs: <<-EOS,
@summary Manages a GLPI certificate and its links to computers through API v2.

Certificates are matched by `name` among the certificates that are not in
the trash, case-insensitively after HTML-entity decoding and Unicode
normalisation (a certificate CN in another case is the same certificate).

* An unmarked certificate of the same name is adopted: it gets the marker
  and is managed from then on (a one-time change).
* The marker is written first in the GLPI comment, followed by `comment`;
  `comment` reads back without it. Unset: the stored comment is kept.
* `dns_name`, `serial`, `expiration` and `self_signed` are written as GLPI
  stores them (`dns_name`, `serial`, `date_expiration`, `is_selfsign`).
  `expiration` is a date `YYYY-MM-DD`; an empty string clears it. Unset
  attributes are not managed.
* `delete_properties` clears `comment`, `dns_name`, `expiration` or `serial`
  of an existing certificate; the marker stays.
* `entity` is an entity's complete name (`Root entity > Customer A`) or a
  unique entity name; `entity_tag` selects the entity by its tag instead
  (mutually exclusive). Unset: not managed; a new certificate is then
  created in the default entity of the API user.
* `computers` are the computers the certificate is linked to. A computer
  matches by name case-insensitively, or by the first DNS label when the
  full name matches nothing. Only links to computers are read or written;
  links of the certificate to other item types are never touched. With
  `computers_exclusive` (default) a link to an undeclared computer is
  removed; without it, missing links are added and none is ever removed.
  A computer that matches nothing is skipped with a warning (class glpi
  `unresolved => 'warn'`) or fails the resource after the other links are
  written (`unresolved => 'fail'`). GLPI may hold the same link twice; it
  reads as one link, and an unwanted pair is removed with all its rows.
* Reading the links uses the GLPI GraphQL API: the OAuth client needs the
  `graphql` scope in addition to `api` (see `glpi::api_access`).
* `ensure => absent` and purge move a marked certificate to the trash; an
  unmarked one is never deleted. With `restore_trashed` (class glpi) a
  marked trashed certificate of the same name is restored instead of
  creating a new one.

@example A certificate linked to a computer
  glpi_certificate { 'www.example.com':
    dns_name    => 'www.example.com',
    serial      => '04A1B2C3',
    expiration  => '2027-02-28',
    self_signed => false,
    entity      => 'Root entity > Customer A',
    computers   => ['web1.example.com'],
  }
  EOS
  features: ['simple_get_filter', 'custom_insync'],
  attributes: {
    ensure: {
      type: 'Enum[present, absent]',
      desc: 'Whether the certificate should be present or absent (absent moves it to the trash).',
      default: 'present',
    },
    name: {
      type: 'String[1]',
      desc: 'The certificate name (e.g. its common name).',
      behaviour: :namevar,
    },
    dns_name: {
      type: 'Optional[String]',
      desc: 'The DNS name. Unset: not managed.',
    },
    serial: {
      type: 'Optional[String]',
      desc: 'The serial number. Unset: not managed.',
    },
    expiration: {
      type: 'Optional[Pattern[/\A(\d{4}-\d{2}-\d{2})?\z/]]',
      desc: 'The expiration date, `YYYY-MM-DD`. Empty string: cleared. Unset: not managed.',
    },
    self_signed: {
      type: 'Optional[Boolean]',
      desc: 'Whether the certificate is self-signed. Unset: not managed.',
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
    computers: {
      type: 'Optional[Array[String[1]]]',
      desc: 'Names of the computers the certificate is linked to. Compared as an unordered set. Unset: links are not managed.',
    },
    computers_exclusive: {
      type: 'Boolean',
      desc: 'Whether links to computers not in `computers` are removed. False: missing links are added, none is removed.',
      default: true,
      behaviour: :parameter,
    },
    delete_properties: {
      type: "Optional[Array[Enum['comment', 'dns_name', 'expiration', 'serial']]]",
      desc: 'Optional properties to clear on update, by attribute name. Removing an attribute from the manifest only stops Puppet managing it. The marker stays in the GLPI comment.',
    },
  },
)

Puppet::Type::GlpiTransportAutorequire.register(:glpi_certificate)

# @api private
# entity and entity_tag both select the entity: only one may be declared.
module Puppet::Type::GlpiCertificateValidation
  def validate
    super
    return unless self[:entity] && self[:entity_tag]

    raise Puppet::ResourceError, "glpi_certificate[#{title}]: entity and entity_tag are mutually exclusive"
  end
end

glpi_certificate_type = Puppet::Type.type(:glpi_certificate)
glpi_certificate_type.prepend(Puppet::Type::GlpiCertificateValidation) unless glpi_certificate_type.ancestors.include?(Puppet::Type::GlpiCertificateValidation)
