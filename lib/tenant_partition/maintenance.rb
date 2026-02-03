# frozen_string_literal: true

module TenantPartition
  # Módulo Mixin que agrega capacidades de mantenimiento (Auditoría y Limpieza)
  # a la fachada principal.
  module Maintenance
    # Audita todas las tablas DEFAULT del sistema buscando registros huérfanos.
    # Un registro huérfano es aquel que cayó en la tabla default porque su partición no existía.
    #
    # @return [Hash{String => Integer}] Reporte con nombre del modelo y cantidad de huérfanos.
    def audit
      ensure_models_loaded!
      log_info "AUDIT", "Iniciando auditoría de tablas DEFAULT..."

      partitionable_models.each_with_object({}) do |model, report|
        count = count_default_rows(model)
        report[model.name] = count
        log_audit_result(model, count)
      end
    end

    # Ejecuta el proceso de limpieza global.
    # Identifica registros huérfanos y los mueve a sus particiones correspondientes.
    #
    # @return [void]
    def cleanup!
      ensure_models_loaded!
      key = configuration.partition_key
      log_info "CLEANUP", "Iniciando proceso de limpieza global..."

      partitionable_models.each do |model|
        process_cleanup_for_model(model, key)
      end
    end

    private

    # Registra el resultado de una auditoría en el log.
    def log_audit_result(model, count)
      if count.positive?
        log_warn "ALERTA", "#{model.name}: #{count} registros huérfanos encontrados."
      else
        log_info "OK", "#{model.name}: Tabla default limpia."
      end
    end

    # Orquesta la limpieza para un modelo específico.
    def process_cleanup_for_model(model, key)
      orphan_ids = fetch_orphan_ids(model, key)
      return log_info("OK", "#{model.name}: Sin datos huérfanos.") if orphan_ids.empty?

      log_warn "FIX", "#{model.name}: Procesando #{orphan_ids.count} tenants con datos huérfanos."
      orphan_ids.each { |id| move_orphans(model, id) }
    end

    # Mueve los huérfanos de un tenant específico.
    def move_orphans(model, id)
      partition = model.find(id)
      if partition
        moved = partition.populate_from_default
        log_info "MOVE", "  -> ID #{id}: #{moved} registros recuperados."
      else
        log_error "ERROR", "  -> ID #{id}: La partición física no existe. Cree el tenant primero."
      end
    end

    # Cuenta las filas en la tabla default de un modelo.
    def count_default_rows(model)
      model.connection.select_value("SELECT count(*) FROM #{model.default_table}").to_i
    rescue ActiveRecord::StatementInvalid
      0
    end

    # Obtiene los IDs únicos de los registros atrapados en la tabla default.
    def fetch_orphan_ids(model, key)
      sql = "SELECT DISTINCT #{key} FROM #{model.default_table} WHERE #{key} IS NOT NULL"
      model.connection.execute(sql).map { |r| r[key.to_s] }
    rescue ActiveRecord::StatementInvalid
      []
    end
  end
end
