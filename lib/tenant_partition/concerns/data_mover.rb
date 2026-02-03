# frozen_string_literal: true

module TenantPartition
  module Concerns
    # Módulo encargado de la migración de datos (Backfilling) entre tablas.
    # Se extrajo de {TenantPartition::Base} para desacoplar la lógica de movimiento de datos.
    module DataMover
      extend ActiveSupport::Concern

      # Query SQL parametrizada para el movimiento atómico (DELETE + INSERT).
      # Se define como constante para evitar la ofensa Metrics/MethodLength de RuboCop
      # y mejorar la performance evitando la re-asignación de memoria en cada llamada.
      # @api private
      MOVE_SQL = <<~SQL.squish.freeze
        WITH moved_rows AS (
          DELETE FROM %<default>s
          WHERE %<key>s = '%<val>s'
          AND id IN (
            SELECT id FROM %<default>s WHERE %<key>s = '%<val>s' LIMIT %<batch_size>d
          )
          RETURNING *
        )
        INSERT INTO %<parent>s SELECT * FROM moved_rows;
      SQL
      private_constant :MOVE_SQL

      # Mueve registros desde la tabla DEFAULT hacia la partición actual.
      # Utiliza transacciones por lotes para evitar bloqueos prolongados en la base de datos.
      #
      # @param batch_size [Integer] Cantidad de registros por transacción (Default: 5000).
      # @return [Integer] La cantidad total de registros movidos exitosamente.
      def populate_from_default(batch_size: 5000)
        return 0 unless persisted?

        ActiveSupport::Notifications.instrument("populate.tenant_partition", instrumentation_payload) do |evt|
          total = perform_batch_move(batch_size)
          evt[:count] = total
          total
        end
      end

      private

      # Construye el payload de datos para la instrumentación de ActiveSupport.
      # @return [Hash] Datos del contexto de la migración.
      def instrumentation_payload
        {
          partition_key: self.class.partition_key,
          value: partition_id,
          parent_table: self.class.parent_table
        }
      end

      # Ejecuta el bucle de movimiento hasta que no queden registros pendientes.
      # @param batch_size [Integer] Tamaño del lote.
      # @return [Integer] Total acumulado de registros movidos.
      def perform_batch_move(batch_size)
        total_moved = 0
        loop do
          batch_count = move_single_batch(batch_size)
          total_moved += batch_count
          break if batch_count < batch_size
        end
        total_moved
      end

      # Ejecuta una transacción atómica para mover un solo lote de registros.
      # @param batch_size [Integer] Tamaño del lote.
      # @return [Integer] Cantidad de filas afectadas (cmd_tuples).
      def move_single_batch(batch_size)
        # Preparamos las variables para inyectar en la plantilla SQL
        params = {
          default: self.class.default_table,
          parent: self.class.parent_table,
          key: self.class.partition_key,
          val: partition_id,
          batch_size: batch_size
        }

        self.class.connection.transaction do
          # Kernel#format es más rápido y seguro que la interpolación directa para templates
          sql = format(MOVE_SQL, params)
          self.class.connection.execute(sql).cmd_tuples
        end
      end
    end
  end
end
