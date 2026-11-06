# frozen_string_literal: true

require 'spec_helper'

describe 'glpi_confdir fact' do
  before(:each) { Facter.clear }
  after(:each) { Facter.clear }

  it "is the agent's own Puppet confdir, where the providers look" do
    expect(Facter.fact(:glpi_confdir).value).to eq(Puppet.settings[:confdir])
  end
end
