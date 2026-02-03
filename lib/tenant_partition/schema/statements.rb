# frozen_string_literal: true

module TenantPartition
  module Schema
    # Módulo que extiende ActiveRecord::Migration con DSL para particionamiento.
    module Statements
      # Crea una tabla particionada por lista y su tabla DEFAULT asociada.
      # Configura automáticamente Primary Keys Compuestas para compatibilidad con Postgres.
      #
      # @param table_name [Symbol] Nombre de la tabla.
      # @param options [Hash] Opciones de migración estándar.
      # @option options [Symbol] :partition_key Clave opcional para sobreescribir la global.
      # @yield [t] Bloque de definición de tabla (ActiveRecord::ConnectionAdapters::TableDefinition).
      def create_partitioned_table(table_name, **options, &block)
        key = options.delete(:partition_key) || TenantPartition.configuration&.partition_key
        raise TenantPartition::Error, "Falta 'partition_key'." unless key

        configure_pk_and_options(options, key)

        create_table(table_name, **options) do |t|
          setup_partitioning(t, key, block)
        end

        create_default_partition(table_name)
      end

      # Elimina una tabla particionada en cascada.
      # @param table_name [Symbol] Nombre de la tabla.
      def drop_partitioned_table(table_name)
        drop_table(table_name, cascade: true)
      end

      private

      # Configura las columnas y definiciones dentro del bloque create_table.
      def setup_partitioning(table, key, block)
        table.uuid :id, null: false, default: -> { "gen_random_uuid()" }
        block.call(table)
        ensure_partition_column(table, key)
      end

      # Prepara las opciones de PK compuesta y tipo de partición.
      def configure_pk_and_options(options, key)
        options[:id] = false
        options[:primary_key] = [:id, key]
        options[:options] = "PARTITION BY LIST (#{key})"
      end

      # Asegura que la columna de partición exista si el usuario olvidó definirla.
      def ensure_partition_column(table, key)
        return if table.columns.any? { |c| c.name == key.to_s }

        table.column key, :string, null: false
      end

      # Crea la tabla _default para capturar datos sin partición asignada.
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
