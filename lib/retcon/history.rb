# frozen_string_literal: true

module Retcon
  # A versioned table's history: immutable rows, one per field set (op 'set') or lifecycle step ('create',
  # 'tombstone', 'revive'), each in a changeset. Rows of applied changesets carry seq, their place in Retcon's global
  # order of application; a proposal's rows wait with applied false until it is applied. Only redaction ever changes a
  # row, and only to scrub its value and salt.
  module History
    LIFECYCLE = %w[create tombstone revive].freeze

    # The current value of a field: its newest applied version.
    Head = Data.define(:field, :seq, :value, :redacted, :row_id)

    # The class for a model's history table (retcon_<table>).
    def self.for(model)
      table = Schema.history_table(model.table_name)
      klass = Class.new(Base) do
        self.table_name = table
        @live_model = model
      end
      model.const_set(:RetconHistory, klass)
    end

    # Shared behavior of every history class.
    class Base < ActiveRecord::Base
      self.abstract_class = true

      belongs_to :changeset, class_name: 'Retcon::Changeset'

      scope :applied, -> { where(applied: true) }
      scope :in_order, -> { order(:seq, :id) }

      class << self
        attr_reader :live_model

        def config = live_model.retcon_config

        # Writes version rows: [{record_id:, op:, field:, value:, base_seq:}, ...] into changeset. applied rows get
        # the changeset's seq.
        def write(changeset, rows, applied:)
          return if rows.empty?

          now = Time.current
          version = config.schema_version
          insert_all!(rows.map do |row|
            salt = row[:op] == 'set' ? Value.salt : nil
            value = row[:op] == 'set' ? { 'v' => Value.dump(row[:value]) } : row[:value]
            { changeset_id: changeset.id, record_id: row[:record_id], op: row[:op], field: row[:field], value:,
              salt:, commitment: salt && Value.commit(salt, value['v']), applied:,
              seq: applied ? changeset.applied_seq : nil, base_seq: row[:base_seq], schema_version: version,
              created_at: now }
          end)
        end

        # {field => Head} for a record, upcast to the current schema. Only applied rows count.
        def heads(record_id)
          rows = applied.where(record_id:, op: 'set')
                        .select('DISTINCT ON (field) id, op, field, value, seq, schema_version, redacted_by_id')
                        .order(:field, seq: :desc, id: :desc).to_a
          heads = {}
          rows.each do |row|
            row.current_pairs.each do |field, value|
              next if heads[field] && heads[field].seq > row.seq

              heads[field] = Head.new(field:, seq: row.seq, value:, redacted: row.redacted?, row_id: row.id)
            end
          end
          heads
        end

        # The newest applied lifecycle row (create, tombstone or revive), or nil.
        def lifecycle(record_id)
          applied.where(record_id:, op: LIFECYCLE).order(seq: :desc, id: :desc).first
        end

        # Whether history says the record exists (created or revived, and not since tombstoned).
        def alive?(record_id) = %w[create revive].include?(lifecycle(record_id)&.op)

        # The record as history says it is: { 'exists' => bool, 'seq' => newest seq, 'attributes' => {...} }, or nil
        # when history has never seen it.
        def state(record_id)
          life = lifecycle(record_id)
          heads = heads(record_id)
          return nil if life.nil? && heads.empty?

          fields = heads.slice(*config.tracked_fields).transform_values(&:value)
          seq = [life&.seq, *heads.values.map(&:seq)].compact.max
          { 'exists' => life.nil? || life.op != 'tombstone', 'seq' => seq, 'attributes' => fields }
        end

        # The newest tombstone whose snapshot contains these attributes (for reviving an edge by its triple).
        def tombstone_matching(attributes)
          applied.where(op: 'tombstone').where('value @> ?', Value.dump(attributes).to_json)
                 .order(seq: :desc, id: :desc).first
        end
      end

      def live_model = self.class.live_model

      def redacted? = redacted_by_id.present?

      # This row's value as written (nil once redacted).
      def raw_value = op == 'set' ? value&.fetch('v', nil) : value

      # [[field, value], ...] under the current schema (an upcaster may rename, split or drop the field).
      def current_pairs
        return [[field, raw_value]] if schema_version >= self.class.config.schema_version

        self.class.config.upcast_value(field, raw_value, schema_version)
      end

      def current_value = current_pairs.first&.last

      # Whether the stored commitment matches the value (always true once redacted: nothing left to check).
      def verified?
        return true if redacted? || op != 'set'

        Value.commit(salt, raw_value) == commitment
      end
    end
  end
end
