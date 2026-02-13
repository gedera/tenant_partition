# frozen_string_literal: true

module TenantPartition
  # Módulo de utilidades para el mantenimiento de la salud de las particiones.
  # Permite auditar tablas DEFAULT en busca de registros huérfanos y moverlos.
  module Maintenance
    # Audita todas las tablas particionadas y cuenta registros en la tabla DEFAULT.
    #
    # @return [Hash{String => Integer}] Reporte con el conteo de huérfanos por modelo.
    def audit
      TenantPartition.send(:ensure_models_loaded!)
      TenantPartition.log_info "AUDIT", "Iniciando auditoría de tablas DEFAULT..."

      TenantPartition.partitionable_models.each_with_object({}) do |model, report|
        count = count_default_rows(model)
        report[model.name] = count
        log_audit_result(model, count)
      end
    end

    # Ejecuta el proceso de limpieza: busca huérfanos y los mueve a su partición correspondiente.
    # Si la partición no existe, lanza un error en el log.
    #
    # @return [void]
    def cleanup!
      TenantPartition.log_info "CLEANUP", "Iniciando proceso de limpieza global..."

      TenantPartition.partitionable_models.each do |model|
        # Usamos la key específica del modelo por si fue configurada localmente
        model_key = model.partition_key_column
        process_cleanup_for_model(model, model_key)
      end
    end

    private

    def log_audit_result(model, count)
      if count.positive?
        TenantPartition.log_warn "ALERTA", "#{model.name}: #{count} registros huérfanos encontrados."
      else
        TenantPartition.log_info "OK", "#{model.name}: Tabla default limpia."
      end
    end

    def process_cleanup_for_model(model, key)
      orphan_ids = fetch_orphan_ids(model, key)
      return TenantPartition.log_info("OK", "#{model.name}: Sin datos huérfanos.") if orphan_ids.empty?

      TenantPartition.log_warn "FIX", "#{model.name}: Procesando #{orphan_ids.count} tenants con datos huérfanos."
      orphan_ids.each { |id| move_orphans(model, id) }
    end

    def move_orphans(model, id)
      # Verificamos si la tabla destino existe antes de intentar mover
      if model.partition_table_exists?(id)
        # Instanciamos el modelo solo para usar el DataMover
        instance = model.new(model.partition_key_column => id)

        moved = instance.populate_from_default
        TenantPartition.log_info "MOVE", "  -> ID #{id}: #{moved} registros recuperados."
      else
        TenantPartition.log_error "ERROR", "  -> ID #{id}: La partición física no existe. Cree el tenant primero."
      end
    end

    def count_default_rows(model)
      model.connection.select_value("SELECT count(*) FROM #{model.default_partition_table_name}").to_i
    rescue ActiveRecord::StatementInvalid
      0
    end

    def fetch_orphan_ids(model, key)
      sql = "SELECT DISTINCT #{key} FROM #{model.default_partition_table_name} WHERE #{key} IS NOT NULL"
      model.connection.execute(sql).map { |r| r[key.to_s] }
    rescue ActiveRecord::StatementInvalid
      []
    end
  end
end
