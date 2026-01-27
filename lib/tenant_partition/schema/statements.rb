# frozen_string_literal: true

module TenantPartition
  module Schema
    # Proporciona métodos adicionales para las migraciones de ActiveRecord
    # enfocados en la automatización del particionamiento nativo de PostgreSQL.
    module Statements
      # Crea una tabla padre particionada por lista y genera automáticamente
      # su partición por defecto (DEFAULT).
      #
      # CORRECCIÓN IMPORTANTE: Configura una Primary Key Compuesta (id + partition_key)
      # para cumplir con los requisitos de unicidad de PostgreSQL en tablas particionadas.
      #
      # @param table_name [Symbol, String] El nombre de la tabla a crear.
      # @param options [Hash] Opciones estándar + :partition_key opcional.
      # @yield [t] Bloque para definir las columnas de la tabla.
      def create_partitioned_table(table_name, **options, &block)
        # Prioridad: 1. Opción pasada al método, 2. Configuración global
        key = options.delete(:partition_key) || TenantPartition.configuration&.partition_key

        unless key
          raise TenantPartition::Error, "Debe configurar 'partition_key' globalmente o pasarlo como opción."
        end

        # --- LÓGICA DE PRIMARY KEY COMPUESTA ---
        # 1. Desactivamos la creación automática del ID simple, ya que Postgres fallaría.
        options[:id] = false

        # 2. Definimos explícitamente que la PK está formada por el ID y la CLAVE DE PARTICIÓN.
        # Esto genera en SQL: PRIMARY KEY (id, isp_id)
        options[:primary_key] = [:id, key]

        # 3. Inyectamos la estrategia de particionamiento
        options[:options] = "PARTITION BY LIST (#{key})"

        # Crear la tabla padre
        create_table(table_name, **options) do |t|
          # A. Como desactivamos id: false, debemos crear la columna ID manualmente.
          # Usamos gen_random_uuid() para que sea autogenerado.
          t.uuid :id, null: false, default: -> { "gen_random_uuid()" }

          # B. Ejecutamos las definiciones del usuario
          block.call(t)

          # C. Inyección automática del atributo de partición si el usuario no lo definió.
          # Nota: Si el usuario ya puso `t.uuid :isp_id` en su migración, esta línea la salta.
          unless t.columns.any? { |c| c.name == key.to_s }
            t.column key, :string, null: false
          end
        end

        # Crear la partición DEFAULT
        default_name = "#{table_name}_default"
        execute <<-SQL.squish
          CREATE TABLE IF NOT EXISTS #{default_name}
          PARTITION OF #{table_name} DEFAULT;
        SQL
      end

      # Elimina una tabla particionada y su tabla por defecto asociada.
      def drop_partitioned_table(table_name)
        drop_table(table_name, cascade: true)
      end
    end
  end
end
