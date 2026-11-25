# frozen_string_literal: true

module Retcon
  # One logical change: version rows across any number of records and tables, with an author and (once someone
  # applies or decides it) a committer. A direct edit is an applied changeset; a proposal is a proposed one, applied
  # later through #apply!. Changesets are never deleted; reverts and redactions are changesets too.
  class Changeset < ActiveRecord::Base
    self.table_name = 'retcon_changesets'

    KINDS = %w[edit proposal genesis catch_up revert redaction merge import].freeze
    STATES = %w[applied proposed rejected withdrawn amended superseded].freeze

    belongs_to :author, class_name: 'Retcon::Actor'
    belongs_to :committer, class_name: 'Retcon::Actor', optional: true
    belongs_to :parent, class_name: 'Retcon::Changeset', optional: true
    has_many :children, class_name: 'Retcon::Changeset', foreign_key: :parent_id, inverse_of: :parent,
                        dependent: :restrict_with_exception

    validates :kind, inclusion: { in: KINDS }
    validates :state, inclusion: { in: STATES }

    scope :applied, -> { where(state: 'applied') }
    scope :proposed, -> { where(state: 'proposed') }
    scope :in_order, -> { order(:applied_seq) }

    STATES.each { |state| define_method(:"#{state}?") { self.state == state } }

    # Every version row in this changeset, across all versioned tables: [History row, ...] in write order.
    def versions
      Retcon.models.values.flat_map { |model| model.retcon_history.where(changeset_id: id).order(:id).to_a }
    end

    # The records this changeset touched: [[model, record_id], ...].
    def records
      Retcon.models.values.flat_map do |model|
        model.retcon_history.where(changeset_id: id).distinct.pluck(:record_id).map { |rid| [model, rid] }
      end
    end

    # {[model, record_id] => {field => value}} that this changeset sets, for showing a diff.
    def changes
      versions.select { |v| v.op == 'set' }.group_by { |v| [v.class.live_model, v.record_id] }
              .transform_values { |rows| rows.to_h { |v| [v.field, v.current_value] } }
    end

    # Applies a proposal: checks every field against its base, writes live rows (validated, without callbacks) and
    # marks the version rows applied, all in one transaction. on_conflict: :raise (Retcon::Conflict, nothing
    # applied) or :skip (applies the fields that don't conflict and returns the conflicts).
    def apply!(committer:, on_conflict: :raise)
      Proposal.apply(self, committer: Actor.resolve(committer),
                           on_conflict:)
    end

    # Rejects a proposal. reason goes to metadata.
    def reject!(by:, reason: nil) = decide!('rejected', by:, reason:, event: :proposal_rejected)

    # The author takes the proposal back.
    def withdraw!(by: author) = decide!('withdrawn', by:)

    # Replaces a proposal with an amended one: the block gets a Proposal::Builder pre-filled with this proposal's
    # changes. The new proposal keeps this author, names by as committer and points here as its parent.
    def amend!(by:, message: self.message, &) = Proposal.amend(self, by: Actor.resolve(by), message:, &)

    # Undoes this changeset (see Retcon::Revert).
    def revert!(actor:, message: nil) = Retcon.revert(self, actor:, message:)

    def decide!(state, by:, reason: nil, event: nil)
      raise InvalidState, "changeset #{id} is #{self.state}, not proposed" unless proposed?

      update!(state:, committer: Actor.resolve(by), decided_at: Time.current,
              metadata: reason ? metadata.merge('reason' => reason) : metadata)
      Retcon.instrument(event, changeset: self) if event
      self
    end
  end
end
