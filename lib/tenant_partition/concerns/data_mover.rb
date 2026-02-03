# frozen_string_literal: true

module TenantPartition
  module Concerns
    # Módulo encargado de la migración de datos (Backfilling) entre tablas.
    # Se extrajo de {TenantPartition::Base} para reducir la complejidad.
    module DataMover
      extend ActiveSupport::Concern

      # Mueve registros desde la tabla DEFAULT hacia la partición actual.
      #
      # @param batch_size [Integer] Registros por transacción (Default: 5000).
      # @return [Integer] Total de registros movidos.
      def populate_from_default(batch_size: 5000)
        return 0 unless persisted?

        ActiveSupport::Notifications.instrument("populate.tenant_partition", instrumentation_payload) do |evt|
          total = perform_batch_move(batch_size)
          evt[:count] = total
          total
        end
      end

      private

      # Construye el payload para la instrumentación.
      def instrumentation_payload
        {
          partition_key: self.class.partition_key,
          value: partition_id,
          parent_table: self.class.parent_table
        }
      end

      # Bucle de movimiento por lotes.
      def perform_batch_move(batch_size)
        total_moved = 0
        loop do
          batch_count = move_single_batch(batch_size)
          total_moved += batch_count
          break if batch_count < batch_size
        end
        total_moved
      end

      # Transacción para un solo lote.
      def move_single_batch(batch_size)
        default = self.class.default_table
        parent  = self.class.parent_table
        key     = self.class.partition_key
        val     = partition_id

        self.class.connection.transaction do
          execute_move_query(default, parent, key, val, batch_size)
        end
      end

      # Ejecuta la query SQL.
      def execute_move_query(default, parent, key, val, batch_size)
        sql = build_move_sql(default, parent, key, val, batch_size)
        self.class.connection.execute(sql).cmd_tuples
      end

      # Construye la query SQL compleja (CTE + DELETE + INSERT).
      def build_move_sql(default, parent, key, val, batch_size)
        <<~SQL.squish
          WITH moved_rows AS (
            DELETE FROM #{default}
            WHERE #{key} = '#{val}'
            AND id IN (
              SELECT id FROM #{default} WHERE #{key} = '#{val}' LIMIT #{batch_size}
            )
            RETURNING *
          )
          INSERT INTO #{parent} SELECT * FROM moved_rows;
        SQL
      end
    end
  end
end
