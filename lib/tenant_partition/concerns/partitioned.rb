# frozen_string_literal: true

require_relative "data_mover"

module TenantPartition
  module Concerns
    # Concern principal para dotar a un modelo ActiveRecord de capacidades de particionamiento.
    #
    # Al incluir este concern en ApplicationRecord, los modelos obtienen acceso a la macro
    # {.partition_table}, la cual activa la lógica de partición, configura la clave primaria
    # compuesta y añade métodos de gestión de tablas (DDL).
    module Partitioned
      extend ActiveSupport::Concern

      class_methods do
        # Macro para activar el particionamiento en el modelo actual.
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

          # Registrar este modelo en el sistema
          TenantPartition.register_model(self)

          # Configurar Primary Key Compuesta (Soporte Rails 7.1+)
          self.primary_key = [:id, resolved_key]

          # Inyectar Scopes Automáticos
          scope :for_partition, ->(val) { where(resolved_key => val) }

          # Inyectar lógica de infraestructura y movimiento de datos
          extend ManagementMethods
          include TenantPartition::Concerns::DataMover
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
          table_name_for_partition = partition_table_name(value)

          payload = {
            partition_key: partition_key_column,
            value: value,
            parent_table: table_name
          }

          ActiveSupport::Notifications.instrument("create.tenant_partition", payload) do
            sql = <<~SQL.squish
              CREATE TABLE IF NOT EXISTS #{table_name_for_partition}
              PARTITION OF #{table_name} FOR VALUES IN ('#{value}');
            SQL
            connection.execute(sql)
          end
        end

        # Elimina (DROP) la partición asociada al valor dado.
        # Realiza un DETACH primero para seguridad y luego DROP.
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
        #
        # @param value [Object] El valor del tenant.
        # @return [String] Nombre de la tabla (ej: 'conversations_isp_1').
        def partition_table_name(value)
          sanitized_value = value.to_s.gsub("-", "_")
          suffix = partition_key_column.to_s.gsub("_id", "")

          # Formato: nombre_tabla_sufijo_valor
          "#{table_name}_#{suffix}_#{sanitized_value}"
        end

        # Verifica si la tabla de la partición existe en el catálogo de PostgreSQL.
        #
        # @param value [Object] El valor del tenant.
        # @return [Boolean]
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

        # Nombre de la tabla DEFAULT (para valores que no caen en ninguna partición).
        # @return [String]
        def default_partition_table_name
          "#{table_name}_default"
        end
      end
    end
  end
end
