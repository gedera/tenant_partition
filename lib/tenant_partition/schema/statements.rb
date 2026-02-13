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
      # @option options [Symbol] :id_type Tipo de ID (:uuid o :bigint). Default: :bigint.
      # @yield [t] Bloque de definición de tabla (ActiveRecord::ConnectionAdapters::TableDefinition).
      def create_partitioned_table(table_name, **options, &block)
        key = options.delete(:partition_key) || TenantPartition.configuration&.partition_key
        id_type = options.delete(:id_type) || :bigint # Default conservador (BigInt)

        raise TenantPartition::Error, "Falta 'partition_key'." unless key

        configure_pk_and_options(options, key)

        create_table(table_name, **options) do |t|
          setup_partitioning(t, key, id_type, block)
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
      def setup_partitioning(table, key, id_type, block)
        # Definimos la ID según la preferencia del usuario
        if id_type == :uuid
          table.uuid :id, null: false, default: -> { "gen_random_uuid()" }
        else
          table.bigserial :id, null: false
        end

        # Ejecutamos el bloque del usuario (definición de columnas adicionales)
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

        # Si no la definió, la creamos (asumiendo integer por defecto para claves foráneas típicas)
        # Si el usuario quiere un UUID como partition key, debería definirlo explícitamente en el bloque.
        table.integer key, null: false
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
