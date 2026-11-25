# frozen_string_literal: true

module Retcon
  # Versions an Active Record model. Every save and destroy writes history in the same transaction as the live row,
  # into the open changeset (Retcon.changeset) or one of its own, attributed to Retcon.as's actor.
  #
  #   class Venue < ApplicationRecord
  #     include Retcon::Model
  #     versioned { ignore :view_count }
  #   end
  #
  # Before an update, Retcon locks the live row, catches up any change written outside Retcon (Retcon::Drift), then
  # checks each changed field against the version the record was loaded at (or retcon_base): a field someone else
  # changed since raises Retcon::Conflict, or with retcon_on_conflict = :skip is left out and listed in
  # retcon_conflicts. Destroys write a tombstone with the row as it was; the live row is deleted, so reads never see
  # it, and Model.retcon_revive! brings it back with its id and history.
  module Model
    extend ActiveSupport::Concern

    # Wraps whole saves and destroys, so autosaved and dependent records join the same changeset.
    module Grouping
      %i[save save! destroy destroy!].each do |name|
        define_method(name) do |*args, **kwargs, &block|
          return super(*args, **kwargs, &block) if Context.replaying? || Context.state[:bypass]

          Context.implicit { super(*args, **kwargs, &block) }
        end
      end
    end

    included do
      prepend Grouping

      Retcon.models[name] = self if name

      # Per-field base versions for the next save: {field => seq}, or one seq for every field.
      attr_writer :retcon_base
      # :raise (the default) or :skip, for fields that conflict on the next save.
      attr_writer :retcon_on_conflict
      # The FieldConflicts left out of the last save (with retcon_on_conflict = :skip).
      attr_reader :retcon_conflicts

      around_save :retcon_around_save
      around_destroy :retcon_around_destroy
    end

    class_methods do
      def retcon_config = @retcon_config ||= Config.new(self)

      # Sets versioning options: see Retcon::Config.
      def versioned(&)
        retcon_config.instance_eval(&)
        retcon_config.reset!
        self
      end

      def retcon_history = @retcon_history ||= History.for(self)

      # The record as history says it is (see History.state).
      def retcon_state(record_id) = retcon_history.state(record_id)

      # Brings back a tombstoned record with its id: the row as it was, with each field's newest version. Returns
      # the record. Done as a changeset of its own (or in the open one).
      def retcon_revive!(record_id, actor: Retcon.actor, message: nil)
        Retcon.changeset(actor:, message: message || "Revive #{name} #{record_id}") do
          Revert.revive(self, record_id, Context.open.changeset(scope: nil))
        end
        unscoped.find(record_id)
      end

      # Rewrites a live row from history (inserting, updating or deleting it). Returns what history says.
      def retcon_rebuild!(record_id)
        state = retcon_state(record_id) or raise Error, "#{name} #{record_id} has no history"
        live = unscoped.exists?(primary_key => record_id)
        if !state['exists']
          Projection.delete(self, record_id) if live
        elsif live
          Projection.update(self, record_id, state['attributes'], seq: state['seq'], validate: false)
        else
          snapshot = retcon_history.applied.where(record_id:, op: 'tombstone').order(seq: :desc).first&.value || {}
          Projection.insert(self, record_id, snapshot.merge(state['attributes']), seq: state['seq'], validate: false)
        end
        state
      end

      # Rows written outside Retcon, caught up into history: see Retcon::Drift.
      def retcon_sweep!(full: false, batch_size: 500) = Drift.sweep(self, full:, batch_size:)

      # Writes Retcon columns without history for rows that have none (run before the first sweep, or let the sweep
      # do it as genesis changesets).
      def retcon_genesis!(batch_size: 500, actor: Actor.named('import', 'genesis'))
        Drift.genesis(self, batch_size:, actor:)
      end
    end

    # Every version row of this record, oldest first (proposals included; check #applied).
    def retcon_versions = self.class.retcon_history.where(record_id: id).order(Arel.sql('seq NULLS LAST'), :id)

    # {field => Head} with the newest applied version of each field: who changed it last and when (blame).
    def retcon_heads = self.class.retcon_history.heads(id)

    # Whether the live row's versioned fields differ from what Retcon last wrote (a write outside Retcon).
    def retcon_drifted?
      row = self.class.unscoped.where(self.class.primary_key => id).pick(:retcon_dirty, :retcon_digest)
      row.nil? || row[0] || row[1] != Projection.digest(self.class.unscoped.find(id))
    end

    def retcon_base = @retcon_base

    def retcon_on_conflict = @retcon_on_conflict || :raise

    private

    def retcon_skip? = Context.replaying? || Context.state[:bypass]

    def retcon_around_save(&)
      return yield if retcon_skip?

      new_record? ? retcon_create(&) : retcon_update(&)
    end

    def retcon_create(&)
      changeset = Context.open.changeset(scope: self.class.retcon_config.scope_for(self))
      self.retcon_seq = changeset.applied_seq
      self.retcon_digest = Projection.digest(self)
      self.retcon_dirty = false
      result = Context.writing(&)
      fields = self.class.retcon_config.tracked_fields
      rows = [{ record_id: id, op: 'create', field: nil, value: nil, base_seq: nil }]
      fields.each do |field|
        value = read_attribute(field)
        rows << { record_id: id, op: 'set', field:, value:, base_seq: nil } unless value.nil?
      end
      self.class.retcon_history.write(changeset, rows, applied: true)
      retcon_fix_digest
      result
    end

    def retcon_update(&)
      tracked = self.class.retcon_config.tracked_fields
      return yield if changes_to_save.slice(*tracked).empty?

      Drift.lock_and_catch_up(self)
      heads = self.class.retcon_history.heads(id)
      retcon_check_conflicts(heads, tracked)
      changed = changes_to_save.slice(*tracked)
      return yield if changed.empty?

      changeset = Context.open.changeset(scope: self.class.retcon_config.scope_for(self))
      self.retcon_seq = changeset.applied_seq
      self.retcon_digest = Projection.digest(self)
      self.retcon_dirty = false
      result = Context.writing(&)
      rows = saved_changes.slice(*tracked).map do |field, (_from, to)|
        { record_id: id, op: 'set', field:, value: to, base_seq: heads[field]&.seq }
      end
      self.class.retcon_history.write(changeset, rows, applied: true)
      retcon_fix_digest
      @retcon_base = nil
      result
    end

    def retcon_around_destroy(&)
      return yield if retcon_skip?

      Drift.lock_and_catch_up(self)
      snapshot = attributes.except(*LIVE_COLUMNS).transform_values { |v| Value.dump(v) }
      row = { record_id: id, op: 'tombstone', field: nil, value: snapshot, base_seq: retcon_seq_in_database }
      changeset = Context.open.changeset(scope: self.class.retcon_config.scope_for(self))
      result = Context.writing(&)
      self.class.retcon_history.write(changeset, [row], applied: true)
      result
    end

    # Fields changed since this record's base: raise, or (on_conflict :skip) put them back and list them.
    def retcon_check_conflicts(heads, tracked)
      @retcon_conflicts = []
      changes_to_save.slice(*tracked).each do |field, (_from, to)|
        head = heads[field]
        base = retcon_base_for(field)
        next if head.nil? || base.nil? || head.seq <= base || Value.same?(head.value, Value.dump(to))
        # Without an explicit base, an editor who loaded the row after the change saw it: nothing of theirs is lost.
        next if @retcon_base.nil? && Value.same?(head.value, Value.dump(attribute_in_database(field)))

        @retcon_conflicts << FieldConflict.new(model: self.class.name, record_id: id, field:, base_seq: base,
                                               head_seq: head.seq, current: head.value, proposed: Value.dump(to))
      end
      return if @retcon_conflicts.empty?
      raise Conflict, @retcon_conflicts unless retcon_on_conflict == :skip

      @retcon_conflicts.each { |c| restore_attributes([c.field]) }
    end

    def retcon_base_for(field)
      case @retcon_base
      when Hash then @retcon_base[field] || @retcon_base[field.to_sym] || attribute_in_database('retcon_seq')
      when Integer then @retcon_base
      else attribute_in_database('retcon_seq')
      end
    end

    # App callbacks inside the save may have changed versioned fields after the digest was taken.
    def retcon_fix_digest
      digest = Projection.digest(self)
      return if digest == retcon_digest

      Context.writing { update_columns(retcon_digest: digest) }
    end
  end
end
