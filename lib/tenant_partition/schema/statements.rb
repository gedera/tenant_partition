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

      # Crea una tabla particionada copiando dinámicamente la estructura de una tabla existente.
      #
      # @param target_table [Symbol, String] Nombre de la nueva tabla particionada.
      # @param source_table [Symbol, String] Nombre de la tabla legacy a copiar.
      # @param sync_triggers [Boolean] Si es true, instala los triggers de Live Sync automáticamente.
      # @param options [Hash] Opciones adicionales (ej: partition_key, id_type).
      def create_partitioned_table_from(target_table, source_table, sync_triggers: false, **options, &block)
        key = options[:partition_key] || TenantPartition.configuration&.partition_key
        raise TenantPartition::Error, "Falta 'partition_key'." unless key

        # 1. Creamos la tabla usando nuestro helper core
        create_partitioned_table(target_table, **options) do |t|

          # 2. Introspección: Leemos las columnas de la tabla vieja
          ActiveRecord::Base.connection.columns(source_table).each do |col|
            # Omitimos 'id' y 'partition_key' porque el helper ya los define correctamente
            next if col.name == "id" || col.name == key.to_s

            # Recreamos la columna con sus propiedades exactas
            t.column col.name, col.type,
                     limit: col.limit,
                     precision: col.precision,
                     scale: col.scale,
                     default: col.default,
                     null: col.null
          end

          # Permitimos al usuario pasar un bloque opcional para agregar índices
          block.call(t) if block
        end

        # 3. Opcional: Instalamos los Triggers en un solo paso
        create_partition_sync_trigger(source_table, target_table, key) if sync_triggers
      end

      # Crea un trigger de sincronización en tiempo real (Live Sync) mediante UPSERT.
      # Replica de forma atómica los eventos INSERT, UPDATE y DELETE desde una tabla
      # origen (legacy) hacia una tabla destino (particionada sombra).
      #
      # @param source_table [Symbol, String] Nombre de la tabla original.
      # @param target_table [Symbol, String] Nombre de la nueva tabla particionada.
      # @param partition_key [Symbol, String] Columna utilizada como clave de partición.
      # @return [void]
      def create_partition_sync_trigger(source_table, target_table, partition_key)
        func_name = "trigger_sync_#{source_table}_to_#{target_table}"
        trigger_name = "sync_#{source_table}_data"

        # Mapeo seguro: "col1 = EXCLUDED.col1, col2 = EXCLUDED.col2"
        update_mapping = update_mapping_for(source_table)

        execute <<~SQL.squish
          CREATE OR REPLACE FUNCTION #{func_name}() RETURNS TRIGGER AS $$
          BEGIN
            IF (TG_OP = 'DELETE') THEN
              DELETE FROM #{target_table} WHERE id = OLD.id;
              RETURN OLD;
            ELSIF (TG_OP = 'UPDATE') THEN
              INSERT INTO #{target_table} VALUES (NEW.*)
              ON CONFLICT (id, #{partition_key})
              DO UPDATE SET #{update_mapping};
              RETURN NEW;
            ELSIF (TG_OP = 'INSERT') THEN
              INSERT INTO #{target_table} VALUES (NEW.*)
              ON CONFLICT (id, #{partition_key})
              DO UPDATE SET #{update_mapping};
              RETURN NEW;
            END IF;
            RETURN NULL;
          END;
          $$ LANGUAGE plpgsql;
        SQL

        execute <<~SQL.squish
          DROP TRIGGER IF EXISTS #{trigger_name} ON #{source_table};
          CREATE TRIGGER #{trigger_name}
          AFTER INSERT OR UPDATE OR DELETE ON #{source_table}
          FOR EACH ROW EXECUTE FUNCTION #{func_name}();
        SQL
      end

      # Elimina la función y el trigger de sincronización creados por {#create_partition_sync_trigger}.
      #
      # @param source_table [Symbol, String] Nombre de la tabla original.
      # @param target_table [Symbol, String] Nombre de la nueva tabla particionada.
      # @return [void]
      def remove_partition_sync_trigger(source_table, target_table)
        func_name = "trigger_sync_#{source_table}_to_#{target_table}"
        trigger_name = "sync_#{source_table}_data"

        execute "DROP TRIGGER IF EXISTS #{trigger_name} ON #{source_table};"
        execute "DROP FUNCTION IF EXISTS #{func_name}();"
      end

      # Realiza el intercambio (Cutover) atómico entre la tabla legacy y la particionada.
      # Elimina los triggers y cruza los nombres de las tablas sin detener la base de datos.
      #
      # @param legacy_table [Symbol, String] Nombre de la tabla original (ej: :versions).
      # @param partitioned_table [Symbol, String] Nombre de la nueva tabla (ej: :versions_partitioned).
      # @return [void]
      def swap_partitioned_tables(legacy_table, partitioned_table)
        backup_name = "#{legacy_table}_legacy"

        transaction do
          remove_partition_sync_trigger(legacy_table, partitioned_table)
          rename_table(legacy_table, backup_name)
          rename_table(partitioned_table, legacy_table)
        end
      end

      # Elimina una tabla particionada en cascada.
      # @param table_name [Symbol] Nombre de la tabla.
      def drop_partitioned_table(table_name)
        drop_table(table_name, cascade: true)
      end

      private

      # Configura las columnas y definiciones dentro del bloque create_table.
      def setup_partitioning(table, key, id_type, block)
        if id_type == :uuid
          table.uuid :id, null: false, default: -> { "gen_random_uuid()" }
        else
          table.bigserial :id, null: false
        end

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

        table.integer key, null: false
      end

      # Crea la tabla _default para capturar datos sin partición asignada.
      def create_default_partition(table_name)
        default_name = "#{table_name}_default"
        execute <<~SQL.squish
          CREATE TABLE IF NOT EXISTS #{default_name}
          PARTITION OF #{table_name} DEFAULT;
        SQL
      end

      # Genera el mapeo explícito de columnas para el UPSERT.
      # Utiliza EXCLUDED, que es la pseudo-tabla de Postgres que contiene la fila conflictiva.
      def update_mapping_for(table_name)
        ActiveRecord::Base.connection.columns(table_name).map do |col|
          "#{col.name} = EXCLUDED.#{col.name}"
        end.join(", ")
      end
    end
  end
end
