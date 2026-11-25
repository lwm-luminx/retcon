# frozen_string_literal: true

module Retcon
  # Bulk writes with history: imports and syncs that would otherwise use upsert_all and leave untracked changes.
  # One changeset per call, attributed to the import.
  #
  #   Retcon::Bulk.upsert(Venue, rows, unique_by: :external_key, actor: Retcon::Actor.named('import', 'facebook'))
  #
  # Rows are matched to live rows by unique_by; new rows are created, matched rows get only the fields that differ.
  # Validations and callbacks don't run (as with upsert_all). Returns the Changeset, or nil when nothing changed.
  module Bulk
    module_function

    def upsert(model, rows, unique_by:, actor:, message: nil)
      keys = Array(unique_by).map(&:to_s)
      rows = rows.map { |r| r.transform_keys(&:to_s) }
      Retcon.changeset(actor:, kind: 'import', message: message || "Import into #{model.table_name}") do
        existing = match(model, keys, rows)
        fields = model.retcon_config.tracked_fields
        changeset = nil
        rows.each do |row|
          record = existing[row.values_at(*keys)]
          changeset ||= Context.open.changeset
          record ? update(model, record, row, fields, changeset) : create(model, row, fields, changeset)
        end
      end
    end

    def match(model, keys, rows)
      conditions = keys.to_h { |k| [k, rows.map { |r| r[k] }.uniq] }
      model.unscoped.where(conditions).index_by { |rec| keys.map { |k| rec.read_attribute(k) } }
    end

    def create(model, row, fields, changeset)
      id = row[model.primary_key] || Proposal.new_id(model)
      record = Projection.insert(model, id, row, seq: changeset.applied_seq, validate: false)
      history_rows = [{ record_id: id, op: 'create', field: nil, value: nil, base_seq: nil }]
      fields.each do |field|
        value = record.read_attribute(field)
        history_rows << { record_id: id, op: 'set', field:, value:, base_seq: nil } unless value.nil?
      end
      model.retcon_history.write(changeset, history_rows, applied: true)
    end

    def update(model, record, row, fields, changeset)
      Drift.lock_and_catch_up(record)
      changed = row.slice(*fields).reject do |f, v|
        Value.same?(record.read_attribute(f), model.type_for_attribute(f).cast(v))
      end
      return if changed.empty?

      heads = model.retcon_history.heads(record.id)
      Projection.update(model, record.id, changed, seq: changeset.applied_seq, validate: false)
      model.retcon_history.write(changeset, changed.map do |field, value|
        { record_id: record.id, op: 'set', field:, value: model.type_for_attribute(field).cast(value),
          base_seq: heads[field]&.seq }
      end, applied: true)
    end
  end
end
