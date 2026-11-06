# frozen_string_literal: true

require 'puppet/resource_api/simple_provider'
require 'digest'
require 'set'
require 'yaml'
require_relative '../../puppet_x/glpi/names'

# Shared base for the glpi_* providers: transport, ownership markers,
# adoption of existing objects, and the purge guard.
#
# A provider for one GLPI collection subclasses this and supplies
#
# * +collection_path+ (e.g. +'/Assets/Computer'+),
# * +api_to_resource(context, object)+: GLPI object => resource hash
#   (symbol keys, values coerced to the type; no +:ensure+),
# * +resource_to_api(context, should, existing)+: resource hash => request
#   body (string keys; +existing+ is the GLPI object or nil). Put +'comment'+
#   into the body only for a type with a user-visible comment attribute.
#
# and may override +object_key+ / +resource_key+ (natural key, default
# +name+), +collection_query+, +item_path+, +create_path+, +fetch_objects+,
# +adoption_policy+, +creatable?+.
# Types using it declare the features +simple_get_filter+ and
# +custom_insync+, and call +Puppet::Type::GlpiTransportAutorequire.register+.
# See Claude.md, "Provider contract".
class Puppet::Provider::GlpiBaseProvider < Puppet::ResourceApi::SimpleProvider
  # Raised when the transport file written by class glpi is absent or unusable.
  class TransportConfigMissing < Puppet::ResourceError; end

  CONFIG_FILE        = 'glpi_transport.yaml'
  DEFAULT_MARKER     = '[managed by puppet]'
  DEFAULT_FRACTION   = 0.5
  # Absolute ceiling on deletions per guard scope and run, next to the
  # fraction: a run that misses part of its inputs must not retire a large
  # share of a big type in one go, however often runs come.
  DEFAULT_MAX_PER_RUN = 3
  CONNECTION_KEYS    = [:base_url, :client_id, :client_secret, :username, :password,
                        :grant_type, :ssl_verify, :ssl_ca_file, :timeout].freeze
  ADOPTION_POLICIES  = [:adopt, :skip_unmarked, :match_only].freeze
  # The collection is read once and reused for this long, so a run reads it
  # once rather than once per resource; a write updates it in place (the
  # written object is read again by id). Bounded so a long-lived agent
  # daemon never carries it into the next run: writes do not extend it.
  CACHE_TTL          = 60

  # Whether natural keys are compared case-sensitively. GLPI treats names
  # case-insensitively, so none of the shipped providers opts in; a provider
  # class may override this to return true.
  def self.case_sensitive_keys?
    false
  end

  def self.config_path
    File.join(Puppet.settings[:confdir], CONFIG_FILE)
  end

  def self.read_transport_config
    config = YAML.safe_load_file(config_path)
    unless config.is_a?(Hash)
      raise TransportConfigMissing,
            "GLPI transport config at #{config_path} is empty or not a YAML mapping; " \
            'apply class glpi before managing glpi_* resources'
    end
    config.transform_keys(&:to_sym)
  rescue Errno::ENOENT, Errno::ENOTDIR
    raise TransportConfigMissing,
          "GLPI transport config not found at #{config_path}; apply class glpi before managing glpi_* resources"
  end

  def self.connection_info(config)
    config.slice(*CONNECTION_KEYS)
  end

  def self.build_transport(context, connection_info)
    require_relative '../transport/glpi'
    Puppet::Transport::Glpi.new(context, connection_info)
  end

  SHARED_TRANSPORTS      = {} # rubocop:disable Style/MutableConstant -- process-wide registry
  # transport => { path => [read_at, list] }: lookup lists shared by every
  # provider using that transport (see shared_list).
  SHARED_LISTS           = {}.compare_by_identity
  SHARED_TRANSPORTS_LOCK = Mutex.new

  # One transport (one connection, one token set) per process for every
  # glpi_* provider reading the same transport file in the same state. A
  # changed file (new +signature+) builds a new one and closes the old.
  # Per-process state that all providers should share (e.g. lookup caches)
  # can hang off the returned object.
  def self.shared_transport(context, signature)
    key = [config_path, signature]
    SHARED_TRANSPORTS_LOCK.synchronize do
      SHARED_TRANSPORTS[key] ||= begin
        stale = SHARED_TRANSPORTS.keys.select { |entry| entry[0] == key[0] }
        built = build_transport(context, connection_info(read_transport_config))
        stale.each do |entry|
          old = SHARED_TRANSPORTS.delete(entry)
          SHARED_LISTS.delete(old)
          old.close if old.respond_to?(:close)
        end
        built
      end
    end
  end

  # Forgets every shared transport and list without closing (for specs).
  def self.reset_shared_transports!
    SHARED_TRANSPORTS_LOCK.synchronize do
      SHARED_TRANSPORTS.clear
      SHARED_LISTS.clear
    end
  end

  # The list cache of +transport+ (path => [read_at, list]).
  def self.shared_lists_for(transport)
    SHARED_TRANSPORTS_LOCK.synchronize { SHARED_LISTS[transport] ||= {} }
  end

  # 'glpi_rule' for Puppet::Provider::GlpiRule::GlpiRule.
  def self.glpi_type_name
    segment = name.split('::')[-2] || name.split('::').last
    segment.gsub(%r{([a-z\d])([A-Z])}, '\1_\2').downcase
  end

  # ---- interface for subclasses -------------------------------------------

  def collection_path
    raise NotImplementedError, "#{self.class} must implement collection_path"
  end

  def collection_query
    {}
  end

  def api_to_resource(_context, _object)
    raise NotImplementedError, "#{self.class} must implement api_to_resource"
  end

  def resource_to_api(_context, _should, _existing)
    raise NotImplementedError, "#{self.class} must implement resource_to_api"
  end

  # Natural key of a GLPI object (raw; compared normalized).
  def object_key(object)
    object['name']
  end

  # Natural key of a resource title (String, or Hash for composite namevars).
  def resource_key(name)
    name.is_a?(Hash) ? name[:name] : name
  end

  def item_path(object)
    "#{collection_path}/#{object['id']}"
  end

  # Where create() POSTs a new object. Override when the collection depends
  # on the resource (e.g. one type spanning several GLPI collections).
  def create_path(_should)
    collection_path
  end

  # The raw collection (all objects the type can see), read by objects().
  # Override to merge several GLPI collections into one list.
  def fetch_objects(context)
    transport(context).get_all(context, collection_path, collection_query)
  end

  # :adopt         unmarked same-key object: get() reports it absent, create()
  #                updates it and adds the marker (one-time change).
  # :skip_unmarked unmarked same-key object: reported in sync with a warning,
  #                never written or deleted, never duplicated.
  # :match_only    objects matched by key and updated; never marked, never
  #                deleted, so never purged. No marker semantics.
  def adoption_policy
    :adopt
  end

  # Whether create() may POST a new object. match_only types typically
  # manage settings of objects that must already exist.
  def creatable?
    adoption_policy != :match_only
  end

  def type_name
    self.class.glpi_type_name
  end

  # The purge guard counts per scope: the allowance, the baseline and the
  # pending and done deletions are kept for each value this returns. The
  # default is one scope for the whole type (''). A type whose objects fall
  # into independent groups (e.g. one collection holding several kinds)
  # overrides it. Called with either a raw GLPI object (Hash with string
  # keys, from the list) or a resource title as the plan hands it over (a
  # String, or a Hash with symbol keys for composite namevars); both must
  # yield the same scope for the same object.
  def guard_scope(_key_or_object)
    ''
  end

  # ---- transport and settings ---------------------------------------------

  def transport(context)
    signature = config_signature
    if @transport.nil? || signature != @transport_signature
      @transport = self.class.shared_transport(context, signature)
      @transport_signature = signature
    end
    @transport
  end

  # marker, type_markers, purge_max_fraction, purge_max_per_run, unresolved,
  # restore_trashed, type_restore_trashed from the transport file;
  # defaults while it does not exist yet. purge_max_per_run 0 (or null)
  # means no absolute cap; absent, DEFAULT_MAX_PER_RUN.
  def module_settings
    signature = config_signature
    return @module_settings if @module_settings && signature == @settings_signature

    config = read_config_or_empty
    @settings_signature = signature
    @module_settings = {
      marker: (config[:marker] || DEFAULT_MARKER).to_s,
      type_markers: (config[:type_markers] || {}).to_h.transform_keys(&:to_s),
      purge_max_fraction: (config[:purge_max_fraction] || DEFAULT_FRACTION).to_f,
      purge_max_per_run: config.key?(:purge_max_per_run) ? config[:purge_max_per_run]&.to_i : DEFAULT_MAX_PER_RUN,
      unresolved: (config[:unresolved] || 'warn').to_s,
      restore_trashed: config[:restore_trashed] == true,
      type_restore_trashed: (config[:type_restore_trashed] || {}).to_h.transform_keys(&:to_s),
    }
  end

  # Whether create() restores a marked trashed object of the wanted key
  # instead of POSTing a new one: transport file +type_restore_trashed+
  # (type name => Boolean) over +restore_trashed+ (default false).
  def restore_trashed?
    per_type = module_settings[:type_restore_trashed]
    return per_type[type_name.to_s] == true if per_type.key?(type_name.to_s)

    module_settings[:restore_trashed]
  end

  # ---- unresolved references ----------------------------------------------

  # Whether a reference that matches no GLPI object fails the resource
  # (class glpi +unresolved => 'fail'+) instead of only warning.
  def fail_unresolved?
    module_settings[:unresolved] == 'fail'
  end

  # 'fail' mode: raises Puppet::ResourceError with +messages+ (the warning
  # texts), once per resource and run. +should+ identifies the resource: the
  # Resource API hands the same target-state hash to every insync? call of a
  # resource and to its set, and a new one on the next run. Raised from
  # insync?, Puppet records a failure event for that property and no change
  # (with nothing else to sync, set is not called); raised from set (after
  # the resolvable part is written), the resource fails "Could not evaluate".
  # Either way the resource counts as failed (report status failed,
  # --detailed-exitcodes bit 4) and resources depending on it are skipped.
  def raise_unresolved(should, messages)
    return if messages.empty? || unresolved_reported?(should)

    @unresolved_reported = should
    raise Puppet::ResourceError, messages.join('; ')
  end

  def unresolved_reported?(should)
    @unresolved_reported.equal?(should)
  end

  # ---- markers ------------------------------------------------------------

  def marker_for(type_name = self.type_name)
    module_settings[:type_markers][type_name.to_s] || module_settings[:marker]
  end

  def managed?(comment, type_name = self.type_name)
    PuppetX::Glpi::Names.normalize(comment).include?(marker_for(type_name))
  end

  # Comment of a type with a comment attribute: "<marker>\n<comment>".
  # Idempotent.
  def with_marker(comment, type_name = self.type_name)
    body = strip_marker(comment, type_name)
    marker = marker_for(type_name)
    body.empty? ? marker : "#{marker}\n#{body}"
  end

  # The user-visible comment: decoded, marker and its newline removed.
  def strip_marker(comment, type_name = self.type_name)
    marker = Regexp.escape(marker_for(type_name))
    PuppetX::Glpi::Names.normalize(comment)
                        .sub(%r{\A#{marker}[ \t]*\r?\n?}, '')
                        .sub(%r{\r?\n?[ \t]*#{marker}\z}, '')
                        .strip
  end

  # Comment of a type without a comment attribute: the existing comment
  # with the marker appended once.
  def append_marker(comment, type_name = self.type_name)
    return comment.to_s if managed?(comment, type_name)

    [comment.to_s.strip, marker_for(type_name)].reject(&:empty?).join("\n")
  end

  def marked?(object)
    adoption_policy != :match_only && managed?(object['comment'])
  end

  # ---- lookup -------------------------------------------------------------

  # Comparison form of a natural key: normalized and case-folded (unless the
  # class opts out with case_sensitive_keys?).
  def natural_key(key)
    PuppetX::Glpi::Names.key(key, fold: !self.class.case_sensitive_keys?)
  end

  # GLPI lists trashed objects (is_deleted) together with live ones.
  def trashed?(object)
    [true, 1, '1', 'true'].include?(object['is_deleted'])
  end

  # The one marked trashed object of key +name+ that create() may restore;
  # nil if none, Puppet::ResourceError if several.
  def restorable_trashed(name)
    wanted  = natural_key(resource_key(name))
    matches = Array(@trashed_objects).select do |object|
      natural_key(object_key(object)) == wanted && marked?(object)
    end
    return matches.first if matches.size <= 1

    raise Puppet::ResourceError,
          "#{type_name}: #{matches.size} trashed GLPI objects match the key '#{PuppetX::Glpi::Names.normalize(resource_key(name))}' " \
          "(ids #{matches.map { |object| object['id'] }.join(', ')}); purge all but one in GLPI"
  end

  # Restoring +restored+: an unmarked trashed object of the same key is
  # never restored; say that it stays in the trash.
  def warn_unmarked_trashed(context, name, restored)
    wanted = natural_key(resource_key(name))
    Array(@trashed_objects).each do |object|
      next if object['id'].to_s == restored['id'].to_s || marked?(object)
      next unless natural_key(object_key(object)) == wanted

      context.warning("#{type_name}: an unmarked trashed GLPI object '#{PuppetX::Glpi::Names.normalize(object_key(object))}' " \
                      "(id #{object['id']}) has the same key; it stays in the trash, the marked one (id #{restored['id']}) is restored")
    end
  end

  # A same-key object exists only in the trash: say that a new one is
  # created instead of restoring it.
  def warn_trashed(context, name)
    wanted = natural_key(resource_key(name))
    Array(@trashed_objects).each do |object|
      next unless natural_key(object_key(object)) == wanted

      context.warning("#{type_name}: a trashed GLPI object '#{PuppetX::Glpi::Names.normalize(resource_key(name))}' " \
                      "(id #{object['id']}) exists; it is not restored, a new object is created")
    end
  end

  # The one object whose natural key matches +key+ (normalized, case-folded);
  # nil if none. Several live objects of the key: the one carrying the
  # marker when exactly one does (the unmarked ones are left alone, said
  # once per key and run through +context+, if given); otherwise
  # Puppet::ResourceError. A :match_only type has no marker, so it always
  # raises on several.
  def find_unique(objects, key, context = nil)
    wanted  = natural_key(key)
    matches = objects.select { |object| natural_key(object_key(object)) == wanted }
    return matches.first if matches.size <= 1

    marked = matches.select { |object| marked?(object) }
    if marked.size == 1
      note_unmarked_twins(context, key, marked.first, matches - marked)
      return marked.first
    end

    raise Puppet::ResourceError,
          "#{type_name}: #{matches.size} GLPI objects match the key '#{PuppetX::Glpi::Names.normalize(key)}' " \
          "(ids #{matches.map { |object| object['id'] }.join(', ')}); make the key unique in GLPI"
  end

  def objects(context)
    unless objects_cached?
      list = Array(fetch_objects(context))
      # Trashed objects are never matched, adopted or purged; they are only
      # remembered for create()'s warning.
      @trashed_objects = list.select { |object| trashed?(object) }
      @objects = list.reject { |object| trashed?(object) }
      @objects_read_at = Time.now
    end
    @objects
  end

  def invalidate_objects
    @objects = nil
  end

  # The written object as the cached list holds it (e.g. tagged with its
  # collection or decorated with derived fields), from +fresh+, the object
  # read again at +path+ after the write. nil drops it from the list (e.g. a
  # trashed object of a type that hides the trash).
  def cache_object(_context, fresh, _path)
    fresh
  end

  # Whether +fresh+ (read again at +path+) carries everything the cached
  # list needs; false falls back to a full re-read.
  def cacheable?(fresh, _path)
    fresh.is_a?(Hash) && !fresh['id'].nil?
  end

  # ---- shared lookup lists ------------------------------------------------

  # A collection other than the type's own (computers, entities, dropdown
  # values), read once per CACHE_TTL and shared by every provider using the
  # same transport, so a run reads it once, not once per type.
  def shared_list(context, path)
    lists = self.class.shared_lists_for(transport(context))
    cached = lists[path]
    return cached[1] if cached && Time.now - cached[0] <= CACHE_TTL

    list = Array(transport(context).get_all(context, path, {}))
    lists[path] = [Time.now, list]
    list
  end

  def drop_shared_list(context, path)
    self.class.shared_lists_for(transport(context)).delete(path)
  end

  # Writes +object+ into the shared list of +path+ (replaced by id, else
  # added); +object+ nil removes the entry with +id+. A list not cached
  # (or expired) is left alone: its next read is a full one.
  def update_shared_list(context, path, id, object)
    lists = self.class.shared_lists_for(transport(context))
    cached = lists[path]
    return if cached.nil?
    return lists.delete(path) if Time.now - cached[0] > CACHE_TTL

    kept = cached[1].reject { |entry| entry['id'].to_s == id.to_s }
    lists[path] = [cached[0], object ? kept + [object] : kept]
  end

  # Reads +id+ of the shared list +path+ again after a write and puts it in
  # the list; on failure the list is dropped (next use reads it whole).
  def refresh_shared_entry(context, path, id)
    return unless shared_list_cached?(context, path)

    fresh = transport(context).get(context, "#{path}/#{id}")
    return drop_shared_list(context, path) unless fresh.is_a?(Hash) && fresh['id'].to_s == id.to_s

    update_shared_list(context, path, id, fresh)
  rescue StandardError => error
    context.debug("#{type_name}: re-reading #{path}/#{id} failed (#{error.message}); list dropped")
    drop_shared_list(context, path)
  end

  def lookup_object(context, name)
    find_unique(objects(context), resource_key(name), context)
  end

  # ---- Resource API -------------------------------------------------------

  # Without names (purge, `puppet resource`): marked objects only (all
  # objects for :match_only). With names: the requested ones, unmarked
  # included as the adoption policy says.
  def get(context, names = nil)
    all = objects(context)
    (names.nil? || names.empty?) ? list_resources(context, all) : requested_resources(context, all, names)
  rescue TransportConfigMissing
    @transport_config_missing = true
    []
  end

  # The adopt-or-POST decision rests on a list read during this run: a list
  # read before the run's plan arrived (or with no plan at all) is read
  # again first. Every write of this provider updates the list in place or
  # drops it, so an object created earlier in the run is always seen.
  def create(context, name, should)
    refuse_conflicting_delete(should)
    invalidate_objects unless objects_current_for_run?
    existing = lookup_object(context, name)
    if existing.nil?
      unless creatable?
        raise Puppet::ResourceError, "#{type_name}: no GLPI object matches '#{resource_key(name)}' and this type does not create objects"
      end
      trashed = restore_trashed? ? restorable_trashed(name) : nil
      if trashed
        warn_unmarked_trashed(context, name, trashed)
        return restore(context, trashed, should)
      end

      warn_trashed(context, name)
      body = mark(resource_to_api(context, should, nil), nil)
      created = transport(context).post(context, create_path(should), body)
      path = created_item_path(should, created)
      if path.nil?
        raise Puppet::ResourceError,
              "#{type_name}: GLPI answered the creation of '#{PuppetX::Glpi::Names.normalize(resource_key(name))}' with no id; " \
              'whether it exists is unknown, so the next run may create it again'
      end
      confirm_created(context, name, path)
    elsif adoption_policy == :skip_unmarked && !marked?(existing)
      warn_unmarked(context, name, 'left unchanged')
    else
      context.info("#{type_name}: adopting existing GLPI object '#{resource_key(name)}' (id #{existing['id']})") unless marked?(existing)
      write(context, existing, should)
    end
  rescue StandardError
    drop_cached_lists(context) { existing ? item_path(existing) : create_path(should) }
    raise
  end

  def update(context, name, should)
    refuse_conflicting_delete(should)
    existing = lookup_object(context, name)
    raise Puppet::ResourceError, "#{type_name}: GLPI object '#{resource_key(name)}' disappeared during the run" if existing.nil?
    return warn_unmarked(context, name, 'left unchanged') if adoption_policy == :skip_unmarked && !marked?(existing)

    write(context, existing, should)
  rescue StandardError
    drop_cached_lists(context) { existing && item_path(existing) }
    raise
  end

  def delete(context, name)
    existing = lookup_object(context, name)
    return if existing.nil?
    return warn_unmarked(context, name, 'not deleted') unless marked?(existing)

    if declared_elsewhere?(name)
      context.warning("#{type_name}: GLPI object '#{resource_key(name)}' is the object declared as another title " \
                      'differing only in case; not deleted')
      return
    end

    path = item_path(existing)
    transport(context).delete(context, path)
    scope = guard_scope(existing)
    @deletions_done = deletions_done.merge(scope => deletions_done(scope) + 1)
    forget_cached_object(context, path)
  rescue StandardError
    drop_cached_lists(context) { path }
    raise
  end

  def set(context, changes)
    changes = refresh_changes(context, changes) if @transport_config_missing
    take_guard_baseline(context) unless adoption_policy == :match_only
    guard_deletions(context, changes)
    super
  end

  # Called by the type hook with the catalog's titles of this type whose
  # target is absent, and (+declared+) those whose target is present. A new plan id (catalog) starts a new run's count.
  def plan_deletions(plan_id, titles, declared = [])
    return if plan_id == @plan_id

    @plan_id = plan_id
    @run_started_at = Time.now
    @planned_deletions = Array(titles)
    @declared_keys = Array(declared).map { |title| natural_key(resource_key(title)) }
    @deletions_done = {}
    @guard_baseline = nil
    reset_run_warnings
  end

  # The once-per-run warning memory is keyed on read timestamps; a new run
  # starts it empty, so it neither suppresses the next run's warnings nor
  # grows for the life of the process.
  def reset_run_warnings
    [:@twins_noted, :@warned, :@warned_links, :@warned_fields, :@warned_missing, :@warned_entities, :@warned_members].each do |ivar|
      set = instance_variable_get(ivar)
      set.clear if set.respond_to?(:clear)
    end
  end

  # Entity id a target state asks for, for the types that leave an
  # unresolvable entity (or entity tag) to the unresolved setting: 'warn'
  # warns once per run and returns nil (the stored entity stays alone),
  # 'fail' fails the resource through raise_unresolved (once per resource
  # and run; later calls return nil).
  def resolvable_entity(context, should)
    wanted_entity(context, should)
  rescue Puppet::ResourceError => error
    if fail_unresolved?
      raise_unresolved(should, [error.message])
    else
      @warned_entities ||= Set.new
      context.warning(error.message) if @warned_entities.add?(error.message)
    end
    nil
  end

  # Types declare the custom_insync feature; nil keeps the default compare.
  # rubocop:disable Style/ReturnNilInPredicateMethodDefinition -- nil is the Resource API's "use the default"
  def insync?(context, name, attribute_name, is_hash, should_hash)
    return delete_properties_insync?(context, name, is_hash, should_hash) if attribute_name == :delete_properties

    existing = observed(name, context)
    return nil if existing.nil?

    if should_hash[:ensure].to_s == 'absent'
      return nil if marked?(existing) || attribute_name != :ensure

      warn_unmarked(context, name, 'not deleted')
      return true
    end
    return nil unless adoption_policy == :skip_unmarked && !marked?(existing)

    warn_unmarked(context, name, 'left unchanged')
    true
  end
  # rubocop:enable Style/ReturnNilInPredicateMethodDefinition

  # The 'comment' to write for a type with an optional comment attribute
  # (marker excluded; mark adds it): '' for a new object without one; the
  # stored text when unset and the object is not marked yet (adoption keeps
  # it); nil (send nothing) when unset on a marked object or unchanged.
  def comment_body(should, existing)
    wanted = wanted_value(should, :comment, existing)
    stored = existing && strip_marker(existing['comment'])
    if wanted.nil?
      return '' if existing.nil?

      return marked?(existing) ? nil : stored
    end
    return nil if existing && marked?(existing) && PuppetX::Glpi::Names.same?(stored, wanted)

    wanted.to_s
  end

  # Clearing optional properties: `delete_properties` names attributes to
  # clear on update. API v2 has no delete parameter, so a listed attribute is
  # written as the empty value, which is how each provider already clears it
  # (the marker stays: mark puts it back into an emptied comment). A type
  # offers only the attributes its provider can clear. should itself is left
  # alone: raise_unresolved identifies a resource by that very hash.

  # Whether +should+ asks to clear +attribute+.
  def deleting?(should, attribute)
    deleted_properties(should).include?(attribute)
  end

  # The value to write for +attribute+: '' when listed in delete_properties
  # on an existing object (create has nothing to clear), else the declared one.
  def wanted_value(should, attribute, existing)
    (existing && deleting?(should, attribute)) ? '' : should[attribute]
  end

  # ---- coercion helpers for subclasses ------------------------------------

  def to_bool(value)
    return true if [true, 1, '1', 'true'].include?(value)
    return false if [false, 0, '0', 'false', nil, ''].include?(value)

    value
  end

  # 'YYYY-MM-DD' of a GLPI date or datetime ('2027-02-28 00:00:00'); ''
  # for none (nil, '', a zero date).
  def to_date(value)
    date = value.to_s[%r{\A\d{4}-\d{2}-\d{2}}]
    (date.nil? || date.start_with?('0000')) ? '' : date
  end

  def to_int(value)
    return value if value.is_a?(Integer)
    return Integer(value, 10) if value.is_a?(String) && value.match?(%r{\A-?\d+\z})

    value
  end

  private

  def deleted_properties(should)
    Array(should[:delete_properties]).map(&:to_sym)
  end

  # A failure in insync? only fails that property: another changed property
  # still reaches create or update, so both refuse before anything is written.
  def refuse_conflicting_delete(should)
    declared = should.compact
    conflicting = deleted_properties(should).select { |attribute| declared.key?(attribute) }
    return if conflicting.empty?

    raise Puppet::ResourceError, "#{type_name}: cannot set and delete the same properties: #{conflicting.join(', ')}"
  end

  # get() never reports delete_properties, so it is in sync once every listed
  # attribute reads back empty; the clearing update is sent only until then,
  # and the resource converges. Declaring a value for an attribute that is
  # also listed could never converge, so it fails. An object this type must
  # not write stays in sync, as every other attribute does (see insync?).
  def delete_properties_insync?(context, name, current, desired)
    refuse_conflicting_delete(desired)
    requested = deleted_properties(desired)
    return true if desired[:ensure].to_s == 'absent'

    existing = observed(name, context)
    if existing && adoption_policy == :skip_unmarked && !marked?(existing)
      warn_unmarked(context, name, 'left unchanged')
      return true
    end
    requested.all? { |attribute| current[attribute].to_s.empty? }
  end

  def read_config_or_empty
    self.class.read_transport_config
  rescue TransportConfigMissing
    {}
  end

  # Changes whenever the file does: a rewrite inside the mtime resolution
  # with the same size (a rotated secret of the same length) still counts.
  def config_signature
    path = self.class.config_path
    stat = File.stat(path)
    [stat.mtime.to_f, stat.size, Digest::SHA256.file(path).hexdigest]
  rescue Errno::ENOENT, Errno::ENOTDIR
    nil
  end

  # A purge-generated absent title that differs only in case from a
  # declared (present) one names the declared object: never deleted.
  def declared_elsewhere?(name)
    Array(@declared_keys).include?(natural_key(resource_key(name)))
  end

  # Deletions done this run: of +scope+, or (no scope) the hash scope => count.
  def deletions_done(scope = nil)
    done = @deletions_done || {}
    scope.nil? ? done : done.fetch(scope, 0)
  end

  def list_resources(context, all)
    candidates = (adoption_policy == :match_only) ? all : all.select { |object| marked?(object) }
    groups = candidates.group_by { |object| natural_key(object_key(object)) }
    groups.filter_map do |_key, group|
      if group.size > 1
        context.warning("#{type_name}: #{group.size} GLPI objects share the key '#{PuppetX::Glpi::Names.normalize(object_key(group.first))}' " \
                        "(ids #{group.map { |object| object['id'] }.join(', ')}); skipped")
        next
      end
      api_to_resource(context, group.first).merge(ensure: 'present')
    end
  end

  def requested_resources(context, all, names)
    names.filter_map do |name|
      existing = find_unique(all, resource_key(name), context)
      next if existing.nil?
      next if adoption_policy == :adopt && !marked?(existing)

      resource = api_to_resource(context, existing).merge(ensure: 'present')
      name.is_a?(Hash) ? resource.merge(name) : resource.merge(context.type.namevars.first => name)
    end
  end

  def observed(name, context = nil)
    return nil if @objects.nil?

    find_unique(@objects, resource_key(name), context)
  rescue Puppet::ResourceError
    nil
  end

  # An empty body (only follow-up writes differ, e.g. links) sends nothing.
  def write(context, existing, should)
    body = resource_to_api(context, should, existing)
    body = mark(body, existing) unless adoption_policy == :match_only
    return if body.empty?

    path = item_path(existing)
    transport(context).patch(context, path, body)
    refresh_cached_object(context, path, existing)
  end

  # Brings the marked trashed object back (PATCH is_deleted false) together
  # with the normal write body, marker included, and puts it into the cached
  # list as a live object.
  def restore(context, trashed, should)
    context.info("#{type_name}: restoring trashed GLPI object '#{resource_key(should[:name] || should)}' (id #{trashed['id']})")
    body = mark(resource_to_api(context, should, trashed), trashed).merge('is_deleted' => false)
    path = item_path(trashed)
    transport(context).patch(context, path, body)
    @trashed_objects = Array(@trashed_objects).reject { |object| object['id'].to_s == trashed['id'].to_s }
    refresh_cached_object(context, path, trashed)
  end

  def objects_cached?
    !@objects.nil? && Time.now - @objects_read_at <= CACHE_TTL
  end

  # Read during this run: after the plan of the run arrived (the type hook
  # hands it over before the first flush). Without a plan, never.
  def objects_current_for_run?
    objects_cached? && !@run_started_at.nil? && @objects_read_at >= @run_started_at
  end

  # Item path of the object a POST created, nil when the response carries
  # no id.
  def created_item_path(should, response)
    id = response.is_a?(Hash) ? to_int(response['id']) : nil
    id.is_a?(Integer) ? "#{create_path(should)}/#{id}" : nil
  end

  # After a POST: the new object must be readable at +path+. A list that
  # cannot see it (no right on its entity, an endpoint that hides it) would
  # make every later run create it again, so the resource fails instead,
  # with the object left in GLPI for a human to look at.
  def confirm_created(context, name, path)
    fresh = read_created(context, name, path)
    unless fresh.is_a?(Hash) && fresh['id'].to_s == split_item_path(path)&.last
      drop_cached_lists(context) { path }
      raise_unconfirmed(name, path, 'no such object returned')
    end
    remember_written(context, path, fresh, nil)
  end

  def read_created(context, name, path)
    transport(context).get(context, path)
  rescue StandardError => error
    drop_cached_lists(context) { path }
    raise_unconfirmed(name, path, error.message)
  end

  def raise_unconfirmed(name, path, reason)
    raise Puppet::ResourceError,
          "#{type_name}: created '#{PuppetX::Glpi::Names.normalize(resource_key(name))}' at #{path}, but it cannot be read back " \
          "(#{reason}); the next run would not find it and create it again"
  end

  # After a write: reads the object at +path+ again and replaces it in the
  # cached list (entries whose item_path is +path+; matched by id, never by
  # natural key), or adds it. The shared list of the same collection, if
  # cached, gets the raw object too. Falls back to dropping the list when
  # the re-read fails or misses a field the cached entry had. Nothing is
  # read when nothing is cached.
  def refresh_cached_object(context, path, previous = nil)
    list_path, id = split_item_path(path)
    shared = list_path && shared_list_cached?(context, list_path)
    return invalidate_objects unless list_path
    return unless objects_cached? || shared

    fresh = transport(context).get(context, path)
    return refresh_failed(context, path, list_path, 'no object returned') unless fresh.is_a?(Hash) && fresh['id'].to_s == id

    remember_written(context, path, fresh, previous)
  rescue StandardError => error
    refresh_failed(context, path, list_path, error.message)
  end

  # Puts +fresh+ (read again at +path+ after a write) into the cached list
  # and the shared list of its collection, if either is cached; drops them
  # when it misses a field the cached entry had.
  def remember_written(context, path, fresh, previous)
    list_path, id = split_item_path(path)
    return invalidate_objects unless list_path
    return refresh_failed(context, path, list_path, 'incomplete object') unless cacheable?(fresh, path) && covers?(fresh, previous)

    update_shared_list(context, list_path, id, fresh) if shared_list_cached?(context, list_path)
    return unless objects_cached?

    entry = trashed?(fresh) ? nil : cache_object(context, fresh, path)
    kept = @objects.reject { |object| item_path(object) == path }
    @objects = entry ? kept + [entry] : kept
  end

  # After a delete: the object leaves the cached list and the shared list.
  def forget_cached_object(context, path)
    list_path, id = split_item_path(path)
    return invalidate_objects unless list_path

    @objects = @objects.reject { |object| item_path(object) == path } if objects_cached?
    update_shared_list(context, list_path, id, nil)
  end

  # After a failed or unconfirmed write: the type's list and the shared list
  # of the collection the block's path (item or collection path; nil = the
  # type's collection) lives in, so no other provider resolves against a
  # list that may miss the write. Never raises: it runs in rescue clauses.
  def drop_cached_lists(context)
    invalidate_objects
    path = yield if block_given?
    list_path = path && (split_item_path(path)&.first || path)
    drop_shared_list(context, list_path || collection_path)
  rescue StandardError => error
    context.debug("#{type_name}: dropping the shared list failed (#{error.message})")
  end

  def refresh_failed(context, path, list_path, reason)
    context.debug("#{type_name}: re-reading #{path} after a write failed (#{reason}); the list is read again")
    invalidate_objects
    drop_shared_list(context, list_path) if list_path
  end

  # [collection path, id] of an item path ending in a numeric id.
  def split_item_path(path)
    match = %r{\A(.+)/(\d+)\z}.match(path.to_s)
    match && [match[1], match[2]]
  end

  # Every field of the cached entry (derived '_' fields aside) is in +fresh+.
  def covers?(fresh, previous)
    return true if previous.nil?

    (previous.keys.reject { |key| key.to_s.start_with?('_') } - fresh.keys).empty?
  end

  def shared_list_cached?(context, path)
    cached = self.class.shared_lists_for(transport(context))[path]
    !cached.nil? && Time.now - cached[0] <= CACHE_TTL
  end

  # A body carrying 'comment' is a comment-attribute type: marker first.
  # Otherwise keep the existing comment and append the marker if missing.
  def mark(body, existing)
    return body if adoption_policy == :match_only

    if body.key?('comment')
      body.merge('comment' => with_marker(body['comment']))
    elsif existing && managed?(existing['comment'])
      body
    else
      body.merge('comment' => append_marker(existing && existing['comment']))
    end
  end

  # find_unique chose +chosen+ (marked) over the unmarked same-key +twins+:
  # an info, once per key and run (a new plan starts a new run).
  def note_unmarked_twins(context, key, chosen, twins)
    return if context.nil?

    @twins_noted ||= Set.new
    note = [@plan_id, natural_key(key), twins.map { |object| object['id'].to_s }.sort]
    return if @twins_noted.include?(note)

    @twins_noted << note
    context.info("#{type_name}: key '#{PuppetX::Glpi::Names.normalize(key)}': the marked GLPI object (id #{chosen['id']}) is managed; " \
                 "unmarked objects of the same key are left alone (id #{twins.map { |object| object['id'] }.join(', ')})")
  end

  def warn_unmarked(context, name, outcome)
    @warned ||= Set.new
    key = [resource_key(name), outcome, @objects_read_at]
    return if @warned.include?(key)

    @warned << key
    reason = (adoption_policy == :match_only) ? 'this type never deletes' : "it does not carry the marker #{marker_for}"
    context.warning("#{type_name}: GLPI object '#{resource_key(name)}' #{outcome}: #{reason}")
  end

  # The managed count per scope the guard measures against, taken by the
  # first set() of a run (plan) before any write of that run, whatever the
  # batch holds: creates or adoptions earlier in the run must not raise the
  # limit. A scope with no marked object allows one deletion.
  def take_guard_baseline(context)
    return if @guard_baseline

    counts = Hash.new(0)
    objects(context).each { |object| counts[guard_scope(object)] += 1 if marked?(object) }
    @guard_baseline = counts.transform_values { |managed| { managed: managed, allowed: guard_allowance(managed) } }
  end

  # max(1, floor(fraction x managed)), capped at purge_max_per_run (if set).
  def guard_allowance(managed)
    allowed = [1, (module_settings[:purge_max_fraction] * managed).floor].max
    cap = module_settings[:purge_max_per_run]
    (cap.nil? || cap <= 0) ? allowed : [allowed, cap].min
  end

  def guard_baseline_for(scope)
    @guard_baseline.fetch(scope) { { managed: 0, allowed: 1 } }
  end

  def guard_limits_text
    cap = module_settings[:purge_max_per_run]
    text = "purge_max_fraction #{module_settings[:purge_max_fraction]}"
    (cap.nil? || cap <= 0) ? text : "#{text}, purge_max_per_run #{cap}"
  end

  # At most max(1, floor(fraction x marked objects)) deletions per scope
  # (default: per type) and run, and never more than purge_max_per_run
  # (default 3; 0 or null in the transport file: no cap), counting deletions already done plus the
  # pending marked targets of the catalog's plan and this batch. A pending
  # title is matched to the marked live objects by natural key alone and
  # counts in the scope of the object it names (not in a scope derived from
  # the title). Exceeding the allowance in any scope the batch touches fails
  # the whole batch before anything is deleted. The Resource API calls set
  # once per resource, so in a Puppet run that refuses the deletions of the
  # scope over its allowance while other scopes proceed. Fails closed: a
  # deletion without a plan for the run (type did not call
  # GlpiTransportAutorequire.register) is refused.
  def guard_deletions(context, changes)
    batch = changes.select { |_name, change| change[:should] && change[:should][:ensure].to_s == 'absent' }.keys
    return if batch.empty? || adoption_policy == :match_only

    if @plan_id.nil?
      raise Puppet::ResourceError,
            "#{type_name}: refusing to delete: no deletion plan for this run (the type did not register " \
            'the deletion-plan hook, Puppet::Type::GlpiTransportAutorequire.register)'
    end

    live    = objects(context).select { |object| marked?(object) }.group_by { |object| natural_key(object_key(object)) }
    titles  = (@planned_deletions + batch).reject { |name| declared_elsewhere?(name) }
    targets = titles.flat_map { |name| live.fetch(natural_key(resource_key(name)), []) }.uniq { |object| item_path(object) }
    pending = targets.map { |object| guard_scope(object) }.tally
    scopes  = batch.map do |name|
      named = live.fetch(natural_key(resource_key(name)), [])
      named.empty? ? guard_scope(name) : guard_scope(named.first)
    end
    scopes.uniq.each do |scope|
      total   = deletions_done(scope) + pending.fetch(scope, 0)
      limits  = guard_baseline_for(scope)
      next if total <= limits[:allowed]

      label = scope.to_s.empty? ? type_name : "#{type_name} (#{scope})"
      raise Puppet::ResourceError,
            "#{label}: refusing to delete #{total} of #{limits[:managed]} managed GLPI objects " \
            "(#{guard_limits_text}: the guard allows #{limits[:allowed]}); " \
            "nothing of this #{scope.to_s.empty? ? 'type' : 'scope'} is deleted"
    end
  end

  def refresh_changes(context, changes)
    @transport = nil
    @transport_signature = nil
    @transport_config_missing = false
    invalidate_objects
    changes.to_h do |name, change|
      current = get(context, [name]).first
      [name, change.merge(is: current || absent_state(context, name))]
    end
  end

  def absent_state(context, name)
    base = name.is_a?(Hash) ? name.dup : { context.type.namevars.first => name }
    base.merge(ensure: 'absent')
  end
end
