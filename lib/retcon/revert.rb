# frozen_string_literal: true

module Retcon
  # Reverts changesets the way an interactive rebase drops commits, without rewriting history: one new revert
  # changeset puts back what the dropped changesets replaced, and later work by others stays.
  #
  # For each field the dropped changesets set:
  # - if a dropped changeset wrote its current value, it goes back to the newest value nobody dropped wrote (nil if
  #   none);
  # - if someone else changed it afterwards, their value stays, and a proposal to restore the earlier value goes to
  #   review (same-field overlap).
  # Records the dropped changesets created are tombstoned, records they tombstoned are revived. Committers who
  # applied a dropped changeset someone else wrote are flagged, for whoever cleans up.
  #
  #   result = Retcon.revert_actor(vandal, actor: staff)
  #   result.revert      # the applied revert changeset (nil if nothing to undo)
  #   result.review      # a proposal with the overlaps (nil if none)
  #   result.flagged     # [Actor] who approved the vandal's proposals
  class Revert
    Result = Data.define(:revert, :review, :flagged)

    def initialize(changesets, actor:, message: nil)
      @targets = changesets.select(&:applied?)
      @ids = @targets.map(&:id)
      @actor = actor
      @message = message || "Revert #{@ids.map { |i| "##{i}" }.join(', ')}"
    end

    def run
      return Result.new(revert: nil, review: nil, flagged: []) if @targets.empty?

      review_rows = Hash.new { |h, k| h[k] = [] }
      revert = Retcon.changeset(actor: @actor, message: @message, kind: 'revert',
                                metadata: { 'reverts' => @ids }) do
        Retcon.models.each_value { |model| revert_model(model, review_rows) }
      end
      review = review_proposal(revert, review_rows)
      Retcon.instrument(:revert_conflict, changeset: review) if review
      Result.new(revert:, review:, flagged:)
    end

    # Puts a tombstoned record back into its live table, inside changeset.
    def self.revive(model, record_id, changeset)
      raise Error, "#{model.name} #{record_id} is live" if model.unscoped.exists?(model.primary_key => record_id)

      history = model.retcon_history
      tomb = history.applied.where(record_id:, op: 'tombstone').order(seq: :desc, id: :desc).first or
        raise Error, "#{model.name} #{record_id} was never tombstoned"
      attributes = (tomb.value || {}).merge(history.heads(record_id).transform_values(&:value))
      Projection.insert(model, record_id, attributes, seq: changeset.applied_seq)
      history.write(changeset, [{ record_id:, op: 'revive', field: nil, value: nil, base_seq: tomb.seq }],
                    applied: true)
    end

    private

    def revert_model(model, review_rows)
      history = model.retcon_history
      touched = history.applied.where(changeset_id: @ids).distinct.pluck(:record_id)
      touched.each { |record_id| revert_record(model, record_id, review_rows) }
    end

    def revert_record(model, record_id, review_rows)
      history = model.retcon_history
      changeset = Context.open.changeset
      rows = history.applied.where(record_id:).order(:seq, :id).to_a
      life = rows.select { |r| History::LIFECYCLE.include?(r.op) }.last

      if life && @ids.include?(life.changeset_id)
        case life.op
        when 'create', 'revive'
          return tombstone(model, record_id, changeset) if model.unscoped.exists?(model.primary_key => record_id)
        when 'tombstone'
          Revert.revive(model, record_id, changeset)
        end
      end
      return unless model.unscoped.exists?(model.primary_key => record_id)

      restore_fields(model, record_id, rows, changeset, review_rows)
    end

    def restore_fields(model, record_id, rows, changeset, review_rows)
      sets = rows.select { |r| r.op == 'set' }.group_by(&:field)
      restore = {}
      sets.each do |field, versions|
        dropped = versions.select { |v| @ids.include?(v.changeset_id) }
        next if dropped.empty?

        kept = versions.reject { |v| @ids.include?(v.changeset_id) }
        head = versions.last
        if @ids.include?(head.changeset_id)
          restore[field] = kept.last&.raw_value
        else
          earlier = kept.select { |v| v.seq < dropped.first.seq }.last&.raw_value
          next if Value.same?(earlier, head.raw_value)

          review_rows[model] << { record_id:, op: 'set', field:, value: earlier, base_seq: head.seq }
        end
      end
      return if restore.empty?

      heads = model.retcon_history.heads(record_id)
      Projection.update(model, record_id, restore, seq: changeset.applied_seq, validate: false)
      model.retcon_history.write(changeset, restore.map do |field, value|
        { record_id:, op: 'set', field:, value:, base_seq: heads[field]&.seq }
      end, applied: true)
    end

    def tombstone(model, record_id, changeset)
      record = model.unscoped.find(record_id)
      snapshot = record.attributes.except(*LIVE_COLUMNS).transform_values { |v| Value.dump(v) }
      Projection.delete(model, record_id)
      model.retcon_history.write(changeset, [{ record_id:, op: 'tombstone', field: nil, value: snapshot,
                                               base_seq: record.retcon_seq }], applied: true)
    end

    def review_proposal(revert, review_rows)
      return nil if review_rows.values.all?(&:empty?)

      Proposal.build(actor: @actor, message: "Review overlaps left by #{revert ? "revert ##{revert.id}" : 'a revert'}",
                     scope: nil, metadata: { 'reverts' => @ids, 'revert_id' => revert&.id }, parent: revert) do |b|
        review_rows.each { |model, rows| b.rows[model].concat(rows) }
      end
    end

    def flagged
      @targets.select { |c| c.committer_id && c.committer_id != c.author_id }.map(&:committer).uniq
    end
  end
end
