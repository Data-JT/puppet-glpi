# frozen_string_literal: true

require_relative '../../puppet_x/glpi/names'

# Wiring every glpi_* type needs: call
# +Puppet::Type::GlpiTransportAutorequire.register(:glpi_x)+ right after
# +Puppet::ResourceApi.register_type+.
#
# * Autorequires the transport file written by class +glpi+, so on the first
#   run the file exists before the provider changes anything.
# * Hands the provider the catalog's deletion plan for the type before the
#   first resource of that type is flushed. The Resource API calls +set+ once
#   per resource, so without the plan the purge guard could only count
#   deletions one at a time and would let the first ones through.
module Puppet::Type::GlpiTransportAutorequire
  CONFIG_FILE = 'glpi_transport.yaml'

  # Prepended to the type class.
  module DeletionPlanHook
    def initialize(attributes)
      super
      self.class.glpi_note_declared(self) if catalog
    end

    def flush
      plan = catalog && self.class.glpi_deletion_plan(catalog)
      my_provider.plan_deletions(catalog.object_id, plan[0], plan[1]) if plan && my_provider.respond_to?(:plan_deletions)
      super
    end
  end

  # Extended onto the type class: computes the plan once per catalog.
  module DeletionPlanCache
    # [titles wanted absent, titles of the present resources] of the catalog.
    def glpi_deletion_plan(catalog)
      unless @glpi_deletion_plan && @glpi_deletion_plan[0].equal?(catalog)
        absent = Puppet::Type::GlpiTransportAutorequire.planned_deletions(catalog, name)
        present = Puppet::Type::GlpiTransportAutorequire.declared_titles(catalog, name)
        @glpi_deletion_plan = [catalog, [absent, present]]
      end
      @glpi_deletion_plan[1]
    end

    # Called for every resource of the type made from a catalog (before any
    # `resources { purge => true }` generates its instances).
    def glpi_note_declared(resource)
      Puppet::Type::GlpiTransportAutorequire.note_declared(name, resource.catalog, resource.rsapi_title)
    end

    def glpi_noted_titles
      Puppet::Type::GlpiTransportAutorequire.noted_titles(name)
    end
  end

  # Prepended to the type's singleton class: `resources { purge => true }`
  # generates one resource per instance whose title is not in the catalog
  # (an exact compare). Natural keys are case-insensitive, so an instance
  # that differs from a declared title only in case is the declared object;
  # it is not offered for purge (the declared resource covers it).
  module InstancesFilter
    def instances
      list = super
      declared = glpi_noted_titles
      return list if declared.empty?

      keys = declared.map { |title| glpi_key_of(title) }
      list.reject { |instance| keys.include?(glpi_key_of(instance.rsapi_title)) }
    end

    def glpi_key_of(title)
      provider = my_provider
      if provider.respond_to?(:natural_key) && provider.respond_to?(:resource_key)
        provider.natural_key(provider.resource_key(title))
      else
        PuppetX::Glpi::Names.key(title.is_a?(Hash) ? title[:name] : title)
      end
    end
  end

  NOTES_LOCK = Mutex.new
  @noted = nil # [catalog, { type name => [titles] }]

  # Remembers the titles a catalog declares, whatever their ensure, per type.
  # One registry for all glpi_* types: the first resource of any glpi_* type
  # built from a new catalog drops what an older catalog (a daemon applies
  # many) left behind, also for a type this catalog does not declare at all
  # but may purge. The purge's own catalog is not reachable from `instances`.
  def self.note_declared(type_name, catalog, title)
    NOTES_LOCK.synchronize do
      @noted = [catalog, Hash.new { |hash, key| hash[key] = [] }] unless @noted && @noted[0].equal?(catalog)
      @noted[1][type_name.to_sym] << title
    end
  end

  def self.noted_titles(type_name)
    NOTES_LOCK.synchronize { @noted ? @noted[1].fetch(type_name.to_sym, []).dup : [] }
  end

  def self.register(type_name)
    type = Puppet::Type.type(type_name)
    type.autorequire(:file) { File.join(Puppet.settings[:confdir], CONFIG_FILE) }
    type.prepend(DeletionPlanHook) unless type.ancestors.include?(DeletionPlanHook)
    type.extend(DeletionPlanCache)
    type.singleton_class.prepend(InstancesFilter) unless type.singleton_class.ancestors.include?(InstancesFilter)
  end

  # Titles (Resource API titles: a String, or a Hash for composite namevars)
  # of the catalog's resources of +type_name+ whose target state is absent,
  # including the ones `resources { purge => true }` generated.
  # Fails closed: a resource of the type without the Resource API methods
  # this relies on raises instead of being left out of the plan.
  def self.planned_deletions(catalog, type_name)
    of_type = catalog.resources.select { |resource| resource.class.name.to_s == type_name.to_s }
    of_type.each do |resource|
      next if resource.respond_to?(:rsapi_canonicalized_target_state) && resource.respond_to?(:rsapi_title)

      raise Puppet::ResourceError,
            "#{type_name}: cannot build the deletion plan: #{resource.ref} lacks the Resource API methods " \
            'rsapi_canonicalized_target_state/rsapi_title (incompatible puppet-resource_api?)'
    end
    of_type.select { |resource| resource.rsapi_canonicalized_target_state[:ensure].to_s == 'absent' }.map(&:rsapi_title)
  end

  # Titles of the catalog's resources of +type_name+ that are not to be
  # absent. The provider needs them because natural keys are case-insensitive:
  # a purge-generated absent title that differs from a declared one only in
  # case names the declared object and must not delete it.
  def self.declared_titles(catalog, type_name)
    of_type = catalog.resources.select { |resource| resource.class.name.to_s == type_name.to_s }
    present = of_type.select do |resource|
      resource.respond_to?(:rsapi_canonicalized_target_state) && resource.respond_to?(:rsapi_title) &&
        resource.rsapi_canonicalized_target_state[:ensure].to_s != 'absent'
    end
    present.map(&:rsapi_title)
  end
end
