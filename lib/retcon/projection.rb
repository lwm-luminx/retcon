# frozen_string_literal: true

module Retcon
  # Writes history into live tables: when a proposal is applied, a changeset reverted, a record revived or rebuilt.
  # Records are validated first (Retcon::Invalid if they would be invalid), then written with SQL, so model callbacks
  # with side effects (pushes, emails, geocoding) don't run for changes that are old or reviewed. Subscribe to
  # Retcon's changeset_applied event for side effects that should follow these writes.
  module Projection
    module_function

    # The digest a live row's versioned fields should have.
    def digest(record)
      fields = record.class.retcon_config.tracked_fields
      Value.digest(fields.to_h { |f| [f, Value.dump(record.read_attribute(f))] })
    end

    # Sets attributes on a live row. Returns the record.
    def update(model, record_id, attributes, seq:, validate: true)
      record = model.unscoped.find_by(model.primary_key => record_id) or
        raise ActiveRecord::RecordNotFound, "#{model.name} #{record_id} isn't live"
      attributes.each { |field, value| record[field] = Value.load(model, field, value) }
      check!(record) if validate
      Context.writing do
        values = attributes.keys.to_h { |f| [f, record.read_attribute(f)] }
        model.unscoped.where(model.primary_key => record_id)
             .update_all(values.merge(retcon_seq: seq, retcon_digest: digest(record), retcon_dirty: false))
      end
      record
    end

    # Puts a row back (or in for the first time) with its id. attributes: every column to set.
    def insert(model, record_id, attributes, seq:, validate: true)
      record = model.new
      attributes.each { |field, value| record[field] = Value.load(model, field, value) if model.has_attribute?(field) }
      record[model.primary_key] = record_id
      check!(record) if validate
      values = record.attributes.compact.merge('retcon_seq' => seq, 'retcon_digest' => digest(record),
                                               'retcon_dirty' => false)
      Context.writing { model.insert!(values) }
      record
    end

    def delete(model, record_id)
      Context.writing { model.unscoped.where(model.primary_key => record_id).delete_all }
    end

    def check!(record)
      Context.replaying { raise Invalid, record unless record.valid? }
    end
  end
end
