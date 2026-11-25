# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Proposals' do
  let(:alice) { Retcon::Actor.named('user', 'alice') }
  let(:member) { Retcon::Actor.named('user', 'member') }
  let(:reviewer) { Retcon::Actor.named('user', 'reviewer') }
  let!(:venue) { Retcon.as(alice) { Venue.create!(name: 'Eagle', phone: '1') } }

  it 'records changes without touching live rows, then applies them' do
    proposal = Retcon.propose(actor: member, message: 'New phone') { |p| p.update(venue, phone: '2') }
    expect(proposal).to be_proposed
    expect(venue.reload.phone).to eq('1')
    expect(proposal.changes).to eq([Venue, venue.id] => { 'phone' => '2' })

    result = proposal.apply!(committer: reviewer)
    expect(result[:conflicts]).to be_empty
    expect(venue.reload.phone).to eq('2')
    expect(proposal.reload).to have_attributes(state: 'applied', author: member, committer: reviewer)
    expect(venue.retcon_heads['phone'].seq).to eq(proposal.applied_seq)
    expect(Retcon.verify(Venue)).to be_empty
  end

  it 'orders an applied proposal by when it was applied, not when it was opened' do
    proposal = Retcon.propose(actor: member) { |p| p.update(venue, name: 'Proposed') }
    Retcon.as(alice) { venue.update!(phone: '9') }
    proposal.apply!(committer: reviewer)
    expect(proposal.reload.applied_seq).to be > venue.reload.retcon_heads['phone'].seq
  end

  it 'conflicts only on fields changed since its base' do
    proposal = Retcon.propose(actor: member) { |p| p.update(venue, phone: '2', name: 'Eagle Bar') }
    Retcon.as(alice) { venue.update!(phone: '3') }
    expect { proposal.apply!(committer: reviewer) }.to raise_error(Retcon::Conflict) { |e|
      expect(e.conflicts.map(&:field)).to eq(['phone'])
    }
    expect(proposal.reload).to be_proposed

    result = proposal.apply!(committer: reviewer, on_conflict: :skip)
    expect(result[:conflicts].map(&:field)).to eq(['phone'])
    expect(venue.reload.attributes.slice('name', 'phone')).to eq('name' => 'Eagle Bar', 'phone' => '3')
    expect(proposal.reload.metadata['skipped'].first['field']).to eq('phone')
  end

  it 'proposes new records and deletes' do
    event = nil
    closed = Retcon.as(alice) { Venue.create!(name: 'Closed') }
    proposal = Retcon.propose(actor: member) do |p|
      event = p.create(Event, venue_id: venue.id, name: 'Drag Bingo')
      p.destroy(closed)
    end
    expect(Event.exists?(event.id)).to be(false)
    Event.saves.clear
    proposal.apply!(committer: reviewer)
    expect(Event.find(event.id).name).to eq('Drag Bingo')
    expect(Venue.exists?(closed.id)).to be(false)
    expect(Event.saves).to be_empty # no callbacks with side effects on apply
    expect(Venue.retcon_history.find_by(record_id: closed.id, op: 'tombstone').value).to include('name' => 'Closed')
  end

  it 'validates records before applying' do
    proposal = Retcon.propose(actor: member) { |p| p.update(venue, name: '') }
    expect { proposal.apply!(committer: reviewer) }.to raise_error(Retcon::Invalid)
    expect(proposal.reload).to be_proposed
  end

  it 'is rejected, withdrawn or amended, and only once' do
    rejected = Retcon.propose(actor: member) { |p| p.update(venue, phone: '5') }
    rejected.reject!(by: reviewer, reason: 'spam')
    expect(rejected.reload).to have_attributes(state: 'rejected', metadata: { 'reason' => 'spam' })
    expect { rejected.apply!(committer: reviewer) }.to raise_error(Retcon::InvalidState)

    withdrawn = Retcon.propose(actor: member) { |p| p.update(venue, phone: '6') }
    withdrawn.withdraw!
    expect(withdrawn.reload).to be_withdrawn

    original = Retcon.propose(actor: member) { |p| p.update(venue, phone: '7', name: 'Typo Bar') }
    amended = original.amend!(by: reviewer) { |p| p.update(venue, name: 'Eagle Bar') }
    expect(original.reload).to be_amended
    expect(amended).to have_attributes(author: member, committer: reviewer, parent: original)
    expect(amended.changes.values.first).to eq('phone' => '7', 'name' => 'Eagle Bar')
    amended.apply!(committer: reviewer)
    expect(venue.reload.attributes.slice('name', 'phone')).to eq('name' => 'Eagle Bar', 'phone' => '7')
  end

  it 'publishes events for routing' do
    opened = []
    subscriber = Retcon.on(:proposal_opened) { |changeset| opened << changeset.id }
    proposal = Retcon.propose(actor: member) { |p| p.update(venue, phone: '2') }
    expect(opened).to eq([proposal.id])
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it 'refuses empty proposals and unversioned fields' do
    expect { Retcon.propose(actor: member) { |_p| nil } }.to raise_error(ArgumentError, /changes nothing/)
    expect { Retcon.propose(actor: member) { |p| p.update(venue, events_count: 3) } }.to raise_error(ArgumentError)
  end

  it 'merges set_union fields instead of conflicting' do
    allow(Venue.retcon_config).to receive(:merges).and_return('tags' => :set_union)
    Retcon.as(alice) { venue.update!(tags: %w[leather]) }
    stale = Venue.find(venue.id)
    proposal = Retcon.propose(actor: member) { |p| p.update(stale, tags: %w[leather bears]) }
    Retcon.as(alice) { venue.reload.update!(tags: %w[leather karaoke]) }
    result = proposal.apply!(committer: reviewer)
    expect(result[:conflicts]).to be_empty
    expect(venue.reload.tags).to eq(%w[leather karaoke bears])
    expect(Retcon.verify(Venue)).to be_empty
  end
end
