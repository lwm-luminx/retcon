# frozen_string_literal: true

module Retcon
  # Finds live rows written outside Retcon (insert_all, update_all, update_column, raw SQL, the console) and writes
  # them into history as catch-up changesets attributed to Actor.untracked, so nothing builds on a change history
  # doesn't know. Rows are found three ways: the dirty flag the trigger sets (cheap, the default), a digest of every
  # row's versioned fields (full: true), and history that says a row exists when the live table has none (a delete
  # outside Retcon). Rows with no history at all are pre-Retcon data: they get genesis changesets instead.
  module Drift
    module_function

    # Locks the live row for the rest of the transaction and catches it up if it was written outside Retcon. Called
    # before every update and destroy.
    def lock_and_catch_up(record)
      model = record.class
      seq, dirty = model.unscoped.lock.where(model.primary_key => record.id).pick(:retcon_seq, :retcon_dirty)
      return unless dirty || seq.nil?

      catch_up(model, [record.id])
    end

    # Writes what changed outside Retcon for these ids in one changeset (genesis for rows history hasn't seen).
    # Returns the changesets written.
    def catch_up(model, ids, actor: Actor.untracked)
      live = model.unscoped.where(model.primary_key => ids).index_by(&:id)
      fresh, known = ids.partition { |id| model.retcon_history.state(id).nil? }
      written = []
      written << write(model, fresh.filter_map { |id| live[id] }, kind: 'genesis',
                                                                  actor: Actor.named('import', 'genesis'))
      written << write(model, known.filter_map { |id| live[id] }, kind: 'catch_up', actor:)
      gone = known.reject { |id| live.key?(id) }
      written << tombstone_missing(model, gone, actor:) if gone.any?
      written.compact.tap { renumber_open(written.compact) }
    end

    # Catches up every dirty row (or, with full, every row whose digest differs) and every row deleted outside
    # Retcon. Returns the number of rows caught up.
    def sweep(model, full: false, batch_size: 500)
      count = 0
      scope = model.unscoped.where(retcon_dirty: true).or(model.unscoped.where(retcon_seq: nil))
      scope.in_batches(of: batch_size) do |batch|
        ids = batch.pluck(model.primary_key)
        model.transaction { catch_up(model, ids) }
        count += ids.size
      end
      count += sweep_digests(model, batch_size) if full
      count + sweep_deleted(model)
    end

    # Writes genesis changesets for rows with no history, a batch per changeset.
    def genesis(model, batch_size:, actor:)
      count = 0
      model.unscoped.where(retcon_seq: nil).in_batches(of: batch_size) do |batch|
        model.transaction { write(model, batch.to_a, kind: 'genesis', actor:) }
        count += batch.size
      end
      count
    end

    def sweep_digests(model, batch_size)
      count = 0
      model.unscoped.find_in_batches(batch_size:) do |records|
        drifted = records.reject { |r| r.retcon_digest == Projection.digest(r) }
        next if drifted.empty?

        model.transaction { catch_up(model, drifted.map(&:id)) }
        count += drifted.size
      end
      count
    end

    def sweep_deleted(model)
      history = model.retcon_history
      alive = history.applied.where(op: History::LIFECYCLE)
                     .select('DISTINCT ON (record_id) record_id, op')
                     .order(:record_id, seq: :desc, id: :desc)
      ids = history.connection.select_values("SELECT record_id FROM (#{alive.to_sql}) l WHERE op <> 'tombstone'")
      ids = ids.map { |id| model.type_for_attribute(model.primary_key).cast(id) }
      gone = ids - model.unscoped.where(model.primary_key => ids).pluck(model.primary_key)
      return 0 if gone.empty?

      model.transaction { tombstone_missing(model, gone, actor: Actor.untracked) }
      gone.size
    end

    # One changeset with set rows for the fields of records that differ from history (every field, for genesis),
    # and the live rows' Retcon columns brought up to date.
    def write(model, records, kind:, actor:)
      return nil if records.empty?

      changeset = Changeset.create!(author: actor, kind:, state: 'applied', applied_seq: Retcon.next_seq,
                                    applied_at: Time.current, message: kind == 'genesis' ? 'Genesis' : 'Untracked')
      fields = model.retcon_config.tracked_fields
      rows = records.flat_map { |record| rows_for(model, record, fields, kind) }
      model.retcon_history.write(changeset, rows, applied: true)
      records.each do |record|
        Context.writing do
          model.unscoped.where(model.primary_key => record.id)
               .update_all(retcon_seq: changeset.applied_seq, retcon_digest: Projection.digest(record),
                           retcon_dirty: false)
        end
      end
      changeset
    end

    def rows_for(model, record, fields, kind)
      state = kind == 'genesis' ? nil : model.retcon_history.state(record.id)
      rows = []
      if state.nil?
        rows << { record_id: record.id, op: 'create', field: nil, value: nil, base_seq: nil }
      elsif !state['exists']
        rows << { record_id: record.id, op: 'revive', field: nil, value: nil, base_seq: state['seq'] }
      end
      heads = state ? model.retcon_history.heads(record.id) : {}
      fields.each do |field|
        value = record.read_attribute(field)
        next if state.nil? && value.nil?
        next if state && Value.same?(heads[field]&.value, value)

        rows << { record_id: record.id, op: 'set', field:, value:, base_seq: heads[field]&.seq }
      end
      rows
    end

    def tombstone_missing(model, ids, actor:)
      changeset = Changeset.create!(author: actor, kind: 'catch_up', state: 'applied', applied_seq: Retcon.next_seq,
                                    applied_at: Time.current, message: 'Deleted outside Retcon')
      rows = ids.map do |id|
        attributes = model.retcon_history.state(id)&.dig('attributes') || {}
        { record_id: id, op: 'tombstone', field: nil, value: attributes, base_seq: nil }
      end
      model.retcon_history.write(changeset, rows, applied: true)
      changeset
    end

    # A changeset already open in this transaction was given its seq before the catch-up; move it after, so history
    # orders the catch-up before the edit that follows it.
    def renumber_open(written)
      changeset = Context.open&.created
      return if written.empty? || changeset.nil?

      old = changeset.applied_seq
      seq = Retcon.next_seq
      changeset.update_columns(applied_seq: seq)
      Retcon.models.each_value do |m|
        m.retcon_history.where(changeset_id: changeset.id).update_all(seq:)
        Context.writing { m.unscoped.where(retcon_seq: old).update_all(retcon_seq: seq) }
      end
    end
  end
end
