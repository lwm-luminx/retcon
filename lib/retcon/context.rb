# frozen_string_literal: true

module Retcon
  # Per-thread (per-fiber, through ActiveSupport::IsolatedExecutionState) state: the actor, the changeset being
  # written, and whether Retcon is replaying history into live tables.
  module Context
    # An open changeset: created on the first write, so a block that changes nothing leaves no changeset behind.
    class Open
      attr_reader :actor, :message, :scope, :kind, :metadata

      def initialize(actor:, message:, scope:, kind:, metadata:)
        @actor = actor
        @message = message
        @scope = scope
        @kind = kind
        @metadata = metadata
      end

      def changeset(scope: nil)
        @changeset ||= Changeset.create!(author: actor, kind:, message:, scope: @scope || scope, metadata:,
                                         state: 'applied', applied_seq: Retcon.next_seq, applied_at: Time.current)
      end

      def created = @changeset

      def seq = changeset.applied_seq
    end

    module_function

    def state = ActiveSupport::IsolatedExecutionState[:retcon] ||= {}

    def actor = state[:actor]

    def with(actor:)
      before = state[:actor]
      state[:actor] = actor
      yield
    ensure
      state[:actor] = before
    end

    def open = state[:open]

    # Runs the block in a transaction with an open changeset (joining the one already open, if any). Returns the
    # Changeset written, or nil.
    def changeset(actor:, message:, scope:, kind:, metadata:, &)
      run(actor:, message:, scope:, kind:, metadata:, &).last
    end

    # The changeset a save writes into: the open one, or a new one around the block. Returns the block's value, so
    # save, save! and destroy keep returning what Active Record returns.
    def implicit(&)
      return yield if open

      run(actor: nil, message: nil, scope: nil, kind: 'edit', metadata: {}, &).first
    end

    # [block's value, Changeset written or nil].
    def run(actor:, message:, scope:, kind:, metadata:)
      return [yield, open.created] if open

      actor ||= self.actor || fallback_actor
      opened = Open.new(actor:, message:, scope:, kind:, metadata:)
      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        state[:open] = opened
        result = yield
      ensure
        state[:open] = nil
      end
      [result, opened.created]
    end

    def fallback_actor
      raise Error, 'no actor: wrap changes in Retcon.as(actor) { ... }' unless Retcon.allow_unattributed?

      Actor.system
    end

    def replaying? = state[:replaying] == true

    def replaying
      before = state[:replaying]
      state[:replaying] = true
      yield
    ensure
      state[:replaying] = before
    end

    # Tells the dirty trigger that the writes in the block are Retcon's own.
    def writing(connection = Retcon.connection)
      connection.execute("SELECT set_config('retcon.writing', 'on', true)")
      yield
    ensure
      begin
        connection.execute("SELECT set_config('retcon.writing', 'off', true)") if connection.transaction_open?
      rescue ActiveRecord::StatementInvalid
        nil # the transaction is failing anyway; the setting ends with it
      end
    end
  end
end
