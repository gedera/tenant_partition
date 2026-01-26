# frozen_string_literal: true

module ActivePartition
  module Schema
    # Proporciona métodos adicionales para las migraciones de ActiveRecord
    # enfocados en la automatización del particionamiento nativo de PostgreSQL.
    module Statements
      # Crea una tabla padre particionada por lista y genera automáticamente
      # su partición por defecto (DEFAULT).
      #
      # La columna de partición se inyectará automáticamente.
      #
      # @param table_name [Symbol, String] El nombre de la tabla a crear.
      # @param options [Hash] Opciones estándar + :partition_key opcional.
      # @yield [t] Bloque para definir las columnas de la tabla.
      #
      # @example Crear tabla usando configuración global
      #   create_partitioned_table :messages do |t| ... end
      #
      # @example Crear tabla con key personalizada
      #   create_partitioned_table :logs, partition_key: :region_code do |t| ... end
      #
      # @return [void]
      # @raise [ActivePartition::Error] Si no se ha configurado ninguna clave.
      def create_partitioned_table(table_name, **options, &block)
        # Prioridad: 1. Opción pasada al método, 2. Configuración global
        key = options.delete(:partition_key) || ActivePartition.configuration&.partition_key

        unless key
          raise ActivePartition::Error, "Debe configurar 'partition_key' globalmente o pasarlo como opción."
        end

        # Inyectamos la cláusula PARTITION BY en las opciones nativas de Postgres
        options[:options] = "PARTITION BY LIST (#{key})"
        options[:id] = :uuid unless options.key?(:id)

        # 1. Crear la tabla padre
        create_table(table_name, **options) do |t|
          # Ejecutamos las definiciones del usuario
          block.call(t)

          # Inyección automática del atributo de partición si no existe
          unless t.columns.any? { |c| c.name == key.to_s }
            t.column key, :string, null: false
          end
        end

        # 2. Crear la partición DEFAULT
        default_name = "#{table_name}_default"
        execute <<-SQL.squish
          CREATE TABLE IF NOT EXISTS #{default_name}
          PARTITION OF #{table_name} DEFAULT;
        SQL
      end

      # Elimina una tabla particionada y su tabla por defecto asociada.
      # @param table_name [Symbol, String] Nombre de la tabla padre.
      # @return [void]
      def drop_partitioned_table(table_name)
        drop_table(table_name, cascade: true)
      end
    end
  end
end
