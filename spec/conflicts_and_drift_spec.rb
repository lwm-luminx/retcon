# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Conflicts and drift' do
  let(:alice) { Retcon::Actor.named('user', 'alice') }
  let(:bob) { Retcon::Actor.named('user', 'bob') }
  let!(:venue) { Retcon.as(alice) { Venue.create!(name: 'Eagle', phone: '1') } }

  describe 'per-field optimistic locking' do
    it 'refuses a field someone else changed since the record was loaded' do
      stale = Venue.find(venue.id)
      Retcon.as(bob) { venue.update!(phone: '2') }
      stale.phone = '3'
      expect { Retcon.as(alice) { stale.save! } }.to raise_error(Retcon::Conflict) { |e|
        expect(e.conflicts.map(&:field)).to eq(['phone'])
        expect(e.conflicts.first.current).to eq('2')
      }
      expect(venue.reload.phone).to eq('2')
    end

    it 'commits fields nobody else touched' do
      stale = Venue.find(venue.id)
      Retcon.as(bob) { venue.update!(phone: '2') }
      Retcon.as(alice) { stale.update!(name: 'The Eagle') }
      expect(venue.reload.attributes.slice('name', 'phone')).to eq('name' => 'The Eagle', 'phone' => '2')
    end

    it 'with :skip, commits the rest and lists the conflicts' do
      stale = Venue.find(venue.id)
      Retcon.as(bob) { venue.update!(phone: '2') }
      stale.retcon_on_conflict = :skip
      Retcon.as(alice) { stale.update!(name: 'New', phone: '3') }
      expect(stale.retcon_conflicts.map(&:field)).to eq(['phone'])
      expect(venue.reload.attributes.slice('name', 'phone')).to eq('name' => 'New', 'phone' => '2')
    end

    it 'takes explicit per-field bases' do
      base = venue.retcon_seq
      Retcon.as(bob) { venue.update!(phone: '2') }
      fresh = Venue.find(venue.id)
      fresh.retcon_base = { 'phone' => base }
      fresh.phone = '3'
      expect { Retcon.as(alice) { fresh.save! } }.to raise_error(Retcon::Conflict)
    end

    it 'does not conflict when the other edit set the same value' do
      stale = Venue.find(venue.id)
      Retcon.as(bob) { venue.update!(phone: '2') }
      expect { Retcon.as(alice) { stale.update!(phone: '2') } }.not_to raise_error
    end
  end

  describe 'drift' do
    it 'marks rows written outside Retcon dirty, and catches them up before the next edit' do
      Venue.where(id: venue.id).update_all(phone: '9')
      expect(venue.reload.retcon_dirty).to be(true)
      Retcon.as(bob) { venue.update!(name: 'Edited') }
      kinds = Retcon::Changeset.order(:applied_seq).last(2).map(&:kind)
      expect(kinds).to eq(%w[catch_up edit])
      expect(Retcon::Changeset.find_by(kind: 'catch_up').author.kind).to eq('untracked')
      expect(Venue.retcon_state(venue.id)['attributes']).to include('phone' => '9', 'name' => 'Edited')
      expect(venue.reload.retcon_dirty).to be(false)
    end

    it 'orders the catch-up before an edit already open in the same changeset' do
      other = Retcon.as(alice) { Venue.create!(name: 'Other') }
      Venue.where(id: venue.id).update_all(phone: '9')
      edit = Retcon.changeset(actor: bob) do
        other.update!(name: 'Other 2')
        venue.reload.update!(phone: '10')
      end
      catch_up = Retcon::Changeset.find_by(kind: 'catch_up')
      expect(edit.reload.applied_seq).to be > catch_up.applied_seq
      expect(other.reload.retcon_seq).to eq(edit.applied_seq)
      expect(Venue.retcon_state(venue.id)['attributes']['phone']).to eq('10')
    end

    it 'sweeps dirty rows, rows deleted outside Retcon, and (full) digest mismatches' do
      gone = Retcon.as(alice) { Venue.create!(name: 'Gone') }
      Venue.where(id: venue.id).update_all(phone: '7')
      Venue.where(id: gone.id).delete_all
      expect(Venue.retcon_sweep!).to eq(2)
      expect(Venue.retcon_state(venue.id)['attributes']['phone']).to eq('7')
      expect(Venue.retcon_state(gone.id)['exists']).to be(false)
      expect(Retcon.verify(Venue)).to be_empty
    end

    it 'finds drift the trigger missed with a full sweep' do
      Venue.connection.execute('ALTER TABLE venues DISABLE TRIGGER retcon_mark_dirty_venues')
      Venue.where(id: venue.id).update_all(phone: '8')
      Venue.connection.execute('ALTER TABLE venues ENABLE TRIGGER retcon_mark_dirty_venues')
      expect(Venue.retcon_sweep!).to eq(0)
      expect(Venue.retcon_sweep!(full: true)).to eq(1)
      expect(Venue.retcon_state(venue.id)['attributes']['phone']).to eq('8')
    end

    it 'writes genesis changesets for rows that predate Retcon' do
      Venue.insert_all!([{ name: 'Old Bar' }])
      old = Venue.find_by(name: 'Old Bar')
      expect(old.retcon_seq).to be_nil
      expect(Venue.retcon_genesis!).to eq(1)
      genesis = Retcon::Changeset.find_by(kind: 'genesis')
      expect(genesis.author.label).to eq('genesis')
      expect(Venue.retcon_state(old.id)['attributes']['name']).to eq('Old Bar')
    end
  end

  describe 'bulk imports' do
    let(:import) { Retcon::Actor.named('import', 'listings') }

    it 'creates and updates with history in one changeset' do
      changeset = Retcon::Bulk.upsert(Venue, [{ name: 'Eagle', phone: '5' }, { name: 'Pony', phone: '6' }],
                                      unique_by: :name, actor: import)
      expect(changeset.kind).to eq('import')
      expect(venue.reload.phone).to eq('5')
      pony = Venue.find_by(name: 'Pony')
      expect(changeset.records).to contain_exactly([Venue, venue.id], [Venue, pony.id])
      expect(Retcon.verify(Venue)).to be_empty
    end

    it 'leaves unchanged rows alone' do
      changeset = Retcon::Bulk.upsert(Venue, [{ name: 'Eagle', phone: '1' }], unique_by: :name, actor: import)
      expect(changeset.records).to be_empty
    end
  end

  describe 'Retcon.edit with a policy' do
    after { Retcon.policy = nil }

    it 'commits, proposes or denies by policy' do
      Retcon.policy = lambda { |actor, _record, changes|
        if actor == alice
          :commit
        else
          (changes.key?('name') ? :deny : :propose)
        end
      }
      Retcon.edit(venue, { phone: '2' }, actor: alice)
      expect(venue.reload.phone).to eq('2')
      proposal = Retcon.edit(venue, { phone: '3' }, actor: bob)
      expect(proposal).to be_proposed
      expect(venue.reload.phone).to eq('2')
      expect { Retcon.edit(venue, { name: 'X' }, actor: bob) }.to raise_error(Retcon::Denied)
    end
  end
end
