# frozen_string_literal: true

module TenantPartition
  module Schema
    # Extensión para ActiveRecord::Migration que agrega DSL para particionamiento.
    module Statements
      # Crea una tabla particionada por lista y su tabla DEFAULT asociada.
      # Configura automáticamente Primary Keys Compuestas.
      #
      # @param table_name [Symbol] Nombre de la tabla.
      # @param options [Hash] Opciones de migración.
      def create_partitioned_table(table_name, **options, &block)
        key = options.delete(:partition_key) || TenantPartition.configuration&.partition_key

        unless key
          raise TenantPartition::Error, "Debe configurar 'partition_key' globalmente o pasarlo como opción."
        end

        configure_pk_and_options(options, key)

        create_table(table_name, **options) do |t|
          t.uuid :id, null: false, default: -> { "gen_random_uuid()" }
          block.call(t)
          ensure_partition_column(t, key)
        end

        create_default_partition(table_name)
      end

      # Elimina una tabla particionada en cascada.
      def drop_partitioned_table(table_name)
        drop_table(table_name, cascade: true)
      end

      private

      def configure_pk_and_options(options, key)
        options[:id] = false
        options[:primary_key] = [:id, key]
        options[:options] = "PARTITION BY LIST (#{key})"
      end

      def ensure_partition_column(table_definition, key)
        return if table_definition.columns.any? { |c| c.name == key.to_s }

        table_definition.column key, :string, null: false
      end

      def create_default_partition(table_name)
        default_name = "#{table_name}_default"
        execute <<-SQL.squish
          CREATE TABLE IF NOT EXISTS #{default_name}
          PARTITION OF #{table_name} DEFAULT;
        SQL
      end
    end
  end
end
