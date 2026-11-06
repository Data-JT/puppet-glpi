# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../../lib/puppet_x/glpi/names'

RSpec.describe PuppetX::Glpi::Names do
  describe '.normalize' do
    it 'decodes the numeric HTML entity GLPI returns for an ampersand' do
      expect(described_class.normalize('Customer A GmbH &#38; Co. KG')).to eq('Customer A GmbH & Co. KG')
    end

    it 'decodes named and hexadecimal entities' do
      expect(described_class.normalize('A &amp; B &lt;x&gt; &#x26; &quot;q&quot;')).to eq('A & B <x> & "q"')
    end

    it 'keeps umlauts unchanged' do
      expect(described_class.normalize('Ünïcödé')).to eq('Ünïcödé')
    end

    it 'composes decomposed umlauts (Unicode NFC)' do
      expect(described_class.normalize(['U', 0x308.chr(Encoding::UTF_8), 'nïcödé'].join)).to eq('Ünïcödé')
    end

    it 'reads binary-tagged UTF-8 input as UTF-8' do
      expect(described_class.normalize((+'A &#38; Ünïcödé').force_encoding(Encoding::BINARY))).to eq('A & Ünïcödé')
    end

    it 'strips surrounding whitespace' do
      expect(described_class.normalize("  Customer A \n")).to eq('Customer A')
    end

    it 'decodes only once (a literal &amp;#38; stays an entity text)' do
      expect(described_class.normalize('A &amp;#38; B')).to eq('A &#38; B')
    end

    it 'returns an empty string for nil and stringifies numbers' do
      expect(described_class.normalize(nil)).to eq('')
      expect(described_class.normalize(42)).to eq('42')
    end
  end

  describe '.same?' do
    it 'compares normalized names' do
      expect(described_class.same?('A &#38; B', ' A & B')).to be true
      expect(described_class.same?('A', 'B')).to be false
    end
  end

  describe '.same? with case' do
    it 'keeps case significant for plain text' do
      expect(described_class.same?('Foo', 'foo')).to be false
    end
  end

  describe '.key' do
    it 'normalizes and case-folds' do
      expect(described_class.key(' A &#38; b ')).to eq('a & b')
      expect(described_class.key('ΑΣ')).to eq(described_class.key('ας'))
    end

    it 'keeps the case when folding is off' do
      expect(described_class.key(' Foo ', fold: false)).to eq('Foo')
    end
  end
end
