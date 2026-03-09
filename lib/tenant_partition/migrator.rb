# frozen_string_literal: true

require "set"

module TenantPartition
  # Clase encargada de la migración masiva de datos (Backfill) en segundo plano.
  #
  # Permite copiar registros en lotes desde una tabla legacy hacia su versión particionada,
  # manejando conflictos automáticamente para convivir con Triggers de replicación en tiempo real.
  #
  # Además, cuenta con inteligencia de "Aprovisionamiento Just-In-Time" (JIT): crea
  # automáticamente las tablas físicas hijas a medida que descubre nuevos tenants en el
  # historial, garantizando que los registros nunca caigan en la partición _default.
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

      # Caché en memoria (Set) para registrar qué particiones ya creamos durante este proceso.
      # Optimiza el rendimiento evitando consultas DDL repetitivas a PostgreSQL.
      @ensured_partitions = Set.new
    end

    # Inicia el proceso de copiado masivo de datos.
    #
    # Utiliza "Keyset Pagination" para mantener el rendimiento estable aunque
    # la tabla tenga millones de filas. No colapsa la memoria RAM gracias a iteraciones ligeras.
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

        # Permitimos al desarrollador mutar el hash de datos al vuelo
        # (ej: inyectar isp_id si es nulo en datos muy antiguos)
        block&.call(rows)

        insert_batch(rows)

        # Actualizamos los cursores para la siguiente iteración
        last_record = rows.last
        last_value = last_record[order_by.to_s]
        last_id = last_record["id"]
        total_copied += rows.size

        print "." # Feedback visual en consola de progreso
      end

      puts "" # Salto de línea al terminar la iteración
      TenantPartition.log_info "MIGRATE", "¡Completado! #{total_copied} registros procesados."
    end

    private

    # Valida que la migración de preparación se haya ejecutado y la tabla exista.
    def validate_target_table!
      return if model.connection.table_exists?(@target_table)

      raise TenantPartition::Error, "La tabla destino '#{@target_table}' no existe."
    end

    # Retorna un lote de registros crudos desde la base de datos sin instanciar modelos de ActiveRecord.
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
        # Soporte robusto para UUIDs: Paginación por Tupla (fecha, id).
        # Previene saltos o duplicados si dos registros tienen exactamente el mismo milisegundo.
        <<~SQL.squish
          SELECT * FROM #{@source_table}
          WHERE (#{column}, id) > (#{model.connection.quote(last_value)}, #{model.connection.quote(last_id)})
          ORDER BY #{column} ASC, id ASC
          LIMIT #{limit}
        SQL
      end
    end

    # Aprovisiona la infraestructura necesaria e inserta los datos en la tabla sombra.
    def insert_batch(rows)
      # 🪄 LA MAGIA: Aseguramos que las particiones físicas existan antes de insertar el lote
      ensure_partitions_exist_for!(rows)

      # Usamos unique_by con ON CONFLICT DO NOTHING implícito en insert_all.
      # Si el Trigger ya replicó un dato en tiempo real (Live), ignoramos la versión vieja.
      @target_model.insert_all!(
        rows,
        unique_by: [:id, @partition_key],
        returning: nil
      )
    end

    # Analiza el lote y crea las tablas hijas dinámicamente si es la primera vez que vemos ese Tenant ID.
    def ensure_partitions_exist_for!(rows)
      # Extraemos los IDs únicos del lote actual (ignorando nulos preventivamente)
      batch_partition_ids = rows.filter_map { |r| r[@partition_key.to_s] }.uniq

      # Filtramos contra nuestro caché en memoria para ejecutar DDL solo cuando sea necesario
      new_ids = batch_partition_ids - @ensured_partitions.to_a
      return if new_ids.empty?

      new_ids.each do |pid|
        create_shadow_partition(pid)
        @ensured_partitions.add(pid) # Lo registramos en caché para futuros lotes
      end
    end

    # Ejecuta el DDL (CREATE TABLE) para la nueva partición en la tabla sombra (target_table).
    def create_shadow_partition(pid)
      suffix = @partition_key.to_s.gsub("_id", "")
      sanitized_pid = pid.to_s.gsub("-", "_")

      # Mantiene estricta consistencia con el formato de nombres de la gema
      partition_name = "#{@target_table}_#{suffix}_#{sanitized_pid}"

      sql = <<~SQL.squish
        CREATE TABLE IF NOT EXISTS #{partition_name}
        PARTITION OF #{@target_table} FOR VALUES IN ('#{pid}');
      SQL

      model.connection.execute(sql)
    end

    # Define el punto de partida dinámico de la paginación según el tipo de columna.
    def initial_value_for(order_by)
      order_by == :id ? 0 : "1970-01-01 00:00:00"
    end

    # Define el ID inicial seguro. Un string vacío evalúa siempre como menor que un UUID en Postgres.
    def initial_id_value
      ""
    end
  end
end
