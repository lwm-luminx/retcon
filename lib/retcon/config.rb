# frozen_string_literal: true

module Retcon
  # A model's versioning settings, set in a `versioned do ... end` block:
  #
  #   class Venue < ApplicationRecord
  #     include Retcon::Model
  #
  #     versioned do
  #       ignore :view_count, :search_vector          # not versioned (timestamps and *_count already aren't)
  #       only :name, :address, :phone                # or name the versioned fields outright
  #       merge :tags, :set_union                     # merge strategy for proposals that touch the same field
  #       scope { |venue| venue.audience_id }         # the scope changesets about this record get
  #       schema_version 2
  #       rename_field :hours_text, :hours, before: 2 # upcaster for history written under version 1
  #       upcast(before: 2) { |field, value| [[field, value]] }
  #     end
  #   end
  class Config
    DEFAULT_IGNORED = %w[created_at updated_at lock_version].freeze
    MERGES = %i[replace set_union].freeze

    attr_reader :model, :merges, :upcasters

    def initialize(model)
      @model = model
      @ignored = []
      @only = nil
      @merges = {}
      @scope = nil
      @schema_version = 1
      @upcasters = []
    end

    def ignore(*fields) = @ignored.concat(fields.map(&:to_s))

    def only(*fields)
      @only = fields.map(&:to_s)
    end

    def merge(field, strategy)
      raise ArgumentError, "merge strategy must be one of #{MERGES.join(', ')}" unless MERGES.include?(strategy)

      @merges[field.to_s] = strategy
    end

    def scope(&block)
      @scope = block
    end

    def schema_version(version = nil)
      return @schema_version if version.nil?

      @schema_version = Integer(version)
    end

    # Converts history written under schema versions below before: the block takes (field, value) and returns
    # [[field, value], ...]: none to drop a field, several to split one.
    def upcast(before:, &block)
      @upcasters << [Integer(before), block]
      @upcasters.sort_by!(&:first)
    end

    def rename_field(from, to, before:)
      from = from.to_s
      upcast(before:) { |field, value| field == from ? [[to.to_s, value]] : [[field, value]] }
    end

    # The fields Retcon versions: every column but the primary key, Retcon's own, timestamps, lock_version, counter
    # caches (*_count) and the ones ignored; or the ones named with only.
    def tracked_fields
      @tracked_fields ||= begin
        columns = model.column_names - [model.primary_key] - LIVE_COLUMNS
        fields = @only || (columns.reject { |c| c.end_with?('_count') } - DEFAULT_IGNORED)
        fields - @ignored
      end
    end

    def reset! = @tracked_fields = nil

    def scope_for(record) = @scope&.call(record)&.to_s

    # A field and value written under schema_version, as they read under the current one: [[field, value], ...].
    def upcast_value(field, value, from_version)
      pairs = [[field, value]]
      upcasters.each do |before, block|
        next unless from_version < before

        pairs = pairs.flat_map { |f, v| block.call(f, v) }
      end
      pairs
    end
  end
end
