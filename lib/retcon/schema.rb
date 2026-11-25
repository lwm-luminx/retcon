# frozen_string_literal: true

module Retcon
  # Migration helpers, available in migrations as Retcon::Schema methods (include it, or call
  # Retcon::Schema.install(self)):
  #
  #   class InstallRetcon < ActiveRecord::Migration[8.0]
  #     include Retcon::Schema
  #
  #     def change
  #       create_retcon_tables                # retcon_actors, retcon_changesets, the retcon_seq sequence
  #       version_table :venues               # retcon_venues history + live columns + the dirty trigger
  #     end
  #   end
  module Schema
    # The history table for a live table.
    def self.history_table(table) = "retcon_#{table}"

    def create_retcon_tables
      reversible do |dir|
        dir.up { execute 'CREATE SEQUENCE IF NOT EXISTS retcon_seq' }
        dir.down { execute 'DROP SEQUENCE IF EXISTS retcon_seq' }
      end

      create_table :retcon_actors do |t|
        t.string :kind, null: false, comment: 'user, device, import, research, system, untracked or agent'
        t.string :ref_type, comment: 'The record this actor stands for (User, a device grant); null once redacted'
        t.string :ref_id
        t.string :name, comment: 'A display name, for imports and systems; null once redacted'
        t.string :pseudonym, comment: 'Shown instead of the actor once redacted'
        t.references :on_behalf_of, foreign_key: { to_table: :retcon_actors }, comment: 'Who an agent acts for'
        t.datetime :redacted_at
        t.timestamps
      end
      add_index :retcon_actors, %i[kind ref_type ref_id name on_behalf_of_id], unique: true, nulls_not_distinct: true,
                                                                               where: 'redacted_at IS NULL',
                                                                               name: 'index_retcon_actors_identity'

      create_table :retcon_changesets do |t|
        t.string :kind, null: false, default: 'edit',
                        comment: 'edit, proposal, genesis, catch_up, revert, redaction, merge or import'
        t.string :state, null: false, default: 'applied',
                         comment: 'applied, proposed, rejected, withdrawn, amended or superseded'
        t.string :scope, comment: 'The tenant it belongs to (an audience, say); policy decides what it means'
        t.references :author, null: false, foreign_key: { to_table: :retcon_actors }
        t.references :committer, foreign_key: { to_table: :retcon_actors }, comment: 'Who applied or decided it'
        t.references :parent, foreign_key: { to_table: :retcon_changesets }, comment: 'Amended or grouped under'
        t.bigint :applied_seq, comment: 'Its place in the order of application (retcon_seq)'
        t.text :message
        t.jsonb :metadata, null: false, default: {}
        t.datetime :applied_at
        t.datetime :decided_at
        t.timestamps
      end
      add_index :retcon_changesets, :applied_seq, unique: true
      add_index :retcon_changesets, %i[state scope]
    end

    # Versions a live table: creates its history table, adds the live columns Retcon keeps, and installs the trigger
    # that marks rows written outside Retcon as dirty. id_type: the live table's primary key type.
    def version_table(table, id_type: nil)
      id_type ||= primary_key_type(table)
      history = Schema.history_table(table)
      create_table history do |t|
        t.bigint :changeset_id, null: false
        t.column :record_id, id_type, null: false
        t.string :op, null: false, comment: 'set, create, tombstone or revive'
        t.string :field, comment: 'For set: the field'
        t.jsonb :value, comment: 'set: {"v": value}; tombstone: the row as it was; null once redacted'
        t.string :salt, comment: 'Random salt of the commitment; null once redacted'
        t.string :commitment, comment: 'SHA-256 of salt and value, kept after redaction'
        t.boolean :applied, null: false, default: false
        t.bigint :seq, comment: 'retcon_seq when applied'
        t.bigint :base_seq, comment: 'The field head the change was made against'
        t.integer :schema_version, null: false, default: 1
        t.bigint :redacted_by_id, comment: 'The redaction changeset that scrubbed this value'
        t.datetime :created_at, null: false
      end
      add_foreign_key history, :retcon_changesets, column: :changeset_id
      add_index history, %i[record_id field seq], name: "index_#{history}_head"
      add_index history, :changeset_id
      add_index history, :value, using: :gin, opclass: :jsonb_path_ops, where: "op = 'tombstone'",
                                 name: "index_#{history}_tombstones"

      add_column table, :retcon_seq, :bigint
      add_column table, :retcon_digest, :string
      add_column table, :retcon_dirty, :boolean, null: false, default: false
      add_index table, :retcon_dirty, where: 'retcon_dirty'
      add_retcon_dirty_trigger(table)
    end

    # A trigger that sets retcon_dirty on rows inserted or updated without Retcon (insert_all, update_all, SQL, the
    # console), so Retcon::Drift only has to look at those rows.
    def add_retcon_dirty_trigger(table)
      function = "retcon_mark_dirty_#{table}"
      reversible do |dir|
        dir.up do
          execute <<~SQL.squish
            CREATE OR REPLACE FUNCTION #{function}() RETURNS trigger AS $$
            BEGIN
              IF current_setting('retcon.writing', true) IS DISTINCT FROM 'on' THEN
                NEW.retcon_dirty := true;
              END IF;
              RETURN NEW;
            END $$ LANGUAGE plpgsql
          SQL
          execute "CREATE TRIGGER #{function} BEFORE INSERT OR UPDATE ON #{quote_table_name(table)} " \
                  "FOR EACH ROW EXECUTE FUNCTION #{function}()"
        end
        dir.down do
          execute "DROP TRIGGER IF EXISTS #{function} ON #{quote_table_name(table)}"
          execute "DROP FUNCTION IF EXISTS #{function}()"
        end
      end
    end

    private

    def primary_key_type(table)
      pk = connection.primary_key(table) || 'id'
      column = connection.columns(table).find { |c| c.name == pk }
      column&.type || :bigint
    end
  end
end
