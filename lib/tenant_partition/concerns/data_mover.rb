# frozen_string_literal: true

module TenantPartition
  module Concerns
    # Funcionalidad para mover registros desde la tabla DEFAULT hacia su partición correspondiente.
    # Utilizado principalmente en tareas de mantenimiento y recuperación de datos.
    module DataMover
      extend ActiveSupport::Concern

      # SQL optimizado para mover datos en masa (CTE + DELETE/INSERT).
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

      # Mueve registros pertenecientes a este tenant desde la tabla Default a la partición.
      # Se ejecuta en lotes para no bloquear la base de datos.
      #
      # @param batch_size [Integer] Tamaño del lote (default: 5000).
      # @return [Integer] Cantidad total de registros movidos.
      def populate_from_default(batch_size: 5000)
        ActiveSupport::Notifications.instrument("populate.tenant_partition", instrumentation_payload) do |evt|
          total = perform_batch_move(batch_size)
          evt[:count] = total
          total
        end
      end

      private

      def instrumentation_payload
        {
          partition_key: self.class.partition_key_column,
          value: partition_id,
          parent_table: self.class.table_name
        }
      end

      # Obtiene el valor del ID de partición de la instancia actual.
      def partition_id
        public_send(self.class.partition_key_column)
      end

      def perform_batch_move(batch_size)
        total_moved = 0
        loop do
          batch_count = move_single_batch(batch_size)
          total_moved += batch_count
          break if batch_count < batch_size
        end
        total_moved
      end

      def move_single_batch(batch_size)
        self.class.connection.transaction do
          sql = format(MOVE_SQL, move_query_params(batch_size))
          self.class.connection.execute(sql).cmd_tuples
        end
      end

      def move_query_params(batch_size)
        {
          default: self.class.default_partition_table_name,
          parent: self.class.table_name,
          key: self.class.partition_key_column,
          val: partition_id,
          batch_size: batch_size
        }
      end
    end
  end
end
