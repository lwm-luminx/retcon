# frozen_string_literal: true

module Retcon
  # Proposals: changesets recorded against base versions and applied later, like pull requests.
  #
  #   proposal = Retcon.propose(actor: member, message: 'New hours') do |p|
  #     p.update(venue, hours: 'Tue–Sun 4pm–2am')                        # base: the version venue was loaded at
  #     p.create(Event, venue_id: venue.id, name: 'Drag Bingo')         # id chosen now
  #     p.destroy(old_event)
  #   end
  #   proposal.apply!(committer: reviewer)                                 # Retcon::Conflict if a field moved on
  #   proposal.apply!(committer: reviewer, on_conflict: :skip)             # applies the rest, returns conflicts
  #
  # A proposal touches no live table until it is applied. Fields conflict only when someone else changed that same
  # field since the proposal's base, to a different value.
  module Proposal
    # Records a proposal's changes.
    class Builder
      attr_reader :rows

      def initialize
        @rows = Hash.new { |h, model| h[model] = [] }
      end

      # Proposes new values for record's fields. base: the seq (or {field => seq}) the proposer saw; defaults to
      # the version the record was loaded at. Fields go as a Hash or as keywords: p.update(venue, phone: '555').
      def update(record, attributes = nil, base: nil, **fields)
        attributes ||= fields
        model = record.class
        fields = model.retcon_config.tracked_fields
        attributes.each do |field, value|
          field = field.to_s
          raise ArgumentError, "#{model.name}.#{field} isn't versioned" unless fields.include?(field)

          rows[model] << { record_id: record.id, op: 'set', field:, value: Value.dump(value),
                           base_seq: base_for(record, field, base) }
        end
        record
      end

      # Proposes a new record, with its id chosen now. Returns the (unsaved) record.
      def create(model, attributes = nil, **fields)
        record = model.new(attributes || fields)
        record[model.primary_key] ||= Proposal.new_id(model)
        rows[model] << { record_id: record.id, op: 'create', field: nil, value: nil, base_seq: nil }
        model.retcon_config.tracked_fields.each do |field|
          value = record.read_attribute(field)
          unless value.nil?
            rows[model] << { record_id: record.id, op: 'set', field:, value: Value.dump(value),
                             base_seq: nil }
          end
        end
        record
      end

      # Proposes deleting a record (a tombstone, applied later).
      def destroy(record)
        rows[record.class] << { record_id: record.id, op: 'tombstone', field: nil, value: nil,
                                base_seq: record.attribute_in_database('retcon_seq') }
        record
      end

      private

      def base_for(record, field, base)
        case base
        when Hash then base[field] || base[field.to_sym]
        when Integer then base
        else record.attribute_in_database('retcon_seq')
        end
      end
    end

    module_function

    def build(actor:, message:, scope:, metadata:, parent: nil, author: actor, committer: nil)
      builder = Builder.new
      yield builder
      raise ArgumentError, 'the proposal changes nothing' if builder.rows.values.all?(&:empty?)

      ActiveRecord::Base.transaction(requires_new: true) do
        changeset = Changeset.create!(author:, committer:, parent:, kind: 'proposal', state: 'proposed', message:,
                                      scope:, metadata:)
        builder.rows.each { |model, rows| write_proposed(model, changeset, rows) }
        Retcon.instrument(:proposal_opened, changeset:)
        changeset
      end
    end

    def write_proposed(model, changeset, rows)
      # Values are already dumped; History.write dumps again, which leaves dumped values as they are.
      model.retcon_history.write(changeset, rows, applied: false)
    end

    def amend(original, by:, message:)
      raise InvalidState, "changeset #{original.id} is #{original.state}, not proposed" unless original.proposed?

      builder = Builder.new
      original.versions.each do |v|
        builder.rows[v.live_model] << { record_id: v.record_id, op: v.op, field: v.field, value: v.raw_value,
                                        base_seq: v.base_seq }
      end
      yield builder if block_given?
      ActiveRecord::Base.transaction(requires_new: true) do
        amended = Changeset.create!(author: original.author, committer: by, parent: original, kind: 'proposal',
                                    state: 'proposed', message:, scope: original.scope, metadata: original.metadata)
        builder.rows.each { |model, rows| write_proposed(model, amended, dedupe(rows)) }
        original.update!(state: 'amended', committer: by, decided_at: Time.current)
        Retcon.instrument(:proposal_opened, changeset: amended)
        amended
      end
    end

    # The last row for each (record, op, field) wins: an amendment's own update replaces the original's.
    def dedupe(rows) = rows.reverse.uniq { |r| [r[:record_id], r[:op], r[:field]] }.reverse

    # Applies a proposed changeset. Returns { changeset:, conflicts: [FieldConflict] }.
    def apply(changeset, committer:, on_conflict:)
      ActiveRecord::Base.transaction(requires_new: true) do
        changeset.lock!
        raise InvalidState, "changeset #{changeset.id} is #{changeset.state}, not proposed" unless changeset.proposed?

        plan = plan(changeset)
        conflicts = plan.flat_map { |step| step[:conflicts] }
        raise Conflict, conflicts if conflicts.any? && on_conflict == :raise

        seq = Retcon.next_seq
        changeset.update!(state: 'applied', committer:, applied_seq: seq, applied_at: Time.current,
                          decided_at: Time.current)
        plan.each { |step| apply_step(changeset, step, seq) }
        changeset.update!(metadata: changeset.metadata.merge('skipped' => conflicts.map(&:to_h))) if conflicts.any?
        Retcon.instrument(:changeset_applied, changeset:)
        { changeset:, conflicts: }
      end
    end

    # What applying does to each record: [{model:, record_id:, rows:, conflicts:}].
    def plan(changeset)
      changeset.versions.group_by { |v| [v.live_model, v.record_id] }.map do |(model, record_id), rows|
        rows.sort_by!(&:id)
        if model.unscoped.exists?(model.primary_key => record_id)
          Drift.lock_and_catch_up(model.unscoped.find(record_id))
        end
        heads = model.retcon_history.heads(record_id)
        conflicts = []
        merged = {}
        rows.each do |v|
          next unless v.op == 'set'

          head = heads[v.field]
          next if head.nil? || v.base_seq.nil? || head.seq <= v.base_seq || Value.same?(head.value, v.raw_value)

          if (value = merge_value(model, v.field, head.value, v.raw_value))
            merged[v.field] = value
            next
          end

          conflicts << FieldConflict.new(model: model.name, record_id:, field: v.field, base_seq: v.base_seq,
                                         head_seq: head.seq, current: head.value, proposed: v.raw_value)
        end
        { model:, record_id:, rows:, conflicts:, heads:, merged: }
      end
    end

    # The value a field merges to instead of conflicting, per its merge strategy (nil: it conflicts). :set_union keeps
    # every element either side has, so two people tagging a venue both get their tags.
    def merge_value(model, field, current, proposed)
      return unless model.retcon_config.merges[field] == :set_union && current.is_a?(Array) && proposed.is_a?(Array)

      current | proposed
    end

    def apply_step(changeset, step, seq)
      model = step[:model]
      record_id = step[:record_id]
      skipped = step[:conflicts].map(&:field)
      rows = step[:rows].reject { |v| v.op == 'set' && skipped.include?(v.field) }
      ops = rows.map(&:op)
      sets = rows.select { |v| v.op == 'set' }.to_h { |v| [v.field, v.raw_value] }.merge(step[:merged])

      if ops.include?('tombstone')
        apply_tombstone(model, record_id, rows.find { |v| v.op == 'tombstone' })
      elsif ops.include?('create')
        Projection.insert(model, record_id, sets, seq:)
      elsif sets.any?
        Projection.update(model, record_id, sets, seq:)
      end
      model.retcon_history.where(id: rows.map(&:id)).update_all(applied: true, seq:)
      # Skipped fields stay unapplied in the applied changeset, so history shows what was proposed and not taken.
      write_merged(changeset, step)
    end

    # Deletes the live row and keeps it, as it is now, in the tombstone row's snapshot.
    def apply_tombstone(model, record_id, tombstone)
      record = model.unscoped.find_by(model.primary_key => record_id)
      snapshot = record ? record.attributes.except(*LIVE_COLUMNS).transform_values { |v| Value.dump(v) } : {}
      Projection.delete(model, record_id)
      model.retcon_history.where(id: tombstone.id).update_all(value: snapshot)
    end

    # A merged field gets one more version, after the proposed one, holding what live now has.
    def write_merged(changeset, step)
      rows = step[:merged].map do |field, value|
        { record_id: step[:record_id], op: 'set', field:, value:, base_seq: step[:heads][field]&.seq }
      end
      step[:model].retcon_history.write(changeset, rows, applied: true)
      changeset
    end

    # An id for a record that doesn't exist yet: a UUID, or the table's sequence.
    def new_id(model)
      column = model.columns_hash[model.primary_key]
      return SecureRandom.uuid if column.type == :uuid

      sequence = model.connection.select_value(
        "SELECT pg_get_serial_sequence(#{model.connection.quote(model.table_name)}, " \
        "#{model.connection.quote(model.primary_key)})"
      )
      raise Error, "#{model.name} has no id sequence to propose a new record with" unless sequence

      model.connection.select_value("SELECT nextval(#{model.connection.quote(sequence)})").to_i
    end
  end
end
