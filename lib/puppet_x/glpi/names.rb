# frozen_string_literal: true

require 'cgi'

# @api private
module PuppetX; end
# @api private
module PuppetX::Glpi; end

# Natural-key normalization for GLPI objects.
#
# GLPI stores and returns some names HTML-entity-encoded (an ampersand comes
# back as +&#38;+), so a byte-wise comparison against the manifest never
# matches and the provider would rewrite the object on every run. Every
# natural-key comparison in this module goes through {normalize}.
module PuppetX::Glpi::Names
  # Decodes HTML entities once (decimal and hexadecimal character references,
  # and the named entities CGI.unescapeHTML knows: amp, lt, gt, quot, apos),
  # composes the result to Unicode NFC and strips surrounding whitespace.
  # Input in another encoding is read as UTF-8. +nil+ becomes ''.
  def self.normalize(name)
    return '' if name.nil?

    text = name.to_s
    text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
    decoded = CGI.unescapeHTML(text)
    decoded = decoded.unicode_normalize(:nfc) if decoded.valid_encoding?
    decoded.strip
  end

  # Whether two names are the same text after normalization (case matters;
  # used for comments and other plain properties).
  def self.same?(left, right)
    normalize(left) == normalize(right)
  end

  # The natural-key form of +name+: normalized and, unless +fold+ is false,
  # case-folded. GLPI compares names case-insensitively (its default database
  # collation) and lets users change the case freely, so objects are matched
  # by this form.
  def self.key(name, fold: true)
    text = normalize(name)
    fold ? text.downcase(:fold) : text
  end
end
