# frozen_string_literal: true

require 'set'
require_relative 'names'

# @api private
module PuppetX; end
# @api private
module PuppetX::Glpi; end

# Links between the objects of a provider ("owners") and other GLPI objects
# ("peers") that REST cannot list across the collection: read in one paged,
# filtered GraphQL query per CACHE_TTL (shared by every resource of the
# provider), written and removed over REST.
#
# Mixed into a subclass of Puppet::Provider::GlpiBaseProvider (uses its
# +transport+, +to_int+, +fail_unresolved?+, +raise_unresolved+). The
# provider supplies +link_spec+, a Hash:
#
# * +:type+, +:selection+, +:filter+: the GraphQL query (e.g.
#   +'Certificate_Item'+, +'id items_id certificate { id }'+,
#   +'itemtype==Computer'+); only rows the filter selects are ever seen;
# * +:owner+, +:peer+: lambdas row => Integer id;
# * +:add+: lambda (owner id, peer id) => [POST path, body];
# * +:remove+: lambda (owner id, peer id, link id) => DELETE path.
#
# GLPI does not keep a link pair unique: duplicate rows of one pair are
# read as one link. A pair that is wanted keeps all its rows; a pair that
# is removed loses all of them.
module PuppetX::Glpi::ItemLinks
  # Every link row the spec selects, as { 'id', 'owner', 'peer' } (Integer
  # ids). A selected row without an id, owner or peer raises: it must never
  # read as "no link" (that would re-create it every run and keep stale ones).
  def item_links(context)
    if @item_links.nil? || Time.now - @item_links_read_at > self.class::CACHE_TTL
      spec = link_spec
      rows = Array(transport(context).graphql_all(context, spec[:type], spec[:selection], filter: spec[:filter]))
      @item_links = rows.filter_map { |row| link_row(spec, row) }
      @item_links_read_at = Time.now
    end
    @item_links
  end

  def drop_item_links
    @item_links = nil
  end

  # The link rows of owner +owner_id+.
  def links_of(context, owner_id)
    item_links(context).select { |link| link['owner'] == owner_id }
  end

  # Peer ids linked to +owner_id+, each once.
  def linked_peers(context, owner_id)
    links_of(context, owner_id).map { |link| link['peer'] }.uniq
  end

  # [peer ids to link, link rows to remove] for owner +owner_id+: +wanted+
  # peers without a link, and the rows of linked peers that are not wanted
  # and for which +removable+ (lambda peer id => Boolean) is true.
  def link_plan(context, owner_id, wanted, removable)
    current = links_of(context, owner_id)
    have = current.to_set { |link| link['peer'] }
    want = wanted.to_set
    adds = wanted.uniq.reject { |peer| have.include?(peer) }
    removes = current.reject { |link| want.include?(link['peer']) || !removable.call(link['peer']) }
    [adds, removes]
  end

  # Links +adds+ first, then removes +removes+; the cached rows follow each
  # write. A POST answered without a link id, or any failure, drops them
  # (the next use reads them whole).
  def write_links(context, owner, adds, removes)
    spec = link_spec
    adds.each do |peer|
      path, body = spec[:add].call(owner, peer)
      created = transport(context).post(context, path, body)
      link_id = created.is_a?(Hash) ? to_int(created['id']) : nil
      if link_id.is_a?(Integer)
        @item_links&.push('id' => link_id, 'owner' => owner, 'peer' => peer)
      else
        drop_item_links
      end
    end
    removes.each do |link|
      transport(context).delete(context, spec[:remove].call(owner, link['peer'], link['id']))
      @item_links&.reject! { |cached| cached['id'] == link['id'] }
    end
  rescue StandardError
    drop_item_links
    raise
  end

  # Declared link targets that match nothing (+messages+): a warning each,
  # once per resource and list read ('warn'), or one failure of the
  # resource ('fail'; not while +write_pending+, i.e. from an insync? that
  # leaves links for set to write: set fails after writing them).
  def report_unresolved_links(context, should, messages, write_pending: false)
    return if messages.empty?

    if fail_unresolved?
      raise_unresolved(should, messages) unless write_pending
      return
    end

    @warned_links ||= Set.new
    messages.each do |message|
      key = [message, @item_links_read_at]
      next if @warned_links.include?(key)

      @warned_links << key
      context.warning(message)
    end
  end

  private

  def link_row(spec, row)
    raise Puppet::ResourceError, "GraphQL link row #{row.inspect} is not an object" unless row.is_a?(Hash)

    id = to_int(row['id'])
    owner = spec[:owner].call(row)
    peer = spec[:peer].call(row)
    { 'id' => id, 'owner' => owner, 'peer' => peer }.each do |part, value|
      next if value.is_a?(Integer)

      raise Puppet::ResourceError, "link row #{row['id'] || row.inspect} has no #{(part == 'id') ? 'id' : "#{part} id"}; check the API user's rights"
    end

    { 'id' => id, 'owner' => owner, 'peer' => peer }
  end
end
