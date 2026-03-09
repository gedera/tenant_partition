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

    def copy_data!(batch_size: 2000, order_by: :id, &block)
      TenantPartition.log_info "MIGRATE", "Copiando #{@source_table} -> #{@target_table} (Lotes: #{batch_size})"

      validate_target_table!

      last_value = initial_value_for(order_by)
      last_id = initial_id_value
      total_copied = 0

      loop do
        rows = fetch_batch(order_by, last_value, last_id, batch_size)
        break if rows.empty?

        block&.call(rows)

        insert_batch(rows)

        last_record = rows.last
        last_value = last_record[order_by.to_s]
        last_id = last_record["id"]
        total_copied += rows.size

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

    def fetch_batch(order_column, last_value, last_id, limit)
      sql = build_keyset_query(order_column, last_value, last_id, limit)
      model.connection.select_all(sql).to_a
    end

    def build_keyset_query(column, last_value, last_id, limit)
      if column == :id
        <<~SQL.squish
          SELECT * FROM #{@source_table}
          WHERE id > #{model.connection.quote(last_value)}
          ORDER BY id ASC
          LIMIT #{limit}
        SQL
      else
        <<~SQL.squish
          SELECT * FROM #{@source_table}
          WHERE (#{column}, id) > (#{model.connection.quote(last_value)}, #{model.connection.quote(last_id)})
          ORDER BY #{column} ASC, id ASC
          LIMIT #{limit}
        SQL
      end
    end

    def insert_batch(rows)
      ensure_partitions_exist_for!(rows)

      @target_model.insert_all(
        rows,
        unique_by: [:id, @partition_key],
        returning: nil
      )
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

      sql = <<~SQL.squish
        CREATE TABLE IF NOT EXISTS #{partition_name}
        PARTITION OF #{@target_table} FOR VALUES IN ('#{pid}');
      SQL

      model.connection.execute(sql)
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
