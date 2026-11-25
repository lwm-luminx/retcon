# frozen_string_literal: true

module Retcon
  # Who made a change. History stores only actor ids, so pseudonymizing an editor rewrites one row here and nothing in
  # history. An actor stands for a record (a User, a device grant), or is named (an import, a system job), and an agent
  # can act on behalf of another actor.
  class Actor < ActiveRecord::Base
    self.table_name = 'retcon_actors'

    KINDS = %w[user device import research system untracked agent].freeze

    belongs_to :on_behalf_of, class_name: 'Retcon::Actor', optional: true
    has_many :changesets, class_name: 'Retcon::Changeset', foreign_key: :author_id, inverse_of: :author,
                          dependent: :restrict_with_exception

    validates :kind, inclusion: { in: KINDS }

    class << self
      # An Actor for anything: an Actor, a record (found or created by type and id), or a String naming a system.
      # kind: overrides the kind given to a new record actor (user by default, or what Retcon.kind_for says).
      def resolve(thing, on_behalf_of: nil, kind: nil)
        on_behalf_of &&= resolve(on_behalf_of)
        actor = case thing
                when Actor then thing
                when nil then return nil
                when String, Symbol then named('system', thing.to_s)
                when ActiveRecord::Base then for_record(thing, kind:)
                else raise ArgumentError, "can't attribute changes to #{thing.inspect}"
                end
        return actor unless on_behalf_of

        identity(kind: 'agent', ref_type: actor.ref_type, ref_id: actor.ref_id, name: actor.name,
                 on_behalf_of_id: on_behalf_of.id)
      end

      def for_record(record, kind: nil)
        identity(kind: kind || kind_for(record), ref_type: record.class.polymorphic_name, ref_id: record.id.to_s)
      end

      # A named actor of a kind: Actor.named('import', 'facebook sync').
      def named(kind, name) = identity(kind:, name:)

      # Changes no one claims: saves made with no actor set, when Retcon.allow_unattributed is on.
      def system = named('system', 'unattributed')

      # Writes Retcon found but didn't make (Retcon::Drift).
      def untracked = named('untracked', 'untracked change')

      # Kind for a new record actor: set Retcon::Actor.kinds = { 'VenueDeviceGrant' => 'device' }.
      attr_writer :kinds

      def kinds = @kinds ||= {}

      def kind_for(record) = kinds.fetch(record.class.polymorphic_name, 'user')

      private

      def identity(kind:, ref_type: nil, ref_id: nil, name: nil, on_behalf_of_id: nil)
        attrs = { kind:, ref_type:, ref_id:, on_behalf_of_id: }
        attrs[:name] = name if ref_type.nil?
        live = where(redacted_at: nil)
        live.find_by(attrs) || transaction(requires_new: true) { create!(attrs.merge(name:)) }
      rescue ActiveRecord::RecordNotUnique
        live.find_by!(attrs)
      end
    end

    # The record this actor stands for, if it still does.
    def record = ref_type && ref_id && ref_type.safe_constantize&.find_by(id: ref_id)

    def redacted? = redacted_at.present?

    # How to show this actor: its pseudonym once redacted.
    def label
      return pseudonym if redacted?

      base = name || "#{ref_type} #{ref_id}"
      on_behalf_of ? "#{base} for #{on_behalf_of.label}" : base
    end

    # Replaces identity with a stable pseudonym; every edit stays and stays grouped under this actor.
    def pseudonymize!(pseudonym: "editor-#{SecureRandom.hex(4)}")
      update!(ref_type: nil, ref_id: nil, name: nil, pseudonym:, redacted_at: Time.current)
    end
  end
end
