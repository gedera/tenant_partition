# frozen_string_literal: true

module ActivePartition
  module Schema
    # Proporciona métodos adicionales para las migraciones de ActiveRecord
    # enfocados en la automatización del particionamiento nativo de PostgreSQL.
    module Statements
      # Crea una tabla padre particionada por lista y genera automáticamente
      # su partición por defecto (DEFAULT).
      #
      # La columna definida en la configuración global como +partition_key+
      # se inyectará automáticamente si no se define explícitamente en el bloque.
      #
      # @param table_name [Symbol, String] El nombre de la tabla a crear.
      # @param options [Hash] Opciones estándar de ActiveRecord +create_table+.
      # @yield [t] Bloque para definir las columnas de la tabla.
      #
      # @example Crear un microservicio de mensajería con soporte Multi-tenant
      #   # config/initializers/active_partition.rb -> config.partition_key = :isp_id
      #
      #   create_partitioned_table :messages do |t|
      #     t.uuid :chat_id, null: false
      #     t.jsonb :payload, default: {}
      #     t.string :state, default: 'pending'
      #     t.timestamps
      #   end
      #
      #   # Esto ejecutará en SQL:
      #   # 1. CREATE TABLE messages (..., isp_id string) PARTITION BY LIST (isp_id);
      #   # 2. CREATE TABLE messages_default PARTITION OF messages DEFAULT;
      #
      # @return [void]
      # @raise [ActivePartition::Error] Si no se ha configurado la clave de partición.
      def create_partitioned_table(table_name, **options, &block)
        key = ActivePartition.configuration&.partition_key

        unless key
          raise ActivePartition::Error, "Debe configurar 'partition_key' en el inicializador antes de ejecutar migraciones."
        end

        # Inyectamos la cláusula PARTITION BY en las opciones nativas de Postgres
        # Forzamos que el partition_key sea parte de la definición primaria
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
        # El nombre se infiere siguiendo la convención de ActivePartition::Base
        default_name = "#{table_name}_default"
        execute <<-SQL.squish
          CREATE TABLE IF NOT EXISTS #{default_name}
          PARTITION OF #{table_name} DEFAULT;
        SQL
      end

      # Elimina una tabla particionada y su tabla por defecto asociada.
      # Utiliza CASCADE para asegurar que todas las particiones hijas sean removidas.
      #
      # @param table_name [Symbol, String] Nombre de la tabla padre.
      # @return [void]
      def drop_partitioned_table(table_name)
        drop_table(table_name, cascade: true)
      end
    end
  end
end
