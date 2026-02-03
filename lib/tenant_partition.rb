# frozen_string_literal: true

require "active_record"
require "active_model"
require "active_support/all"

require_relative "tenant_partition/version"
require_relative "tenant_partition/configuration"
require_relative "tenant_partition/safety_guard"
require_relative "tenant_partition/base"
require_relative "tenant_partition/concerns/partitioned"
require_relative "tenant_partition/concerns/controller"

require_relative "tenant_partition/railtie" if defined?(Rails)

# Fachada principal para la gestión y orquestación de particionamiento en PostgreSQL.
# Actúa como punto de entrada para operaciones de ciclo de vida (crear, borrar, auditar).
module TenantPartition
  class Error < StandardError; end

  class << self
    # @return [TenantPartition::Configuration] Objeto de configuración global.
    attr_accessor :configuration

    # Configura la gema y valida el entorno.
    #
    # @yieldparam [TenantPartition::Configuration] config
    # @return [void]
    def configure
      self.configuration ||= Configuration.new
      yield(configuration)
      SafetyGuard.validate!
    end

    # Crea las particiones físicas para un tenant en todos los modelos registrados.
    #
    # @param partition_id [String, Integer] Identificador del tenant.
    # @return [void]
    def create!(partition_id)
      ensure_models_loaded!
      log_info "CREATE", "Iniciando aprovisionamiento para ID: #{partition_id}"

      partitionable_models.each do |model|
        process_creation(model, partition_id)
      end
    end

    # Elimina irreversiblemente las particiones y datos de un tenant.
    #
    # @param partition_id [String, Integer] Identificador del tenant.
    # @return [void]
    def destroy!(partition_id)
      ensure_models_loaded!
      log_info "DESTROY", "Eliminando infraestructura para ID: #{partition_id}"

      partitionable_models.each do |model|
        process_destruction(model, partition_id)
      end
    end

    # Verifica si existe infraestructura creada para un tenant.
    #
    # @param partition_id [String, Integer] Identificador del tenant.
    # @return [Boolean] true si existe al menos una tabla particionada.
    def exists?(partition_id)
      ensure_models_loaded!
      partitionable_models.any? { |model| model.exists?(partition_id) }
    end

    # Audita tablas DEFAULT en busca de registros huérfanos.
    #
    # @return [Hash{String => Integer}] Mapa de Modelos y cantidad de registros huérfanos.
    def audit
      ensure_models_loaded!
      log_info "AUDIT", "Iniciando auditoría de tablas DEFAULT..."

      partitionable_models.each_with_object({}) do |model, report|
        count = count_default_rows(model)
        report[model.name] = count
        log_audit_result(model, count)
      end
    end

    # Mueve registros huérfanos desde tablas DEFAULT a sus particiones correspondientes.
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

    # --- Helpers de Orquestación ---

    def process_creation(model, partition_id)
      if model.exists?(partition_id)
        log_info "SKIP", "#{model.name}: La partición ya existe."
      else
        model.create(partition_id)
        log_info "OK", "#{model.name}: Partición creada exitosamente."
      end
    end

    def process_destruction(model, partition_id)
      if model.exists?(partition_id)
        if model.find(partition_id).destroy
          log_info "DROP", "#{model.name}: Partición eliminada."
        else
          log_error "FAIL", "#{model.name}: No se pudo eliminar la partición."
        end
      else
        log_info "SKIP", "#{model.name}: No existe partición para borrar."
      end
    end

    # --- Helpers de Mantenimiento ---

    def log_audit_result(model, count)
      if count.positive?
        log_warn "ALERTA", "#{model.name}: #{count} registros huérfanos encontrados."
      else
        log_info "OK", "#{model.name}: Tabla default limpia."
      end
    end

    def process_cleanup_for_model(model, key)
      orphan_ids = fetch_orphan_ids(model, key)
      return log_info("OK", "#{model.name}: Sin datos huérfanos.") if orphan_ids.empty?

      log_warn "FIX", "#{model.name}: Procesando #{orphan_ids.count} tenants con datos huérfanos."
      orphan_ids.each { |id| move_orphans(model, id) }
    end

    def move_orphans(model, id)
      partition = model.find(id)
      if partition
        moved = partition.populate_from_default
        log_info "MOVE", "  -> ID #{id}: #{moved} registros recuperados."
      else
        log_error "ERROR", "  -> ID #{id}: La partición física no existe. Cree el tenant primero."
      end
    end

    # --- Métodos de Soporte ---

    def partitionable_models
      ObjectSpace.each_object(Class).select { |klass| klass < TenantPartition::Base }
    end

    def count_default_rows(model)
      model.connection.select_value("SELECT count(*) FROM #{model.default_table}").to_i
    rescue ActiveRecord::StatementInvalid
      0
    end

    def fetch_orphan_ids(model, key)
      sql = "SELECT DISTINCT #{key} FROM #{model.default_table} WHERE #{key} IS NOT NULL"
      model.connection.execute(sql).map { |r| r[key.to_s] }
    rescue ActiveRecord::StatementInvalid
      []
    end

    def ensure_models_loaded!
      return unless defined?(Rails)

      partition_dir = Rails.root.join("app/models/partition")
      return unless Dir.exist?(partition_dir)

      Dir[partition_dir.join("**/*.rb")].each { |file| require_dependency file }
    end

    # --- Logging ---

    def log_info(tag, msg)  = logger&.info(format_log(tag, msg))
    def log_warn(tag, msg)  = logger&.warn(format_log(tag, msg))
    def log_error(tag, msg) = logger&.error(format_log(tag, msg))
    def format_log(tag, msg) = "[TenantPartition] [#{tag}] #{msg}"
    def logger = (defined?(Rails) ? Rails.logger : Logger.new($stdout))
  end
end
