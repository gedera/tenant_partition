# frozen_string_literal: true

module TenantPartition
  module Schema
    module Statements
      # Crea una tabla particionada por lista y su tabla DEFAULT asociada.
      #
      # @param table_name [Symbol] Nombre de la tabla.
      # @param options [Hash] Opciones.
      # @option options [Symbol] :partition_key Clave de partición (ej: :isp_id).
      # @option options [Symbol] :id_type Tipo de ID (:uuid o :bigint). Default: :bigint.
      def create_partitioned_table(table_name, **options, &block)
        key = options.delete(:partition_key) || TenantPartition.configuration&.partition_key
        id_type = options.delete(:id_type) || :bigint # Default a BigInt para ser conservadores

        raise TenantPartition::Error, "Falta 'partition_key'." unless key

        # Configuramos id: false y las opciones de partición
        configure_pk_and_options(options, key)

        create_table(table_name, **options) do |t|
          setup_partitioning(t, key, id_type, block)
        end

        create_default_partition(table_name)
      end

      def drop_partitioned_table(table_name)
        drop_table(table_name, cascade: true)
      end

      private

      def setup_partitioning(table, key, id_type, block)
        # Definimos la ID según la preferencia
        if id_type == :uuid
          table.uuid :id, null: false, default: -> { "gen_random_uuid()" }
        else
          table.bigserial :id, null: false
        end

        # Ejecutamos el bloque del usuario (columnas)
        block.call(table)

        # Aseguramos que la columna de partición exista
        ensure_partition_column(table, key)
      end

      def configure_pk_and_options(options, key)
        options[:id] = false
        options[:primary_key] = [:id, key]
        options[:options] = "PARTITION BY LIST (#{key})"
      end

      def ensure_partition_column(table, key)
        return if table.columns.any? { |c| c.name == key.to_s }
        # Si no la definió el usuario, asumimos integer.
        # Si fuera string/uuid el usuario debería definirla explícitamente en el bloque.
        table.integer key, null: false
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
