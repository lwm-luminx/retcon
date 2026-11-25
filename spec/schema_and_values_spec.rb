# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Schema versions and values' do
  let(:alice) { Retcon::Actor.named('user', 'alice') }

  describe 'upcasters' do
    let(:config) do
      Retcon::Config.new(Venue).tap do |c|
        c.schema_version 3
        c.rename_field :telephone, :phone, before: 2
        c.upcast(before: 3) { |field, value| field == 'hours_text' ? [] : [[field, value]] }
      end
    end

    it 'renames fields written under older versions' do
      expect(config.upcast_value('telephone', '555', 1)).to eq([%w[phone 555]])
      expect(config.upcast_value('telephone', '555', 2)).to eq([%w[telephone 555]])
    end

    it 'drops fields an upcaster returns nothing for' do
      expect(config.upcast_value('hours_text', '4pm', 1)).to eq([])
    end

    it 'reads old history rows under the current schema' do
      venue = Retcon.as(alice) { Venue.create!(name: 'Pony', phone: '555-0100') }
      Venue.retcon_history.where(record_id: venue.id, field: 'phone').update_all(field: 'telephone', schema_version: 1)
      allow(Venue).to receive(:retcon_config).and_return(config)
      expect(Venue.retcon_history.heads(venue.id)['phone'].value).to eq('555-0100')
      expect(Venue.retcon_history.heads(venue.id)).not_to have_key('telephone')
    end
  end

  describe 'config' do
    it 'refuses unknown merge strategies' do
      expect { Retcon::Config.new(Venue).merge(:tags, :sum) }.to raise_error(ArgumentError)
    end

    it 'tracks only the fields named with only, minus ignored ones' do
      config = Retcon::Config.new(Venue).tap do |c|
        c.only :name, :phone
        c.ignore :phone
      end
      expect(config.tracked_fields).to eq(['name'])
    end
  end

  describe Retcon::Value do
    it 'keeps decimals as strings and hashes with string keys' do
      expect(described_class.dump(BigDecimal('1.50'))).to eq('1.5')
      expect(described_class.dump({ a: { b: [1, :c] } })).to eq('a' => { 'b' => [1, 'c'] })
    end

    it 'compares values canonically, ignoring hash key order' do
      expect(described_class.same?({ 'a' => 1, 'b' => 2 }, { b: 2, a: 1 })).to be(true)
      expect(described_class.same?([1, 2], [2, 1])).to be(false)
    end

    it 'commits with a salt, so equal values give different commitments' do
      expect(described_class.commit('s1', 'x')).not_to eq(described_class.commit('s2', 'x'))
      expect(described_class.commit('s1', 'x')).to match(/\A\h{64}\z/)
    end

    it 'round-trips arrays, jsonb and dates through history' do
      venue = Retcon.as(alice) do
        Venue.create!(name: 'Eagle', tags: %w[leather bar], hours: { 'tue' => '4pm' }, opened_on: Date.new(1970, 6, 1))
      end
      state = Venue.retcon_state(venue.id)['attributes']
      expect(state).to include('tags' => %w[leather bar], 'hours' => { 'tue' => '4pm' }, 'opened_on' => '1970-06-01')
      expect(Retcon.verify(Venue)).to be_empty
    end
  end

  it 'verifies every set row against its commitment' do
    venue = Retcon.as(alice) { Venue.create!(name: 'Pony') }
    expect(venue.retcon_versions.all?(&:verified?)).to be(true)
    row = venue.retcon_versions.find_by(field: 'name')
    row.update_columns(value: { 'v' => 'Tampered' })
    expect(row.reload.verified?).to be(false)
  end
end
