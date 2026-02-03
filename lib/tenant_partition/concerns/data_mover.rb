# frozen_string_literal: true

module TenantPartition
  module Concerns
    # Módulo encargado de la migración de datos (Backfilling) entre tablas.
    # Se extrajo de {TenantPartition::Base} para reducir la complejidad y responsabilidad de la clase base.
    module DataMover
      extend ActiveSupport::Concern

      # Mueve registros desde la tabla DEFAULT hacia la partición actual de forma transaccional y por lotes.
      # Utiliza CTEs (Common Table Expressions) para asegurar atomicidad en el movimiento.
      #
      # @param batch_size [Integer] Cantidad de registros a procesar por transacción (Default: 5000).
      # @return [Integer] La cantidad total de registros movidos exitosamente.
      def populate_from_default(batch_size: 5000)
        return 0 unless persisted?

        payload = {
          partition_key: self.class.partition_key,
          value: partition_id,
          parent_table: self.class.parent_table
        }

        ActiveSupport::Notifications.instrument("populate.tenant_partition", payload) do |evt|
          total = perform_batch_move(batch_size)
          evt[:count] = total
          total
        end
      end

      private

      # Ejecuta el bucle de movimiento hasta que no queden registros pendientes.
      # @param batch_size [Integer] Tamaño del lote.
      # @return [Integer] Total acumulado.
      def perform_batch_move(batch_size)
        total_moved = 0
        loop do
          batch_count = move_single_batch(batch_size)
          total_moved += batch_count
          break if batch_count < batch_size
        end
        total_moved
      end

      # Ejecuta una transacción para mover un solo lote de registros.
      # @param batch_size [Integer] Tamaño del lote.
      # @return [Integer] Cantidad de filas afectadas en este lote.
      def move_single_batch(batch_size)
        default = self.class.default_table
        parent  = self.class.parent_table
        key     = self.class.partition_key
        val     = partition_id

        self.class.connection.transaction do
          execute_move_query(default, parent, key, val, batch_size)
        end
      end

      # Construye y ejecuta la query SQL cruda para el movimiento atómico (DELETE + INSERT).
      # @param default [String] Tabla origen (default).
      # @param parent [String] Tabla destino (padre).
      # @param key [Symbol] Columna de partición.
      # @param val [Object] Valor del ID de partición.
      # @param batch_size [Integer] Límite del lote.
      # @return [Integer] Número de tuplas movidas.
      def execute_move_query(default, parent, key, val, batch_size)
        sql = <<~SQL.squish
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
        self.class.connection.execute(sql).cmd_tuples
      end
    end
  end
end
