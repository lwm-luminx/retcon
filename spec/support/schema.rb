# frozen_string_literal: true

module RetconSpec
  # The tables the specs use: venues (uuid ids), events (bigint ids), links (edges) and Retcon's own.
  class Schema < ActiveRecord::Migration[7.1]
    include Retcon::Schema

    TABLES = %w[retcon_links retcon_events retcon_venues links events venues retcon_changesets retcon_actors].freeze

    def self.create!
      drop!
      new.migrate(:up)
    end

    def self.drop!
      conn = ActiveRecord::Base.connection
      TABLES.each { |t| conn.execute("DROP TABLE IF EXISTS #{t} CASCADE") }
      conn.execute('DROP SEQUENCE IF EXISTS retcon_seq')
      %w[venues events links].each { |t| conn.execute("DROP FUNCTION IF EXISTS retcon_mark_dirty_#{t}() CASCADE") }
    end

    def change
      enable_extension 'pgcrypto'
      create_retcon_tables
      create_table :venues, id: :uuid do |t|
        t.string :name, null: false
        t.string :phone
        t.string :tags, array: true, default: []
        t.jsonb :hours, default: {}
        t.date :opened_on
        t.integer :events_count, default: 0, null: false
        t.string :audience
        t.timestamps
      end
      create_table :events do |t|
        t.references :venue, type: :uuid, foreign_key: true
        t.string :name, null: false
        t.datetime :starts_at
        t.timestamps
      end
      create_table :links do |t|
        t.string :subject_type, null: false
        t.string :subject_id, null: false
        t.string :predicate, null: false
        t.string :object_type, null: false
        t.string :object_id, null: false
        t.string :role
        t.timestamps
      end
      add_index :links, %i[subject_type subject_id predicate object_type object_id], unique: true
      version_table :venues
      version_table :events
      version_table :links
    end
  end
end
