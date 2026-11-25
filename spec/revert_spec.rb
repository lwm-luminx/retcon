# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Reverts' do
  let(:alice) { Retcon::Actor.named('user', 'alice') }
  let(:vandal) { Retcon::Actor.named('user', 'vandal') }
  let(:carol) { Retcon::Actor.named('user', 'carol') }
  let(:staff) { Retcon::Actor.named('user', 'staff') }
  let!(:venue) { Retcon.as(alice) { Venue.create!(name: 'Eagle', phone: '1', tags: %w[bar]) } }

  it 'undoes a changeset and is itself undoable' do
    bad = Retcon.changeset(actor: vandal) { venue.update!(name: 'Spam') }
    result = bad.revert!(actor: staff)
    expect(venue.reload.name).to eq('Eagle')
    expect(result.revert).to have_attributes(kind: 'revert', metadata: { 'reverts' => [bad.id] })
    result.revert.revert!(actor: staff)
    expect(venue.reload.name).to eq('Spam')
  end

  it "drops an actor's changes and keeps later work by others on other fields" do
    Retcon.as(vandal) { venue.update!(name: 'Spam', phone: '666') }
    Retcon.as(carol) { venue.reload.update!(tags: %w[bar dance]) }
    result = Retcon.revert_actor(vandal, actor: staff)
    expect(venue.reload.attributes.slice('name', 'phone', 'tags'))
      .to eq('name' => 'Eagle', 'phone' => '1', 'tags' => %w[bar dance])
    expect(result.review).to be_nil
    expect(Retcon.verify(Venue)).to be_empty
  end

  it 'sends same-field overlaps to review instead of overwriting later work' do
    Retcon.as(vandal) { venue.update!(phone: '666') }
    Retcon.as(carol) { venue.reload.update!(phone: '555') }
    result = Retcon.revert_actor(vandal, actor: staff)
    expect(venue.reload.phone).to eq('555')
    expect(result.review).to be_proposed
    expect(result.review.changes).to eq([Venue, venue.id] => { 'phone' => '1' })
    expect(result.review.parent).to eq(result.revert)
  end

  it "skips the vandal's own later edits on the same field" do
    Retcon.as(vandal) { venue.update!(phone: '666') }
    Retcon.as(vandal) { venue.reload.update!(phone: '667') }
    Retcon.revert_actor(vandal, actor: staff)
    expect(venue.reload.phone).to eq('1')
  end

  it 'revives what was deleted and removes what was created' do
    Retcon.as(vandal) do
      venue.destroy!
      Venue.create!(name: 'Fake Bar')
    end
    Retcon.revert_actor(vandal, actor: staff)
    expect(Venue.find(venue.id).name).to eq('Eagle')
    expect(Venue.find_by(name: 'Fake Bar')).to be_nil
  end

  it 'flags reviewers who approved the reverted proposals' do
    proposal = Retcon.propose(actor: vandal) { |p| p.update(venue, name: 'Spam') }
    proposal.apply!(committer: carol)
    result = Retcon.revert_actor(vandal, actor: staff)
    expect(result.flagged).to eq([carol])
    expect(venue.reload.name).to eq('Eagle')
  end

  it 'reverts only since a time' do
    Retcon.as(vandal) { venue.update!(name: 'Old edit') }
    cutoff = Time.current
    Retcon.as(vandal) { venue.reload.update!(phone: '666') }
    Retcon.revert_actor(vandal, actor: staff, since: cutoff)
    expect(venue.reload.attributes.slice('name', 'phone')).to eq('name' => 'Old edit', 'phone' => '1')
  end
end
