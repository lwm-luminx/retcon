# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Edges' do
  let(:alice) { Retcon::Actor.named('user', 'alice') }
  let(:venue) { Retcon.as(alice) { Venue.create!(name: 'The Eagle') } }
  let(:event) { Retcon.as(alice) { Event.create!(name: 'Drag Bingo', venue:) } }

  it 'creates an edge once and updates it in place when linked again' do
    link = Retcon.as(alice) { Link.link!(event, :held_at, venue, role: 'host') }
    again = Retcon.as(alice) { Link.link!(event, :held_at, venue, role: 'sponsor') }
    expect(again.id).to eq(link.id)
    expect(Link.count).to eq(1)
    expect(again.reload.role).to eq('sponsor')
    expect(link.retcon_versions.where(field: 'role').count).to eq(2)
  end

  it 'does not write a changeset when linking an unchanged edge' do
    Retcon.as(alice) { Link.link!(event, :held_at, venue, role: 'host') }
    expect { Retcon.as(alice) { Link.link!(event, :held_at, venue, role: 'host') } }
      .not_to change(Retcon::Changeset, :count)
  end

  it 'tombstones on unlink, so the live table holds only live edges' do
    link = Retcon.as(alice) { Link.link!(event, :held_at, venue) }
    removed = Retcon.as(alice) { Link.unlink!(event, :held_at, venue) }
    expect(removed.id).to eq(link.id)
    expect(Link.exists?(link.id)).to be(false)
    expect(Link.retcon_history.alive?(link.id)).to be(false)
    expect(Retcon.as(alice) { Link.unlink!(event, :held_at, venue) }).to be_nil
  end

  it 'revives the same row, with its id and history, when the triple is linked again' do
    link = Retcon.as(alice) { Link.link!(event, :held_at, venue, role: 'host') }
    Retcon.as(alice) { Link.unlink!(event, :held_at, venue) }
    revived = Retcon.as(alice) { Link.link!(event, :held_at, venue, role: 'cohost') }
    expect(revived.id).to eq(link.id)
    expect(revived.reload.role).to eq('cohost')
    expect(revived.retcon_versions.map(&:op)).to include('create', 'tombstone', 'revive')
    expect(Link.retcon_history.alive?(link.id)).to be(true)
  end

  it 'keeps different predicates as different edges' do
    a = Retcon.as(alice) { Link.link!(event, :held_at, venue) }
    b = Retcon.as(alice) { Link.link!(event, :promoted_by, venue) }
    expect(a.id).not_to eq(b.id)
  end

  it 'builds identities with polymorphic ends cast to the column types' do
    identity = Link.retcon_identity(event, :held_at, venue)
    expect(identity).to eq('subject_type' => 'Event', 'subject_id' => event.id.to_s, 'predicate' => 'held_at',
                           'object_type' => 'Venue', 'object_id' => venue.id)
  end
end
