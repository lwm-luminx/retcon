# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Redaction' do
  let(:alice) { Retcon::Actor.named('user', 'alice') }
  let(:doxxer) { Retcon::Actor.named('user', 'doxxer') }
  let(:staff) { Retcon::Actor.named('user', 'staff') }
  let!(:venue) { Retcon.as(alice) { Venue.create!(name: 'Eagle', phone: '1') } }

  it 'scrubs a value from every version and proposal, keeping commitments' do
    Retcon.as(doxxer) { venue.update!(phone: '206-555-0199') }
    proposal = Retcon.propose(actor: doxxer) { |p| p.update(venue, phone: '206-555-0199') }
    redaction = Retcon::Redaction.field(venue, :phone, actor: staff, reason: 'privacy', value: '206-555-0199',
                                                       remedy: '1')
    rows = Venue.retcon_history.where(record_id: venue.id, field: 'phone').order(:id).to_a
    expect(rows.map(&:raw_value)).to eq(['1', nil, nil, '1'])
    expect(rows.select(&:redacted?).map(&:commitment)).to all(be_present)
    expect(rows).to all(be_verified)
    expect(venue.reload.phone).to eq('1')
    expect(redaction.metadata).to include('reason' => 'privacy', 'field' => 'phone')
    expect(redaction.metadata.to_json).not_to include('206-555-0199')
    expect(proposal.reload.changes.values.first['phone']).to be_nil
    expect(Retcon.verify(Venue)).to be_empty
  end

  it 'scrubs tombstone snapshots' do
    Retcon.as(alice) { venue.update!(phone: 'secret') }
    Retcon.as(alice) { venue.destroy! }
    Retcon::Redaction.field(venue, :phone, actor: staff, reason: 'privacy', remedy: Retcon::Redaction::KEEP)
    expect(Venue.retcon_history.find_by(record_id: venue.id, op: 'tombstone').value).not_to have_key('phone')
  end

  it 'detects a tampered value through its commitment' do
    row = Venue.retcon_history.find_by(record_id: venue.id, field: 'name')
    Venue.retcon_history.where(id: row.id).update_all(value: { 'v' => 'Forged' })
    expect(row.reload).not_to be_verified
  end

  it 'pseudonymizes an editor and keeps their edits grouped' do
    Retcon.as(doxxer) { venue.update!(name: 'X') }
    Retcon::Redaction.editor(doxxer, by: staff, reason: 'account deleted')
    expect(doxxer.reload).to be_redacted
    expect(doxxer.label).to start_with('editor-')
    expect(Retcon::Changeset.where(author: doxxer).count).to eq(1)
    expect(Retcon::Actor.named('user', 'doxxer')).not_to eq(doxxer)
  end

  it "erases only the requester's own edits, sending overlaps to review" do
    Retcon.as(doxxer) { venue.update!(name: 'Mine', phone: 'mine') }
    Retcon.as(alice) { venue.reload.update!(phone: 'alice') }
    result = Retcon::Redaction.erase(doxxer, by: staff, reason: 'deletion request')
    expect(venue.reload.attributes.slice('name', 'phone')).to eq('name' => 'Eagle', 'phone' => 'alice')
    expect(result[:review].changes.values.first).to eq('phone' => '1')
    authored = Venue.retcon_history.joins(:changeset).where(retcon_changesets: { author_id: doxxer.id })
    expect(authored.map(&:raw_value)).to all(be_nil)
    expect(doxxer.reload).to be_redacted
  end
end
