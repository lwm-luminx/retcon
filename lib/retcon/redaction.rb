# frozen_string_literal: true

module Retcon
  # Removing what history must not keep (privacy requests, DMCA, the right to be forgotten). The one place Retcon
  # changes history rows: it deletes their value and salt and keeps the commitment, so history still verifies but the
  # value is gone and a short one (a phone number) can't be guessed back from the commitment.
  #
  #   Retcon::Redaction.field(venue, :phone, actor: staff, reason: 'privacy request', remedy: nil)
  #   Retcon::Redaction.editor(actor, by: staff, reason: 'account deleted')
  #   Retcon::Redaction.erase(actor, by: deletion_job, reason: 'deletion request')
  #
  # Every redaction is a changeset (kind redaction) recording who, when, why and which rows: never what.
  module Redaction
    KEEP = Object.new.freeze

    module_function

    # Scrubs a field's values from every version (applied or proposed) of a record and from its tombstone
    # snapshots. value: only versions holding this value (default: every version). remedy: the live value afterwards
    # (written as a new version, so a rebuild lands on it); Redaction::KEEP leaves live alone (when the live value
    # is already clean). Returns the redaction changeset.
    def field(record, field, actor:, reason:, value: KEEP, remedy: nil)
      model = record.class
      field = field.to_s
      Retcon.changeset(actor:, kind: 'redaction', message: 'Redaction') do
        changeset = Context.open.changeset(scope: model.retcon_config.scope_for(record))
        history = model.retcon_history
        rows = history.where(record_id: record.id, field:, op: 'set', redacted_by_id: nil)
        rows = rows.to_a.select { |r| Value.same?(r.raw_value, value) } unless value.equal?(KEEP)
        ids = rows.map(&:id)
        history.where(id: ids).update_all(value: nil, salt: nil, redacted_by_id: changeset.id)
        snapshots = history.where(record_id: record.id, op: 'tombstone').where('value ? :f', f: field)
        snapshots.update_all(['value = value - ?', field])
        unless remedy.equal?(KEEP)
          heads = history.heads(record.id)
          if model.unscoped.exists?(model.primary_key => record.id)
            Projection.update(model, record.id, { field => remedy }, seq: changeset.applied_seq, validate: false)
          end
          history.write(changeset, [{ record_id: record.id, op: 'set', field:, value: remedy,
                                      base_seq: heads[field]&.seq }], applied: true)
        end
        changeset.update!(metadata: { 'reason' => reason, 'table' => model.table_name, 'record_id' => record.id,
                                      'field' => field, 'version_ids' => ids, 'snapshots' => snapshots.count })
        Retcon.instrument(:redacted, changeset:)
      end
    end

    # Replaces an editor's identity with a pseudonym. Their edits stay, grouped under the pseudonym for audit and
    # revert.
    def editor(target, by:, reason:)
      target = Actor.resolve(target)
      Retcon.changeset(actor: by, kind: 'redaction', message: 'Editor redaction',
                       metadata: { 'reason' => reason, 'actor_id' => target.id }) do
        Context.open.changeset
        target.pseudonymize!
      end
    end

    # An automated personal deletion request: reverts the requester's own changes, scrubs the values they wrote,
    # and pseudonymizes them. Anything else that may hold their data (later edits by others to the same fields)
    # comes back as a review proposal instead of being touched: a request can't wipe other people's work.
    # Returns the Revert::Result with the redaction changeset added: { revert:, review:, flagged:, redaction: }.
    def erase(target, by:, reason:)
      target = Actor.resolve(target)
      ActiveRecord::Base.transaction(requires_new: true) do
        result = Retcon.revert_actor(target, actor: by, message: 'Revert for deletion request')
        redaction = Retcon.changeset(actor: by, kind: 'redaction', message: 'Deletion request',
                                     metadata: { 'reason' => reason, 'actor_id' => target.id }) do
          changeset = Context.open.changeset
          authored = Changeset.where(author_id: target.id).select(:id)
          Retcon.models.each_value do |model|
            model.retcon_history.where(changeset_id: authored, op: 'set', redacted_by_id: nil)
                 .update_all(value: nil, salt: nil, redacted_by_id: changeset.id)
          end
          target.pseudonymize!
        end
        result.to_h.merge(redaction:)
      end
    end
  end
end
