# frozen_string_literal: true

module TenantPartition
  # Clase encargada de la migración masiva de datos (Backfill) en segundo plano.
  # Permite copiar registros en lotes desde una tabla legacy hacia su versión particionada,
  # manejando conflictos automáticamente para convivir con Triggers de replicación en tiempo real.
  class Migrator
    attr_reader :model, :source_table, :target_table, :partition_key

    # @param model [Class] Clase ActiveRecord del modelo a migrar (ej. PaperTrail::Version).
    # @param target_table [Symbol, String] Nombre de la tabla destino (ej. :versions_partitioned).
    def initialize(model:, target_table:)
      @model = model
      @source_table = model.table_name
      @target_table = target_table.to_s
      @partition_key = model.partition_key_column

      # Creamos un modelo anónimo al vuelo para poder usar el método `insert_all`
      # nativo de Rails apuntando a la tabla destino sin modificar tu modelo original.
      @target_model = Class.new(model)
      @target_model.table_name = @target_table
    end

    # Inicia el proceso de copiado masivo de datos.
    # Utiliza "Keyset Pagination" para mantener el rendimiento estable aunque
    # la tabla tenga millones de filas.
    #
    # @param batch_size [Integer] Cantidad de registros a copiar por lote.
    # @param order_by [Symbol] Columna de ordenamiento. Usar :id para enteros, o :created_at para UUIDs.
    # @yield [Array<Hash>] Bloque opcional para transformar/limpiar los datos antes de insertarlos.
    def copy_data!(batch_size: 2000, order_by: :id, &block)
      TenantPartition.log_info "MIGRATE", "Copiando #{@source_table} -> #{@target_table} (Lotes: #{batch_size})"

      validate_target_table!

      last_value = initial_value_for(order_by)
      last_id = initial_id_value
      total_copied = 0

      loop do
        rows = fetch_batch(order_by, last_value, last_id, batch_size)
        break if rows.empty?

        # Permitimos al desarrollador mutar el hash de datos (ej: inyectar isp_id si es nulo)
        block&.call(rows)

        insert_batch(rows)

        # Actualizamos los cursores para la siguiente iteración
        last_record = rows.last
        last_value = last_record[order_by.to_s]
        last_id = last_record["id"]
        total_copied += rows.size

        print "." # Feedback visual en consola
      end

      puts "" # Salto de línea al terminar la iteración
      TenantPartition.log_info "MIGRATE", "¡Completado! #{total_copied} registros procesados."
    end

    private

    def validate_target_table!
      return if model.connection.table_exists?(@target_table)

      raise TenantPartition::Error, "La tabla destino '#{@target_table}' no existe."
    end

    # Retorna un lote de registros desde la base de datos sin instanciar modelos (por velocidad).
    def fetch_batch(order_column, last_value, last_id, limit)
      sql = build_keyset_query(order_column, last_value, last_id, limit)
      model.connection.select_all(sql).to_a
    end

    # Construye la consulta SQL optimizada para paginación continua.
    def build_keyset_query(column, last_value, last_id, limit)
      if column == :id
        <<~SQL.squish
          SELECT * FROM #{@source_table}
          WHERE id > #{model.connection.quote(last_value)}
          ORDER BY id ASC
          LIMIT #{limit}
        SQL
      else
        # Soporte para UUIDs: Paginación por Tupla (fecha, id)
        # Esto previene saltos o duplicados si dos registros tienen exactamente el mismo milisegundo.
        <<~SQL.squish
          SELECT * FROM #{@source_table}
          WHERE (#{column}, id) > (#{model.connection.quote(last_value)}, #{model.connection.quote(last_id)})
          ORDER BY #{column} ASC, id ASC
          LIMIT #{limit}
        SQL
      end
    end

    # Inserta los datos en la tabla sombra.
    def insert_batch(rows)
      # Usamos unique_by con ON CONFLICT DO NOTHING implícito en insert_all.
      # Si el Trigger ya replicó un dato en tiempo real (Live), ignoramos la versión vieja.
      @target_model.insert_all!(
        rows,
        unique_by: [:id, @partition_key],
        returning: nil
      )
    end

    def initial_value_for(order_by)
      order_by == :id ? 0 : "1970-01-01 00:00:00"
    end

    def initial_id_value
      # Un string vacío funciona como punto de partida menor que cualquier UUID en Postgres
      ""
    end
  end
end
