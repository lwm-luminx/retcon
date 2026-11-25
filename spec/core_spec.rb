# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Versioned saves' do
  let(:alice) { Retcon::Actor.named('user', 'alice') }
  let(:bob) { Retcon::Actor.named('user', 'bob') }

  it 'writes field versions with the actor in the same transaction as the live row' do
    venue = Retcon.as(alice) { Venue.create!(name: 'The Eagle', phone: '555-0100', audience: 'hotmess') }
    changeset = Retcon::Changeset.last
    expect(changeset.author).to eq(alice)
    expect(changeset.scope).to eq('hotmess')
    expect(venue.retcon_versions.map { |v| [v.op, v.field] }).to include(['create', nil], %w[set name], %w[set phone])
    expect(venue.retcon_seq).to eq(changeset.applied_seq)
    expect(venue.retcon_drifted?).to be(false)
  end

  it 'versions only changed tracked fields, and not timestamps or counter caches' do
    venue = Retcon.as(alice) { Venue.create!(name: 'A') }
    Retcon.as(bob) { venue.update!(name: 'B', events_count: 3) }
    last = Retcon::Changeset.order(:id).last
    rows = venue.retcon_versions.where(changeset_id: last.id)
    expect(rows.map(&:field)).to eq(['name'])
    expect(Venue.retcon_config.tracked_fields).not_to include('created_at', 'updated_at', 'events_count', 'id')
  end

  it 'groups several saves into one changeset' do
    changeset = Retcon.changeset(actor: alice, message: 'Set up') do
      venue = Venue.create!(name: 'Pony')
      Event.create!(venue:, name: 'Bingo')
    end
    expect(changeset.records.map(&:first)).to contain_exactly(Venue, Event)
    expect(changeset.message).to eq('Set up')
  end

  it 'keeps Active Record return values for save and destroy' do
    venue = Venue.new(name: 'A')
    expect(Retcon.as(alice) { venue.save }).to be(true)
    expect(Retcon.as(alice) { venue.save! }).to be(true)
    expect(Retcon.as(alice) { Venue.new.save }).to be(false)
    expect(Retcon.as(alice) { venue.destroy }).to eq(venue)
  end

  it 'leaves no changeset when nothing changes' do
    venue = Retcon.as(alice) { Venue.create!(name: 'A') }
    expect { Retcon.as(bob) { venue.save! } }.not_to change(Retcon::Changeset, :count)
  end

  it 'attributes saves with no actor to the system actor, or refuses them' do
    Venue.create!(name: 'Quiet')
    expect(Retcon::Changeset.last.author.label).to eq('unattributed')
    Retcon.allow_unattributed = false
    expect { Venue.create!(name: 'Loud') }.to raise_error(Retcon::Error, /no actor/)
  ensure
    Retcon.allow_unattributed = true
  end

  it 'reports heads with who set each field last' do
    venue = Retcon.as(alice) { Venue.create!(name: 'A', phone: '1') }
    Retcon.as(bob) { venue.update!(phone: '2') }
    heads = venue.retcon_heads
    expect(heads['phone'].value).to eq('2')
    expect(Retcon::Changeset.joins('JOIN retcon_venues v ON v.changeset_id = retcon_changesets.id')
                            .find_by('v.id' => heads['phone'].row_id).author).to eq(bob)
  end

  it 'keeps values of every type' do
    venue = Retcon.as(alice) do
      Venue.create!(name: 'Types', tags: %w[bar dance], hours: { 'tue' => '4pm' }, opened_on: Date.new(2020, 6, 1))
    end
    state = Venue.retcon_state(venue.id)['attributes']
    expect(state).to include('tags' => %w[bar dance], 'hours' => { 'tue' => '4pm' }, 'opened_on' => '2020-06-01')
    expect(Retcon.verify(Venue)).to be_empty
  end

  it 'records agents acting for someone' do
    agent = Retcon::Actor.resolve('mcp agent', on_behalf_of: alice)
    expect(agent.kind).to eq('agent')
    expect(agent.label).to eq('mcp agent for alice')
    Retcon.as(agent) { Venue.create!(name: 'By agent') }
    expect(Retcon::Changeset.last.author.on_behalf_of).to eq(alice)
  end

  describe 'deletes' do
    it 'tombstones in history and removes the live row' do
      venue = Retcon.as(alice) { Venue.create!(name: 'Gone') }
      Retcon.as(bob) { venue.destroy! }
      expect(Venue.unscoped.exists?(venue.id)).to be(false)
      expect(Venue.retcon_state(venue.id)['exists']).to be(false)
      tomb = venue.retcon_versions.find_by(op: 'tombstone')
      expect(tomb.value).to include('name' => 'Gone')
    end

    it 'puts dependent destroys in the same changeset' do
      venue = Retcon.as(alice) { Venue.create!(name: 'Parent') }
      event = Retcon.as(alice) { Event.create!(venue:, name: 'Child') }
      Retcon.as(bob) { venue.destroy! }
      changeset = Retcon::Changeset.order(:id).last
      expect(changeset.records).to contain_exactly([Venue, venue.id], [Event, event.id])
    end

    it 'revives a record with its id and history' do
      venue = Retcon.as(alice) { Venue.create!(name: 'Phoenix', phone: '1') }
      Retcon.as(alice) { venue.update!(phone: '2') }
      Retcon.as(bob) { venue.destroy! }
      revived = Venue.retcon_revive!(venue.id, actor: alice)
      expect(revived.attributes.slice('id', 'name',
                                      'phone')).to eq('id' => venue.id, 'name' => 'Phoenix', 'phone' => '2')
      expect(Venue.retcon_state(venue.id)['exists']).to be(true)
      expect(revived.retcon_versions.map(&:op)).to include('tombstone', 'revive')
    end
  end

  describe 'rebuild' do
    it 'rewrites a live row from history' do
      venue = Retcon.as(alice) { Venue.create!(name: 'Right', phone: '1') }
      Retcon.bypass { venue.update_columns(name: 'Wrong') }
      expect(Retcon.verify(Venue).map { |m| m[1] }).to eq(['name'])
      Venue.retcon_rebuild!(venue.id)
      expect(venue.reload.name).to eq('Right')
    end

    it 'reinserts and deletes rows to match history' do
      venue = Retcon.as(alice) { Venue.create!(name: 'Here') }
      Retcon.bypass { Venue.where(id: venue.id).delete_all }
      Venue.retcon_rebuild!(venue.id)
      expect(Venue.find(venue.id).name).to eq('Here')
    end
  end
end
