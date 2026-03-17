# frozen_string_literal: true

require "digest"
require "set"

module TenantPartition
  # Clase encargada de la migración masiva de datos (Backfill) en segundo plano.
  class Migrator
    attr_reader :model, :source_table, :target_table, :partition_key

    def initialize(model:, target_table:)
      @model = model
      @source_table = model.table_name
      @target_table = target_table.to_s

      # Intenta obtener la key del modelo (si ya tiene la macro),
      # caso contrario, usa de forma segura la clave global.
      @partition_key = if model.respond_to?(:partition_key_column) && model.partition_key_column
                         model.partition_key_column
                       else
                         TenantPartition.configuration.partition_key
                       end

      raise TenantPartition::Error, "No se pudo determinar la partition_key para el Migrator." unless @partition_key

      @target_model = Class.new(model)
      @target_model.table_name = @target_table

      @ensured_partitions = Set.new
    end

    def copy_data!(batch_size: 5000, order_by: :id, &block)
      TenantPartition.log_info "MIGRATE", "Copiando #{@source_table} -> #{@target_table} (Lotes: #{batch_size})"

      validate_target_table!

      last_value = initial_value_for(order_by)
      last_id = initial_id_value
      total_copied = 0

      # Obtenemos el mapeo de columnas para el UPSERT (ON CONFLICT DO UPDATE)
      update_mapping = update_mapping_for_target

      loop do
        # 🚀 OPTIMIZACIÓN: Solo traemos los campos de control a Ruby para ahorrar memoria
        control_rows = fetch_control_batch(order_by, last_value, last_id, batch_size)
        break if control_rows.empty?

        # Aseguramos que existan las particiones físicas para este lote
        ensure_partitions_exist_for!(control_rows)

        # Ejecutamos el movimiento de datos pesados directamente en SQL
        batch_ids = control_rows.map { |r| r["id"] }
        move_batch_in_sql(batch_ids, update_mapping)

        block&.call(control_rows) if block

        last_record = control_rows.last
        last_value = last_record[order_by.to_s]
        last_id = last_record["id"]
        total_copied += control_rows.size

        print "."
      end

      puts ""
      TenantPartition.log_info "MIGRATE", "¡Completado! #{total_copied} registros procesados."
    end

    private

    def validate_target_table!
      return if model.connection.table_exists?(@target_table)

      raise TenantPartition::Error, "La tabla destino '#{@target_table}' no existe."
    end

    def fetch_control_batch(order_column, last_value, last_id, limit)
      sql = build_control_query(order_column, last_value, last_id, limit)
      model.connection.select_all(sql).to_a
    end

    def build_control_query(column, last_value, last_id, limit)
      # 🐛 FIX: Debemos seleccionar la columna de paginación (ej: created_at)
      # para que el script sepa desde dónde arrancar el siguiente lote.
      fields = ["id", @partition_key.to_s]
      fields << column.to_s unless fields.include?(column.to_s)

      select_clause = "SELECT #{fields.join(', ')} "
      from_clause = "FROM #{@source_table} "

      where_clause = if column == :id
                       "WHERE id > #{model.connection.quote(last_value)} "
                     else
                       "WHERE (#{column}, id) > (#{model.connection.quote(last_value)}, #{model.connection.quote(last_id)}) "
                     end

      order_clause = column == :id ? "ORDER BY id ASC " : "ORDER BY #{column} ASC, id ASC "

      "#{select_clause}#{from_clause}#{where_clause}#{order_clause}LIMIT #{limit}"
    end

    def move_batch_in_sql(ids, update_mapping)
      quoted_ids = ids.map { |id| model.connection.quote(id) }.join(",")

      sql = <<~SQL.squish
        INSERT INTO #{@target_table}
        SELECT * FROM #{@source_table}
        WHERE id IN (#{quoted_ids})
        ON CONFLICT (id, #{@partition_key})
        DO UPDATE SET #{update_mapping};
      SQL

      model.connection.execute(sql)
    end

    def update_mapping_for_target
      model.connection.columns(@source_table).map do |col|
        "#{col.name} = EXCLUDED.#{col.name}"
      end.join(", ")
    end

    def ensure_partitions_exist_for!(rows)
      batch_partition_ids = rows.filter_map { |r| r[@partition_key.to_s] }.uniq

      new_ids = batch_partition_ids - @ensured_partitions.to_a
      return if new_ids.empty?

      new_ids.each do |pid|
        create_shadow_partition(pid)
        @ensured_partitions.add(pid)
      end
    end

    def create_shadow_partition(pid)
      suffix = @partition_key.to_s.gsub("_id", "")
      str_pid = pid.to_s

      # Misma lógica de Hashing Inteligente para la creación de infraestructura
      safe_pid = str_pid.length > 10 ? Digest::MD5.hexdigest(str_pid)[0..7] : str_pid.gsub("-", "_")

      partition_name = "#{@target_table}_#{suffix}_#{safe_pid}"
      default_partition = "#{@target_table}_default"

      model.connection.transaction do
        # 1. Extraemos y borramos temporalmente los datos "vivos" que cayeron en el DEFAULT.
        # Al usar RETURNING * obtenemos las filas completas en un solo paso.
        quoted_pid = model.connection.quote(pid)
        conflicting_rows = model.connection.select_all(
          "DELETE FROM #{default_partition} WHERE #{@partition_key} = #{quoted_pid} RETURNING *"
        ).to_a

        # 2. Ahora que Postgres ve que no hay violaciones en el DEFAULT, creamos la partición
        sql = <<~SQL.squish
          CREATE TABLE IF NOT EXISTS #{partition_name}
          PARTITION OF #{@target_table} FOR VALUES IN (#{quoted_pid});
        SQL
        model.connection.execute(sql)

        # 3. Re-insertamos los datos "vivos" (Postgres ahora los enrutará a la nueva tabla)
        if conflicting_rows.any?
          @target_model.insert_all(
            conflicting_rows,
            unique_by: [:id, @partition_key],
            returning: nil
          )
          TenantPartition.log_info "RECOVER", "Se movieron #{conflicting_rows.size} registros vivos desde DEFAULT hacia #{partition_name}"
        end
      end
    end

    def initial_value_for(order_by)
      order_by == :id ? 0 : "1970-01-01 00:00:00"
    end

    # Define el ID inicial evaluando el tipo de columna.
    def initial_id_value
      if model.columns_hash["id"]&.type == :uuid
        "00000000-0000-0000-0000-000000000000"
      else
        0
      end
    end
  end
end
