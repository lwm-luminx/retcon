# frozen_string_literal: true

module Retcon
  # Edges as versioned rows: semantic triples (subject, predicate, object) whose identity is the triple, kept unique
  # by an index. Removing an edge tombstones it like any record; linking the same triple again revives that row, with
  # its id and its whole history, instead of starting a new one.
  #
  #   class EntityLink < ApplicationRecord
  #     include Retcon::Edge
  #     retcon_triple subject: %i[item_type item_id], predicate: :predicate, object: %i[target_type target_id],
  #                   discriminator: :slot                 # optional: lets one triple appear more than once
  #   end
  #
  #   EntityLink.link!(episode, :recorded_at, event, status: 'linked')   # creates, updates or revives
  #   EntityLink.unlink!(episode, :recorded_at, event)                   # tombstones
  #
  # Because removed edges leave the live table, graph_query (and any other reader) walks only live edges.
  module Edge
    extend ActiveSupport::Concern

    included do
      include Retcon::Model
    end

    class_methods do
      # Names the columns that hold the subject, predicate and object. A polymorphic end is [type_column, id_column];
      # a plain end is an id column (its records' class is then taken as given).
      def retcon_triple(subject:, predicate:, object:, discriminator: nil)
        @retcon_triple = { subject: Array(subject).map(&:to_s), predicate: predicate.to_s,
                           object: Array(object).map(&:to_s), discriminator: discriminator&.to_s }
      end

      def retcon_triple_columns
        @retcon_triple or raise Error, "#{name} has no retcon_triple"
      end

      # The identifying attributes of a triple: { 'item_type' => 'MediaEpisode', 'item_id' => ..., ... }.
      def retcon_identity(subject, predicate, object, discriminator: nil)
        cols = retcon_triple_columns
        attrs = end_attributes(cols[:subject], subject).merge(cols[:predicate] => predicate.to_s)
                                                       .merge(end_attributes(cols[:object], object))
        attrs[cols[:discriminator]] = discriminator if cols[:discriminator]
        attrs.to_h { |col, value| [col, type_for_attribute(col).cast(value)] }
      end

      # Makes sure the edge exists with these attributes: updates a live one, revives a removed one (keeping its id
      # and history), or creates it. Attributes go as a Hash or as keywords. Returns the record.
      def link!(subject, predicate, object, attributes = nil, discriminator: nil, **fields)
        attributes ||= fields
        identity = retcon_identity(subject, predicate, object, discriminator:)
        Context.implicit do
          record = unscoped.find_by(identity)
          unless record
            tomb = retcon_history.tombstone_matching(identity)
            record = tomb ? retcon_revive!(tomb.record_id) : new(identity)
          end
          record.assign_attributes(attributes)
          record.save! if record.new_record? || record.changed?
          record
        end
      end

      # Removes the edge (a tombstone). Returns the removed record, or nil when there was none.
      def unlink!(subject, predicate, object, discriminator: nil)
        record = unscoped.find_by(retcon_identity(subject, predicate, object, discriminator:))
        record&.destroy!
      end

      private

      def end_attributes(columns, node)
        if columns.size == 2
          { columns[0] => node.class.polymorphic_name, columns[1] => node.id }
        else
          { columns[0] => node.respond_to?(:id) ? node.id : node }
        end
      end
    end
  end
end
