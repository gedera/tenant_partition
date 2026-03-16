# frozen_string_literal: true

require "digest"
require_relative "data_mover"

module TenantPartition
  module Concerns
    # Concern principal para dotar a un modelo ActiveRecord de capacidades de particionamiento.
    #
    # Al incluir este concern en ApplicationRecord, los modelos obtienen acceso a la macro
    # {.partition_table}, la cual activa la lógica de partición, configura la clave primaria
    # compuesta (solo si es seguro) y añade métodos de gestión de tablas (DDL).
    module Partitioned
      extend ActiveSupport::Concern

      class_methods do
        # Macro para activar el particionamiento en el modelo actual.
        #
        # Incluye introspección inteligente: verifica en PostgreSQL si la tabla física
        # realmente está particionada antes de alterar el comportamiento nativo de Rails.
        # Esto permite despliegues Zero-Downtime seguros, donde el código puede ser
        # desplegado antes de que finalice la migración de base de datos.
        #
        # @example Activar partición por ISP
        #   class Conversation < ApplicationRecord
        #     partition_table key: :isp_id
        #   end
        #
        # @param key [Symbol, nil] La columna clave de partición. Si es nil, usa la global.
        # @return [void]
        def partition_table(key: nil)
          resolved_key = key || TenantPartition.configuration.partition_key

          # Guardamos la key en una variable de instancia de clase para acceso rápido
          @partition_key_column = resolved_key

          # Registrar este modelo en el sistema global
          TenantPartition.register_model(self)

          # Inyectar Scopes Automáticos
          # Este scope es siempre inofensivo y útil, incluso si la tabla sigue siendo legacy.
          scope :for_partition, ->(val) {
            # 🚀 OPTIMIZACIÓN: Forzamos el cast del valor al tipo de la columna para asegurar el Partition Pruning.
            # Evitamos que Postgres reciba un String para un BigInt, lo que desactivaría la poda de particiones.
            cast_value = type_for_attribute(resolved_key).cast(val)
            where(resolved_key => cast_value)
          }

          # Inyectar lógica de infraestructura y movimiento de datos
          extend ManagementMethods
          include TenantPartition::Concerns::DataMover

          # 🪄 INTROSPECCIÓN DINÁMICA: Adaptación al entorno
          begin
            # 'p' en pg_class.relkind significa "Partitioned table" nativa en Postgres.
            is_partitioned = connection.select_value(
              "SELECT relkind FROM pg_class WHERE relname = '#{table_name}'"
            ) == "p"

            # Solo activamos la Primary Key Compuesta si la tabla ya hizo el Cutover real en BD.
            # Además, verificamos que Rails sea 7.1 o superior (Rails 6 no lo soporta nativamente).
            if is_partitioned && ActiveRecord.version >= Gem::Version.new("7.1.0")
              self.primary_key = [:id, resolved_key]
            end
          rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
            # Ignoramos silenciosamente si la BD no está lista (ej. durante rake assets:precompile,
            # construcción de imágenes Docker, o antes de correr db:create).
          end
        end

        # Devuelve el nombre de la columna usada para particionar este modelo.
        # @return [Symbol]
        def partition_key_column
          @partition_key_column
        end
      end

      # Métodos de gestión de infraestructura (DDL) inyectados como métodos de clase.
      module ManagementMethods
        # Crea físicamente la partición en la base de datos para un valor dado.
        #
        # @param value [String, Integer] El valor del tenant (ej: ID del ISP).
        # @return [void]
        # @raise [ActiveRecord::StatementInvalid] Si falla la ejecución SQL.
        def create_partition(value)
          payload = create_partition_payload(value)

          ActiveSupport::Notifications.instrument("create.tenant_partition", payload) do
            execute_create_partition_sql(value)
          end
        end

        # Elimina (DROP) la partición asociada al valor dado.
        # Realiza un DETACH primero para mayor seguridad en transacciones y luego DROP.
        #
        # @param value [String, Integer] El valor del tenant.
        # @return [void]
        def drop_partition(value)
          partition_name = partition_table_name(value)

          return unless partition_table_exists?(value)

          connection.transaction do
            connection.execute("ALTER TABLE #{table_name} DETACH PARTITION #{partition_name};")
            connection.execute("DROP TABLE IF EXISTS #{partition_name};")
          end
        end

        # Genera el nombre de la tabla física para una partición específica.
        # Utiliza Hashing Inteligente para evitar el límite de 63 caracteres de PostgreSQL.
        #
        # @param value [Object] El valor del tenant.
        # @return [String] Nombre de la tabla (ej: 'conversations_isp_1' o 'conversations_isp_a1b2c3d4').
        def partition_table_name(value)
          str_value = value.to_s

          # Si es largo (UUID), hasheamos a 8 caracteres. Si es corto (Integer), lo dejamos legible.
          safe_value = str_value.length > 10 ? Digest::MD5.hexdigest(str_value)[0..7] : str_value.gsub("-", "_")

          suffix = partition_key_column.to_s.gsub("_id", "")

          # Formato estricto interno: nombre_tabla_sufijo_valor_seguro
          "#{table_name}_#{suffix}_#{safe_value}"
        end

        # Verifica si la tabla de la partición existe en el catálogo de PostgreSQL.
        #
        # @param value [Object] El valor del tenant.
        # @return [Boolean] true si la tabla hija existe y está anexada.
        def partition_table_exists?(value)
          child_table = partition_table_name(value)

          sql = <<~SQL.squish
            SELECT 1 FROM pg_class c
            JOIN pg_inherits i ON c.oid = i.inhrelid
            JOIN pg_class p ON i.inhparent = p.oid
            WHERE p.relname = '#{table_name}' AND c.relname = '#{child_table}';
          SQL

          connection.execute(sql).any?
        end

        # Nombre de la tabla DEFAULT (para valores que no caen en ninguna partición aprovisionada).
        # @return [String]
        def default_partition_table_name
          "#{table_name}_default"
        end

        private

        # Genera el payload de metadatos para la instrumentación (ActiveSupport::Notifications).
        def create_partition_payload(value)
          {
            partition_key: partition_key_column,
            value: value,
            parent_table: table_name
          }
        end

        # Ejecuta la consulta SQL pura para anexar la nueva tabla como partición.
        def execute_create_partition_sql(value)
          table_name_for_partition = partition_table_name(value)
          
          # 🛡️ CHEQUEO DE RENDIMIENTO: Si la partición DEFAULT tiene datos, Postgres escaneará
          # todo el DEFAULT para asegurar que el nuevo valor no esté allí.
          default_count = connection.select_value("SELECT count(*) FROM #{default_partition_table_name} LIMIT 1001")
          if default_count > 1000
            TenantPartition.log_info "WARNING", "La partición DEFAULT de #{table_name} tiene >1000 registros. " \
                                              "Crear esta nueva partición podría bloquear la tabla durante el escaneo."
          end

          sql = <<~SQL.squish
            CREATE TABLE IF NOT EXISTS #{table_name_for_partition}
            PARTITION OF #{table_name} FOR VALUES IN ('#{value}');
          SQL
          connection.execute(sql)
        end
      end
    end
  end
end
