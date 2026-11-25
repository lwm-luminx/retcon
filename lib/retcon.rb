# frozen_string_literal: true

require 'active_record'
require 'active_support/concern'
require 'active_support/notifications'
require 'securerandom'
require 'digest'
require 'json'
require 'pg'
require 'retcon/version'

# VCS-style history for Active Record on PostgreSQL.
#
# Every versioned table gets a history table of immutable field-level versions. Live tables stay where they are and
# stay as fast as they were: they are a projection of history, written in the same transaction, and can be rebuilt
# from it. Changes are grouped in changesets with an actor; a proposal is a changeset that hasn't been applied yet.
#
#   class Venue < ApplicationRecord
#     include Retcon::Model
#   end
#
#   Retcon.as(current_user) { venue.update!(name: 'The Eagle') }        # an applied changeset, attributed
#   proposal = Retcon.propose(actor: member) { |p| p.update(venue, phone: '555-0100') }
#   proposal.apply!(committer: reviewer)                                   # or reject!, amend
#   Retcon.revert_actor(vandal, actor: staff)                              # drops their changes, keeps later work
#
# See README.md and docs/.
module Retcon
  class Error < StandardError; end
  # A model or table isn't set up for Retcon (missing history table or columns).
  class NotVersioned < Error; end
  # A changeset can't move to the state asked for (applying a rejected proposal, say).
  class InvalidState < Error; end
  # The policy refused a change.
  class Denied < Error; end

  # Fields changed by someone else since the base version the edit started from.
  class Conflict < Error
    attr_reader :conflicts

    # conflicts: [Retcon::FieldConflict, ...]
    def initialize(conflicts)
      @conflicts = conflicts
      fields = conflicts.map { |c| "#{c.model}##{c.record_id}.#{c.field}" }.join(', ')
      super("changed since the base version: #{fields}")
    end
  end

  # A record would be invalid after applying a changeset to it.
  class Invalid < Error
    attr_reader :record

    def initialize(record)
      @record = record
      super("#{record.class.name} #{record.id} is invalid: #{record.errors.full_messages.join(', ')}")
    end
  end

  # One field that conflicts: what the edit expected (its base), what is there now, and what the edit wanted.
  FieldConflict = Data.define(:model, :record_id, :field, :base_seq, :head_seq, :current, :proposed)

  autoload :Actor, 'retcon/actor'
  autoload :Bulk, 'retcon/bulk'
  autoload :Changeset, 'retcon/changeset'
  autoload :Config, 'retcon/config'
  autoload :Context, 'retcon/context'
  autoload :Drift, 'retcon/drift'
  autoload :Edge, 'retcon/edge'
  autoload :History, 'retcon/history'
  autoload :Model, 'retcon/model'
  autoload :Projection, 'retcon/projection'
  autoload :Proposal, 'retcon/proposal'
  autoload :Redaction, 'retcon/redaction'
  autoload :Revert, 'retcon/revert'
  autoload :Schema, 'retcon/schema'
  autoload :Value, 'retcon/value'

  # Columns Retcon keeps on every versioned live table.
  LIVE_COLUMNS = %w[retcon_seq retcon_digest retcon_dirty].freeze

  class << self
    # Decides whether an edit made with Retcon.edit commits, becomes a proposal or is refused:
    #   Retcon.policy = ->(actor, record, changes) { actor.trusted? ? :commit : :propose }
    # changes: {field => [from, to]}. Returns :commit, :propose or :deny. Defaults to :commit.
    attr_writer :policy

    def policy = @policy || ->(_actor, _record, _changes) { :commit }

    # Whether saves with no actor set (Retcon.as) are allowed; they are attributed to Actor.system. Defaults to true.
    attr_writer :allow_unattributed

    def allow_unattributed? = @allow_unattributed.nil? || @allow_unattributed

    # Runs the block with actor as the author of every change made in it. actor: an Actor, or any record (a User,
    # a device), which gets an Actor of its own. on_behalf_of: who an agent acts for.
    def as(actor, on_behalf_of: nil, &)
      Context.with(actor: Actor.resolve(actor, on_behalf_of:), &)
    end

    # The actor changes are attributed to right now (nil outside Retcon.as).
    def actor = Context.actor

    # Groups every change made in the block into one applied changeset, in one database transaction. Returns the
    # Changeset (nil if nothing changed).
    def changeset(actor: nil, message: nil, scope: nil, kind: 'edit', metadata: {}, &)
      Context.changeset(actor: actor && Actor.resolve(actor), message:, scope:, kind:, metadata:, &)
    end

    # Opens a proposal: the block gets a Proposal::Builder to record updates, creates and destroys without touching
    # live tables. Returns the proposed Changeset.
    def propose(actor: Context.actor, message: nil, scope: nil, metadata: {}, &)
      Proposal.build(actor: Actor.resolve(actor || raise(ArgumentError, 'a proposal needs an actor')),
                     message:, scope:, metadata:, &)
    end

    # Edits a record through the policy: commits, opens a proposal, or raises Denied. Returns the Changeset.
    def edit(record, attributes, actor: Context.actor, message: nil, base: nil)
      actor = Actor.resolve(actor || raise(ArgumentError, 'an edit needs an actor'))
      record.assign_attributes(attributes)
      changes = record.changes_to_save.slice(*record.class.retcon_config.tracked_fields)
      decision = policy.call(actor, record, changes)
      case decision
      when :commit
        record.retcon_base = base if base
        changeset(actor:, message:) { record.save! }
      when :propose
        record.restore_attributes(changes.keys)
        propose(actor:, message:) { |p| p.update(record, changes.transform_values(&:last), base:) }
      when :deny then raise Denied, "#{actor.label} may not change #{record.class.name} #{record.id}"
      else raise ArgumentError, "policy returned #{decision.inspect}, not :commit, :propose or :deny"
      end
    end

    # Reverts changesets: see Retcon::Revert.
    def revert(changesets, actor:, message: nil)
      Revert.new(Array(changesets), actor: Actor.resolve(actor),
                                    message:).run
    end

    # Reverts every applied changeset an actor authored (since a time, in a scope): see Retcon::Revert.
    def revert_actor(target, actor:, since: nil, scope: nil, message: nil)
      target = Actor.resolve(target)
      sets = Changeset.applied.where(author_id: target.id).where.not(kind: %w[revert redaction])
      sets = sets.where(applied_at: since..) if since
      sets = sets.where(scope:) if scope
      revert(sets.to_a, actor:, message: message || "Revert changes by #{target.label}")
    end

    # Writes in the block skip history (bulk fixes, migrations). The dirty trigger still marks the rows, so the next
    # Retcon::Drift sweep records them as untracked changes; use Retcon::Bulk to keep attribution instead.
    def bypass
      before = Context.state[:bypass]
      Context.state[:bypass] = true
      yield
    ensure
      Context.state[:bypass] = before
    end

    # Checks that history rebuilds the live rows: compares a sample of live rows' versioned fields with what history
    # says. Returns mismatches as [[record_id, field, live, history], ...]; empty means they agree.
    def verify(model, sample: 100)
      model.unscoped.order(Arel.sql('random()')).limit(sample).flat_map do |record|
        state = model.retcon_state(record.id)
        next [[record.id, nil, 'live', 'no history']] if state.nil? || !state['exists']

        model.retcon_config.tracked_fields.filter_map do |field|
          live = Value.dump(record.read_attribute(field))
          kept = state['attributes'][field]
          [record.id, field, live, kept] unless Value.same?(live, kept)
        end
      end
    end

    # Runs the block with model callbacks for side effects told it is a replay (approval, revert, rebuild).
    def replaying? = Context.replaying?

    # Publishes an event (proposal_opened, changeset_applied, proposal_rejected, revert_conflict, redacted) as
    # "<name>.retcon" through ActiveSupport::Notifications.
    def instrument(name, payload = {}) = ActiveSupport::Notifications.instrument("#{name}.retcon", payload)

    # Subscribes to a Retcon event: Retcon.on(:proposal_opened) { |changeset| route(changeset) }.
    def on(name, &block)
      ActiveSupport::Notifications.subscribe("#{name}.retcon") { |*, payload| block.call(payload[:changeset]) }
    end

    # Every model that includes Retcon::Model, by name.
    def models = @models ||= {}

    def model_for(name) = models[name.to_s] || name.to_s.constantize

    def connection = ActiveRecord::Base.connection

    # The next number in Retcon's global order of application.
    def next_seq = connection.select_value("SELECT nextval('retcon_seq')").to_i
  end
end
